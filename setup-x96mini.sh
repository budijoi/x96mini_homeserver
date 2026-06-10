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
ZRAM_SIZE="${ZRAM_SIZE:-1024}"          # MB (50% dari 2GB RAM)
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

    # Uninstall paket lama
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

    # Install dependensi
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg lsb-release

    # Repo Docker
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null || {
        warn "Gagal download key Docker, coba metode alternatif..."
        apt-get install -y -qq docker.io docker-compose-v2
        systemctl enable --now docker
        ok "Docker terinstall (via distro repo)"
        return
    }

    echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

    systemctl enable --now docker
    ok "Docker + Docker Compose terinstall"
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
    mkdir -p "$compose_dir" "$data_dir"/{seafile,akkoma-db,akkoma,motioneye,mariadb}

    # Generate random passwords
    SEAFILE_DB_PW=$(openssl rand -base64 16)
    SEAFILE_ADMIN_PW=$(openssl rand -base64 12)
    AKKOMA_DB_PW=$(openssl rand -base64 16)

    # Tulis docker-compose.yml
    cat > "${compose_dir}/docker-compose.yml" <<COMPOSE
version: "3.8"

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
  motioneye-config:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ${data_dir}/motioneye

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
  # 3. CCTV DVR - MotionEye
  # ======================
  motioneye:
    image: ccrisan/motioneye:latest
    container_name: motioneye
    restart: unless-stopped
    networks:
      - x96mini-net
    ports:
      - "8765:8765"
      - "8081:8081"
    volumes:
      - motioneye-config:/etc/motioneye
      - "${data_dir}/motioneye/recordings:/var/lib/motioneye"
    devices:
      - /dev/video0:/dev/video0
    privileged: true
    environment:
      - TZ=${TZ}
COMPOSE

    # Simpan kredensial
    cat > "${compose_dir}/.credentials" <<CRED
========================================
X96Mini SERVICE CREDENTIALS
========================================
Simpan file ini dengan aman!

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
    --help|-h)
        echo "Penggunaan: bash $0 [OPTION]"
        echo "  (tanpa option)  Setup lengkap"
        echo "  --setup-proxy   Pasang Nginx reverse proxy"
        echo "  --zram-only     Setup ZRAM saja"
        echo "  --swap-only     Setup SWAP saja"
        echo "  --storage-only  Setup MicroSD storage saja"
        echo "  --deploy-only   Deploy Docker services saja"
        ;;
    *) main ;;
esac
