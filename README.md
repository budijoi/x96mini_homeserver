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

Untuk akses dari luar + reverse proxy (setelah setup domain):
```bash
sudo bash setup-x96mini.sh --setup-proxy
```

Kredensial akan tercetak di layar dan disimpan di
```/srv/x96mini/compose/.credentials.```
