#!/bin/bash
# ===============================================================
# X96Mini Auto Setup - Cloud Storage + MicroBlog + CCTV DVR
# Target: Armbian / Debian-based OS on aarch64
# ===============================================================
set -euo pipefail

# ---- Warna untuk output ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ---- Variable Konfigurasi ----
SD_DEV="${SD_DEV:-/dev/mmcblk1}"       # MicroSD device
SD_PART="${SD_PART:-${SD_DEV}p1}"       # MicroSD partition (may be /dev/mmcblk1p1)
MOUNT_DIR="${MOUNT_DIR:-/srv/x96mini}"  # Mount point untuk MicroSD
ZRAM_SIZE="${ZRAM_SIZE:-512}"           # MB (25% dari 2GB RAM)
SWAP_FILE="${SWAP_FILE:-${MOUNT_DIR}/swapfile}"
SWAP_SIZE="${SWAP_SIZE:-2048}"          # MB (2GB swap)
DOMAIN="${DOMAIN:-$(hostname -I | awk '{print $1}')}"
TZ="${TZ:-Asia/Jakarta}"

# ---- Cek Prasyarat ----
preflight() {
    info "Memeriksa prasyarat..."
    [[ $EUID -eq 0 ]] || err "Jalankan sebagai root: sudo bash $0"
    [[ "$(uname -m)" == "aarch64" ]] || warn "Architecture bukan aarch64 (ditemukan: $(uname -m)). Beberapa image mungkin tidak kompatibel."
    command -v apt-get &>/dev/null || err "Harus menggunakan apt-based distro (Debian/Armbian/Ubuntu)"
    ok "Prasyarat terpenuhi"
}

# ---- Setup ZRAM ----
setup_zram() {
    info "Memasang ZRAM ${ZRAM_SIZE}MB..."
    apt-get install -y -qq zram-tools &>/dev/null || true

    cat > /etc/default/zramswap <<EOF
# ZRAM configuration
ZRAM_DEVICES=1
ZRAM_SIZE=${ZRAM_SIZE}
ZRAM_PRIORITY=100
ZRAM_ALGORITHM=zstd
EOF

    systemctl enable zramswap 2>/dev/null || true
    systemctl restart zramswap 2>/dev/null || true
    sleep 1

    # Fallback jika zram-tools tidak bekerja
    if ! swapon --show | grep -q zram; then
        warn "zram-tools gagal, menggunakan fallback manual..."
        modprobe zram || true
        echo zstd > /sys/block/zram0/comp_algorithm 2>/dev/null || true
        echo $((ZRAM_SIZE * 1024 * 1024)) > /sys/block/zram0/disksize 2>/dev/null || true
        mkswap /dev/zram0 &>/dev/null || true
        swapon -p 100 /dev/zram0 &>/dev/null || true
    fi

    ok "ZRAM ${ZRAM_SIZE}MB aktif dengan zstd compression"
}

# ---- Setup SWAP File di MicroSD ----
setup_swap() {
    info "Memasang SWAP file ${SWAP_SIZE}MB di ${SWAP_FILE}..."

    # Matikan swap yang sudah ada (default Armbian sering bikin swap di eMMC)
    swapoff -a 2>/dev/null || true

    if [[ -f "$SWAP_FILE" ]]; then
        warn "Swap file sudah ada, melewati..."
    else
        dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_SIZE" status=progress 2>/dev/null
        chmod 600 "$SWAP_FILE"
        mkswap "$SWAP_FILE" &>/dev/null
    fi

    swapon "$SWAP_FILE" &>/dev/null || true

    # Tambahkan ke fstab jika belum ada
    grep -q "$SWAP_FILE" /etc/fstab 2>/dev/null || \
        echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab

    ok "SWAP ${SWAP_SIZE}MB aktif"
}

# ---- Setup Storage MicroSD ----
setup_storage() {
    info "Memeriksa MicroSD di ${SD_DEV}..."

    if ! lsblk -n "$SD_DEV" &>/dev/null 2>&1; then
        warn "MicroSD tidak terdeteksi di ${SD_DEV}. Coba periksa dengan 'lsblk'."
        warn "Storage setup dilewati. Data akan disimpan di ${MOUNT_DIR} (internal)."
        mkdir -p "$MOUNT_DIR"
        return
    fi

    # Cek apakah ada partisi; jika tidak, buat partisi baru
    HAS_PART=$(lsblk -n "$SD_DEV" | grep -c part || true)
    if [[ "$HAS_PART" -eq 0 ]]; then
        warn "MicroSD belum memiliki partisi. Membuat partisi baru..."
        apt-get install -y -qq parted &>/dev/null || true
        parted -s "$SD_DEV" mklabel msdos
        parted -s "$SD_DEV" mkpart primary ext4 0% 100%
        sleep 2
        partprobe "$SD_DEV" 2>/dev/null || blockdev --rereadpt "$SD_DEV" 2>/dev/null || true
        sleep 2
    fi

    # Deteksi partisi (nama partisi bervariasi: mmcblk1p1, mmcblk1_1, dll)
    SD_PART=$(lsblk -nlo NAME "$SD_DEV" | grep -v "^$(basename "$SD_DEV")$" | head -1)
    SD_PART="/dev/${SD_PART}"

    # Format jika belum ext4
    FSTYPE=$(blkid -s TYPE -o value "$SD_PART" 2>/dev/null || echo "")
    if [[ "$FSTYPE" != "ext4" ]]; then
        warn "Partisi MicroSD bukan ext4 (${FSTYPE:-none}). Memformat..."
        umount "$SD_PART" 2>/dev/null || true
        mkfs.ext4 -F "$SD_PART" &>/dev/null || err "Gagal memformat MicroSD"
        ok "MicroSD diformat ext4"
    fi

    # Mount
    mkdir -p "$MOUNT_DIR"
    if ! mountpoint -q "$MOUNT_DIR"; then
        mount "$SD_PART" "$MOUNT_DIR" || err "Gagal mount MicroSD"
    fi

    # Tambahkan ke fstab jika belum ada
    grep -q "$SD_PART" /etc/fstab 2>/dev/null || \
        echo "$SD_PART $MOUNT_DIR ext4 defaults,noatime,data=writeback 0 2" >> /etc/fstab

    ok "MicroSD terpasang di ${MOUNT_DIR}"
    df -h "$MOUNT_DIR" | tail -1
}

# ---- System Tuning ----
tune_system() {
    info "Mengoptimalkan kernel parameters..."

    cat > /etc/sysctl.d/99-x96mini.conf <<EOF
# X96Mini tuning
vm.swappiness=60
vm.vfs_cache_pressure=50
vm.dirty_ratio=20
vm.dirty_background_ratio=5
vm.min_free_kbytes=65536
fs.file-max=65536
net.core.somaxconn=1024
net.ipv4.tcp_tw_reuse=1
EOF

    sysctl -p /etc/sysctl.d/99-x96mini.conf &>/dev/null || true
    ok "System tuning diterapkan"
}

# ---- Install Docker ----
install_docker() {
    if command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
        ok "Docker sudah terinstall"
        return
    fi

    info "Memasang Docker untuk aarch64..."
    apt-get update -qq

    # Hapus repo Docker lama yang mungkin salah dari percobaan sebelumnya
    rm -f /etc/apt/sources.list.d/docker.list 2>/dev/null || true

    # Deteksi apakah ini Armbian dengan codename Ubuntu
    local codename
    codename=$(grep -oP '^VERSION_CODENAME=\K.*' /etc/os-release 2>/dev/null | tr -d '"' || echo "")

    # Daftar codename Ubuntu yang dikenal
    local is_ubuntu_codename=0
    for c in focal jammy kinetic lunar mantic noble oracular plucky; do
        [[ "$codename" == "$c" ]] && { is_ubuntu_codename=1; break; }
    done

    if [[ "$is_ubuntu_codename" -eq 1 ]]; then
        # Armbian dengan codename Ubuntu → forced pakai repo Ubuntu
        info "Mendeteksi sistem dengan codename Ubuntu (${codename}). Pakai repo Docker Ubuntu..."
        apt-get install -y -qq ca-certificates curl gnupg
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
        echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable" > /etc/apt/sources.list.d/docker.list
        apt-get update -qq 2>/dev/null && \
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>/dev/null && {
            systemctl enable --now docker
            ok "Docker + Docker Compose terinstall (via repo Ubuntu)"
            return
        }
        warn "Repo Docker Ubuntu gagal, fallback ke distro..."
    fi

    # Fallback: install dari repo distro
    apt-get install -y -qq docker.io docker-compose-v2
    systemctl enable --now docker
    ok "Docker terinstall (via distro repo)"
}

# ---- Setup Docker Data di MicroSD ----
setup_docker_data() {
    local docker_root="${MOUNT_DIR}/docker"
    mkdir -p "$docker_root"

    # Konfigurasi Docker untuk pakai storage di MicroSD
    cat > /etc/docker/daemon.json <<EOF
{
  "data-root": "${docker_root}",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2"
}
EOF

    systemctl restart docker
    ok "Docker data-root dialihkan ke ${docker_root}"
}

# ---- Deploy Services via Docker Compose ----
deploy_services() {
    info "Menyiapkan Docker Compose..."

    local compose_dir="${MOUNT_DIR}/compose"
    local data_dir="${MOUNT_DIR}/data"
    mkdir -p "$compose_dir" "$data_dir"/{seafile,akkoma-db,akkoma,mariadb,dashboard}

    # Generate random passwords
    SEAFILE_DB_PW=$(openssl rand -base64 16)
    SEAFILE_ADMIN_PW=$(openssl rand -base64 12)
    AKKOMA_DB_PW=$(openssl rand -base64 16)

    # Tulis docker-compose.yml
    cat > "${compose_dir}/docker-compose.yml" <<COMPOSE
networks:
  x96mini-net:
    driver: bridge

volumes:
  seafile-data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ${data_dir}/seafile
  mariadb-data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ${data_dir}/mariadb
  akkoma-db-data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ${data_dir}/akkoma-db
  akkoma-config:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ${data_dir}/akkoma

services:
  # ======================
  # 1. CLOUD STORAGE - Seafile
  # ======================
  seafile-db:
    image: mariadb:10.11
    container_name: seafile-db
    restart: unless-stopped
    networks:
      - x96mini-net
    volumes:
      - mariadb-data:/var/lib/mysql
    environment:
      - MYSQL_ROOT_PASSWORD=${SEAFILE_DB_PW}
      - MYSQL_DATABASE=seafile
      - MYSQL_USER=seafile
      - MYSQL_PASSWORD=${SEAFILE_DB_PW}
      - TZ=${TZ}

  seafile-memcached:
    image: memcached:1.6
    container_name: seafile-memcached
    restart: unless-stopped
    networks:
      - x96mini-net
    command: ["memcached", "-m", "64"]

  seafile:
    image: seafileltd/seafile-mc:latest
    container_name: seafile
    restart: unless-stopped
    networks:
      - x96mini-net
    ports:
      - "8001:80"
      - "8082:8082"
    volumes:
      - seafile-data:/shared
    environment:
      - DB_HOST=seafile-db
      - DB_PORT=3306
      - DB_USER=seafile
      - DB_PASSWORD=${SEAFILE_DB_PW}
      - DB_ROOT_PASSWD=${SEAFILE_DB_PW}
      - SEAFILE_SERVER_HOSTNAME=${DOMAIN}
      - SEAFILE_ADMIN_EMAIL=admin@example.com
      - SEAFILE_ADMIN_PASSWORD=${SEAFILE_ADMIN_PW}
      - MEMCACHED_HOST=seafile-memcached
      - MEMCACHED_PORT=11211
      - TZ=${TZ}
    depends_on:
      - seafile-db
      - seafile-memcached

  # ======================
  # 2. MICROBLOG - Akkoma
  # ======================
  akkoma-db:
    image: postgres:15-alpine
    container_name: akkoma-db
    restart: unless-stopped
    networks:
      - x96mini-net
    volumes:
      - akkoma-db-data:/var/lib/postgresql/data
    environment:
      - POSTGRES_DB=akkoma
      - POSTGRES_USER=akkoma
      - POSTGRES_PASSWORD=${AKKOMA_DB_PW}
      - TZ=${TZ}

  akkoma:
    image: akkoma/akkoma:stable
    container_name: akkoma
    restart: unless-stopped
    networks:
      - x96mini-net
    ports:
      - "4000:4000"
    volumes:
      - akkoma-config:/var/lib/akkoma
    environment:
      - DB_HOST=akkoma-db
      - DB_PORT=5432
      - DB_NAME=akkoma
      - DB_USER=akkoma
      - DB_PASS=${AKKOMA_DB_PW}
      - DOMAIN=${DOMAIN}
      - TZ=${TZ}
    depends_on:
      - akkoma-db

  # ======================
  # 3. DASHBOARD (port 80)
  # ======================
  dashboard:
    image: python:3.11-alpine
    container_name: dashboard
    restart: unless-stopped
    networks:
      - x96mini-net
    ports:
      - "80:80"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - "${data_dir}/dashboard:/app"
    working_dir: /app
    command: python server.py
    environment:
      - TZ=${TZ}
COMPOSE

    # Tulis dashboard files
    cat > "${data_dir}/dashboard/server.py" <<'PYEOF'
#!/usr/bin/env python3
import http.server, json, os, socket, time
from pathlib import Path

PORT = 80
HTML_FILE = Path(__file__).parent / "index.html"
SERVICES = {
    "Seafile":   {"host": "seafile",              "port": 80,   "url": "http://localhost:8001"},
    "Akkoma":    {"host": "akkoma",               "port": 4000, "url": "http://localhost:4000"},
    "Motion":    {"host": "host.docker.internal",  "port": 8765, "url": "http://localhost:8765"},
}

def read_proc(path):
    try:
        with open(path) as f: return f.read()
    except OSError: return ""

def get_uptime():
    raw = read_proc("/proc/uptime").strip()
    if not raw: return {"days":0,"hours":0,"minutes":0}
    s = float(raw.split()[0])
    return {"days":int(s//86400),"hours":int((s%86400)//3600),"minutes":int((s%3600)//60)}

def get_loadavg():
    raw = read_proc("/proc/loadavg").strip()
    if not raw: return [0,0,0]
    return [float(x) for x in raw.split()[:3]]

def get_memory():
    raw = read_proc("/proc/meminfo"); mem = {}
    for line in raw.splitlines():
        p = line.split()
        if len(p)>=2: mem[p[0].rstrip(":")] = int(p[1])
    t = mem.get("MemTotal",0); a = mem.get("MemAvailable",0); u = t - a
    return {"total_kb":t,"used_kb":u,"available_kb":a,"percent":round(u/t*100,1) if t else 0}

def get_swap():
    raw = read_proc("/proc/meminfo"); mem = {}
    for line in raw.splitlines():
        p = line.split()
        if len(p)>=2: mem[p[0].rstrip(":")] = int(p[1])
    t = mem.get("SwapTotal",0); f = mem.get("SwapFree",0); u = t - f
    return {"total_kb":t,"used_kb":u,"free_kb":f,"percent":round(u/t*100,1) if t else 0}

def get_disk(path="/srv/x96mini"):
    try:
        st = os.statvfs(path)
        t = st.f_frsize * st.f_blocks; f = st.f_frsize * st.f_bfree; u = t - f
        return {"total_gb":round(t/(1024**3),1),"used_gb":round(u/(1024**3),1),"free_gb":round(f/(1024**3),1),"percent":round(u/t*100,1) if t else 0}
    except: return {"total_gb":0,"used_gb":0,"free_gb":0,"percent":0}

def check_service(host,port,timeout=2):
    try:
        sock = socket.create_connection((host,port),timeout=timeout); sock.close()
        return "online"
    except: return "offline"

def get_services_status():
    r = {}
    for n,i in SERVICES.items(): r[n] = {"status": check_service(i["host"],i["port"]), "url": i["url"]}
    return r

def get_status():
    return {"system":{"hostname":os.uname().nodename,"uptime":get_uptime(),"loadavg":get_loadavg(),"memory":get_memory(),"swap":get_swap(),"disk":get_disk()},"services":get_services_status()}

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/api/status":
            self.send_response(200)
            self.send_header("Content-Type","application/json"); self.send_header("Access-Control-Allow-Origin","*")
            self.end_headers(); self.wfile.write(json.dumps(get_status()).encode())
        elif self.path in ("/","/index.html"):
            self.send_response(200); self.send_header("Content-Type","text/html; charset=utf-8"); self.end_headers()
            if HTML_FILE.exists(): self.wfile.write(HTML_FILE.read_bytes())
            else: self.wfile.write(b"<h1>Dashboard</h1><p>index.html not found</p>")
        else:
            self.send_response(404); self.end_headers(); self.wfile.write(b"Not found")
    def log_message(self,fmt,*args): pass

if __name__ == "__main__":
    http.server.HTTPServer(("0.0.0.0",PORT),H).serve_forever()
PYEOF

    cat > "${data_dir}/dashboard/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="id">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>X96Mini Dashboard</title>
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
:root{--bg:#0f1117;--card:#1a1d27;--border:#2a2d3a;--text:#e1e4eb;--muted:#7a7f8e;--accent:#6366f1;--green:#22c55e;--red:#ef4444;--yellow:#eab308;--radius:12px}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:var(--bg);color:var(--text);min-height:100vh;display:flex;flex-direction:column;align-items:center;padding:24px}
.container{max-width:900px;width:100%}
header{text-align:center;margin-bottom:32px}
header h1{font-size:1.6rem;font-weight:700}
header h1 span{color:var(--accent)}
header p{color:var(--muted);font-size:.85rem;margin-top:4px}
#uptime{color:var(--muted);font-size:.8rem;margin-top:8px}
.grid{display:grid;gap:16px;margin-bottom:24px}
.grid-3{grid-template-columns:repeat(3,1fr)}
.grid-2{grid-template-columns:repeat(2,1fr)}
.card{background:var(--card);border:1px solid var(--border);border-radius:var(--radius);padding:20px;transition:transform .15s,border-color .15s}
.card:hover{border-color:var(--accent)}
.card-title{font-size:.7rem;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);margin-bottom:8px}
.card-value{font-size:1.4rem;font-weight:700}
.card-sub{font-size:.75rem;color:var(--muted);margin-top:4px}
.bar-wrap{margin-top:10px}
.bar{height:6px;background:var(--border);border-radius:3px;overflow:hidden}
.bar-fill{height:100%;border-radius:3px;transition:width .5s}
.bar-label{display:flex;justify-content:space-between;font-size:.7rem;color:var(--muted);margin-top:4px}
.service-card{background:var(--card);border:1px solid var(--border);border-radius:var(--radius);padding:24px;text-decoration:none;color:var(--text);display:block;transition:transform .15s,border-color .15s,box-shadow .15s;position:relative;overflow:hidden}
.service-card:hover{border-color:var(--accent);transform:translateY(-2px);box-shadow:0 8px 24px rgba(99,102,241,.15)}
.service-card .icon{font-size:2rem;margin-bottom:8px}
.service-card .name{font-size:1.1rem;font-weight:600}
.service-card .desc{font-size:.78rem;color:var(--muted)}
.service-card .badge{display:inline-block;font-size:.65rem;padding:2px 10px;border-radius:99px;margin-top:8px;font-weight:600}
.badge.online{background:rgba(34,197,94,.15);color:var(--green)}
.badge.offline{background:rgba(239,68,68,.15);color:var(--red)}
footer{text-align:center;color:var(--muted);font-size:.75rem;margin-top:32px}
@media(max-width:640px){.grid-3{grid-template-columns:1fr 1fr}.grid-2{grid-template-columns:1fr}body{padding:16px}}
</style>
</head>
<body>
<div class="container">
<header>
<h1>X96Mini <span>Dashboard</span></h1>
<p id="hostname"></p>
<div id="uptime"></div>
</header>
<div class="grid grid-3">
<div class="card"><div class="card-title">CPU Load</div><div class="card-value" id="load">-</div><div class="card-sub">1 min / 5 min / 15 min</div></div>
<div class="card"><div class="card-title">RAM</div><div class="card-value" id="ram">-</div><div class="bar-wrap"><div class="bar"><div class="bar-fill" id="ram-bar" style="width:0%;background:var(--accent)"></div></div><div class="bar-label"><span id="ram-used">-</span><span id="ram-total">-</span></div></div></div>
<div class="card"><div class="card-title">SWAP</div><div class="card-value" id="swap">-</div><div class="bar-wrap"><div class="bar"><div class="bar-fill" id="swap-bar" style="width:0%;background:var(--yellow)"></div></div><div class="bar-label"><span id="swap-used">-</span><span id="swap-total">-</span></div></div></div>
</div>
<div class="grid grid-2" style="margin-bottom:24px">
<div class="card"><div class="card-title">Storage (MicroSD 64GB)</div><div class="card-value" id="disk-used">-</div><div class="card-sub" id="disk-detail"></div><div class="bar-wrap"><div class="bar"><div class="bar-fill" id="disk-bar" style="width:0%;background:var(--green)"></div></div><div class="bar-label"><span id="disk-used-label">-</span><span id="disk-total-label">-</span></div></div></div>
<div class="card"><div class="card-title">Services Status</div><div id="service-status-list" style="font-size:.85rem"></div></div>
</div>
<h2 style="font-size:1rem;margin-bottom:12px;color:var(--muted)">Navigasi</h2>
<div class="grid grid-3" style="margin-bottom:24px">
<a href="http://localhost:8001" target="_blank" class="service-card" id="card-seafile"><div class="icon">&#x1F4C1;</div><div class="name">Seafile</div><div class="desc">Cloud Storage pribadi</div><div class="badge" id="status-seafile">memeriksa...</div></a>
<a href="http://localhost:4000" target="_blank" class="service-card" id="card-akkoma"><div class="icon">&#x2709;&#xFE0F;</div><div class="name">Akkoma</div><div class="desc">MicroBlog terfederasi</div><div class="badge" id="status-akkoma">memeriksa...</div></a>
<a href="http://localhost:8765" target="_blank" class="service-card" id="card-motioneye"><div class="icon">&#x1F4F7;</div><div class="name">Motion</div><div class="desc">CCTV DVR / IP Camera</div><div class="badge" id="status-motioneye">memeriksa...</div></a>
</div>
<footer>X96Mini Server &mdash; Armbian aarch64</footer>
</div>
<script>
async function fetchStatus(){try{const r=await fetch('/api/status');const d=await r.json();render(d)}catch(e){document.getElementById('load').textContent='offline'}}
function render(d){const s=d.system;document.getElementById('hostname').textContent='Host: '+s.hostname;const u=s.uptime,p=[];if(u.days)p.push(u.days+'d');if(u.hours)p.push(u.hours+'j');p.push(u.minutes+'m');document.getElementById('uptime').textContent='Uptime: '+p.join(' ');const l=s.loadavg;document.getElementById('load').textContent=l.map(v=>v.toFixed(2)).join(' / ');const m=s.memory;const g=v=>(v/(1024*1024)).toFixed(1);document.getElementById('ram').textContent=m.percent+'%';document.getElementById('ram-bar').style.width=m.percent+'%';document.getElementById('ram-used').textContent=g(m.used_kb)+' GB used';document.getElementById('ram-total').textContent=g(m.total_kb)+' GB';const w=s.swap;document.getElementById('swap').textContent=w.total_kb?w.percent+'%':'none';document.getElementById('swap-bar').style.width=(w.total_kb?w.percent:0)+'%';document.getElementById('swap-used').textContent=w.total_kb?g(w.used_kb)+' GB used':'-';document.getElementById('swap-total').textContent=w.total_kb?g(w.total_kb)+' GB':'-';const k=s.disk;document.getElementById('disk-used').textContent=k.used_gb+' GB / '+k.total_gb+' GB';document.getElementById('disk-detail').textContent=k.percent+'% terpakai';document.getElementById('disk-bar').style.width=k.percent+'%';document.getElementById('disk-used-label').textContent=k.used_gb+' GB used';document.getElementById('disk-total-label').textContent=k.total_gb+' GB';const t=document.getElementById('service-status-list');t.innerHTML='';for(const[n,i]of Object.entries(d.services)){const r=document.createElement('div');r.style.display='flex';r.style.justifyContent='space-between';r.style.padding='4px 0';const o=i.status==='online'?'&#x1F7E2;':'&#x1F534;';r.innerHTML=o+' '+n+'<span style="color:'+(i.status==='online'?'var(--green)':'var(--red)')+'">'+i.status+'</span>';t.appendChild(r)}for(const[n,i]of Object.entries(d.services)){const b=document.getElementById('status-'+n.toLowerCase());if(b){b.textContent=i.status;b.className='badge '+i.status}}}
fetchStatus();setInterval(fetchStatus,10000);
</script>
</body>
</html>
HTMLEOF

    ok "Dashboard files created"
    cat > "${compose_dir}/.credentials" <<CRED
========================================
X96Mini SERVICE CREDENTIALS
========================================
Simpan file ini dengan aman!

DASHBOARD:
  URL    : http://${DOMAIN}
  Status : Live system status + navigasi

SEAFILE:
  URL    : http://${DOMAIN}:8001
  Admin  : admin@example.com
  Pass   : ${SEAFILE_ADMIN_PW}

AKKOMA:
  URL    : http://${DOMAIN}:4000
  Setup  : akses URL untuk registrasi pertama

MOTIONEYE:
  URL    : http://${DOMAIN}:8765
  User   : admin
  Pass   : (kosong, set via UI setelah login)

DATABASE CREDENTIALS (seafile):
  Root   : root / ${SEAFILE_DB_PW}
  User   : seafile / ${SEAFILE_DB_PW}

DATABASE CREDENTIALS (akkoma):
  User   : akkoma / ${AKKOMA_DB_PW}

========================================
CRED
    chmod 600 "${compose_dir}/.credentials"

    # Deploy
    cd "$compose_dir"
    docker compose pull
    docker compose up -d

    ok "Semua service telah dideploy!"
    echo ""
    cat "${compose_dir}/.credentials"
}

# ---- Setup CCTV (Native motion + motioneye) ----
setup_cctv() {
    if command -v motion &>/dev/null && systemctl is-active --quiet motion 2>/dev/null; then
        ok "CCTV (motion) sudah terinstall"
        return
    fi

    info "Memasang CCTV DVR (motion + motioneye)..."
    apt-get install -y -qq motion python3-pip python3-dev python3-setuptools

    # Buat direktori rekaman
    local record_dir="${MOUNT_DIR}/data/motioneye/recordings"
    mkdir -p "$record_dir"

    # Konfigurasi motion
    cat > /etc/motion/motion.conf <<MOTION
daemon on
log_level 3
log_file /var/log/motion.log
target_dir ${record_dir}
videodevice /dev/video0
width 640
height 480
framerate 5
threshold 1500
event_gap 60
pre_capture 3
post_capture 10
stream_port 8765
stream_localhost off
stream_maxrate 10
webcontrol_port 8080
webcontrol_localhost off
webcontrol_parms 0
picture_output off
movie_output on
movie_codec mpeg4
movie_max_time 60
MOTION

    # Install motioneye via pip
    pip3 install motioneye --break-system-packages 2>/dev/null || pip3 install motioneye 2>/dev/null || true

    # Systemd service untuk motion
    cat > /etc/systemd/system/motion.service <<UNIT
[Unit]
Description=Motion CCTV daemon
After=network.target

[Service]
ExecStart=/usr/bin/motion -c /etc/motion/motion.conf
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable motion
    systemctl restart motion

    ok "CCTV DVR terinstall (port 8765 - stream, port 8080 - webcontrol)"
}

# ---- Info tambahan ----
show_info() {
    echo ""
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}  X96Mini SETUP COMPLETE!${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo ""
    echo -e "ZRAM     : ${ZRAM_SIZE}MB (zstd)"
    echo -e "SWAP     : ${SWAP_SIZE}MB (di MicroSD)"
    echo -e "Storage  : ${MOUNT_DIR}"
    echo -e "Domain   : ${DOMAIN}"
    echo ""
    echo -e "Service URLs:"
    echo -e "  Dashboard     : ${CYAN}http://${DOMAIN}${NC} (Homepage)"
    echo -e "  Cloud Storage : ${CYAN}http://${DOMAIN}:8001${NC}"
    echo -e "  MicroBlog     : ${CYAN}http://${DOMAIN}:4000${NC}"
    echo -e "  CCTV DVR      : ${CYAN}http://${DOMAIN}:8765${NC}"
    echo ""
    echo -e "Credential disimpan di: ${YELLOW}${MOUNT_DIR}/compose/.credentials${NC}"
    echo ""
    echo -e "${YELLOW}Tips:${NC}"
    echo -e "  1. Reboot setelah setup selesai: sudo reboot"
    echo -e "  2. Jika ingin akses dari luar, port-forward di router"
    echo -e "  3. Untuk set domain/nginx reverse proxy, jalankan:"
    echo -e "     ${CYAN}bash $0 --setup-proxy${NC}"
    echo ""
}

# ---- Setup Nginx Reverse Proxy (Opsional) ----
setup_proxy() {
    info "Memasang Nginx reverse proxy..."
    apt-get install -y -qq nginx certbot python3-certbot-nginx

    # Seafile
    cat > /etc/nginx/sites-available/seafile <<'NGX'
server {
    listen 80;
    server_name seafile.DOMAIN;
    client_max_body_size 0;
    location / {
        proxy_pass http://127.0.0.1:8001;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
    location /seafhttp {
        rewrite ^/seafhttp(.*)$ $1 break;
        proxy_pass http://127.0.0.1:8082;
        proxy_set_header Host $host;
    }
}
NGX
    sed -i "s/seafile\.DOMAIN/seafile.$DOMAIN/g" /etc/nginx/sites-available/seafile
    ln -sf /etc/nginx/sites-available/seafile /etc/nginx/sites-enabled/

    # Akkoma
    cat > /etc/nginx/sites-available/akkoma <<'NGX'
server {
    listen 80;
    server_name akkoma.DOMAIN;
    location / {
        proxy_pass http://127.0.0.1:4000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
NGX
    sed -i "s/akkoma\.DOMAIN/akkoma.$DOMAIN/g" /etc/nginx/sites-available/akkoma
    ln -sf /etc/nginx/sites-available/akkoma /etc/nginx/sites-enabled/

    # MotionEye
    cat > /etc/nginx/sites-available/motioneye <<'NGX'
server {
    listen 80;
    server_name cctv.DOMAIN;
    client_max_body_size 0;
    location / {
        proxy_pass http://127.0.0.1:8765;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
NGX
    sed -i "s/cctv\.DOMAIN/cctv.$DOMAIN/g" /etc/nginx/sites-available/motioneye
    ln -sf /etc/nginx/sites-available/motioneye /etc/nginx/sites-enabled/

    nginx -t && systemctl reload nginx
    ok "Nginx proxy terpasang"
    echo -e "Akses via:"
    echo -e "  ${CYAN}http://seafile.${DOMAIN}${NC}"
    echo -e "  ${CYAN}http://akkoma.${DOMAIN}${NC}"
    echo -e "  ${CYAN}http://cctv.${DOMAIN}${NC}"
}

# ---- Main ----
main() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  X96Mini Ultimate Setup${NC}"
    echo -e "${CYAN}  Cloud Storage + MicroBlog + CCTV DVR${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""

    preflight
    setup_zram
    setup_storage
    setup_swap
    tune_system
    install_docker
    setup_docker_data
    setup_cctv
    deploy_services
    show_info

    echo -e "${YELLOW}Reboot sekarang? (y/N):${NC} "
    read -r REBOOT
    [[ "$REBOOT" =~ ^[Yy]$ ]] && reboot
}

# ---- Argumen ----
case "${1:-}" in
    --setup-proxy) setup_proxy ;;
    --zram-only) setup_zram ;;
    --swap-only) setup_swap ;;
    --storage-only) setup_storage ;;
    --deploy-only) deploy_services ;;
    --cctv-only) setup_cctv ;;
    --help|-h)
        echo "Penggunaan: bash $0 [OPTION]"
        echo "  (tanpa option)  Setup lengkap"
        echo "  --setup-proxy   Pasang Nginx reverse proxy"
        echo "  --zram-only     Setup ZRAM saja"
        echo "  --swap-only     Setup SWAP saja"
        echo "  --storage-only  Setup MicroSD storage saja"
        echo "  --deploy-only   Deploy Docker services saja"
        echo "  --cctv-only     Install CCTV DVR (motion native)"
        ;;
    *) main ;;
esac
