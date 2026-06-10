# x96mini_homeserver

Cara pakai:
Copy script ke STB yang sudah terinstall Armbian
```bash
curl -O https://raw.githubusercontent.com/budijoi/x96mini_homeserver/main/setup-x96mini.sh
```
Ubah permission
```bash
chmod +x setup-x96mini.sh
```
Jalankan installer
```bash
sudo ./setup-x96mini.sh
```
File	Fungsi
* setup-x96mini.sh	Script utama (otomatis: ZRAM, SWAP, MicroSD, Docker, deploy semua service)
* docker-compose.yml	Standalone compose file (untuk manual deploy)
* .env.example	Template konfigurasi environment

Yang dilakukan script:

* ZRAM - 1024MB (50% RAM) pakai algoritma zstd
* SWAP - 2048MB file di MicroSD
* MicroSD - Format ext4, mount ke /srv/x96mini
* System tuning - swappiness=60, dirty_ratio=20, dll
* Docker - Install + alihkan data-root ke MicroSD
* Deploy services via Docker Compose:

Untuk akses dari luar + reverse proxy (setelah setup domain):
```bash
sudo bash setup-x96mini.sh --setup-proxy
```

Kredensial akan tercetak di layar dan disimpan di
```/srv/x96mini/compose/.credentials.```
