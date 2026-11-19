# Online Meeting App

Free and private online meetings, on a server you control.

People join in the browser: talk, use a camera, share a screen, draw, open files, and chat. A small group connects from browser to browser. A larger group uses the media server installed here. Accounts, rooms, chat, recordings, and files stay in your database.

[فارسی](README.fa.md)

## Requirements

- Ubuntu, and a root shell
- `git`. If it is missing: `sudo apt-get install -y git`
- A domain name
- A public IP, with the domain's A record pointed at it before the certificate step
- The ports in the Ports section, open on that public IP
- Outbound HTTPS, so Let's Encrypt can be reached

The installer adds Nginx, MariaDB, PHP, Coturn, LiveKit, certbot, and ffmpeg. Other Nginx sites stay. The firewall only gains rules.

## Install

Install on a server that has a public IP.

```bash
git clone --depth 1 --branch v1.1.1 https://github.com/mrkioumarsi/didar-online-meetings-app.git didar && sudo bash didar/install/didar-install.sh --net direct --domain meet.example.com --email you@example.com --admin-user admin --admin-pass 'your-password' --confirm-wipe
```

Install on a server behind NAT. Forward the ports to this machine.

```bash
git clone --depth 1 --branch v1.1.1 https://github.com/mrkioumarsi/didar-online-meetings-app.git didar && sudo bash didar/install/didar-install.sh --net nat --domain meet.example.com --email you@example.com --admin-user admin --admin-pass 'your-password' --confirm-wipe
```

If the domain has no A record yet, add `--public-ip` to the NAT command.

The first line it prints must be `Didar 1.1.1 installer 20261120-clone`. If that line is missing, delete the `didar` folder and run the command again.

`--confirm-wipe` erases every MariaDB database on this machine. Other Nginx sites stay. The firewall only gains rules. Without it, the script waits until you type `WIPE-DATABASES`. The admin password needs 8 characters. Leave it out and one is created for you.

`SUCCESS` prints the media mode, then the database password, then the admin username and password. Copy them before you close the terminal. The same values are in `/etc/didar/secrets.env` and `/etc/didar/admin.txt`. The MariaDB root password is not printed. Open `https://your-domain/` and sign in.

After that, the install scripts are removed from the website folder and from the extracted folder. What remains are the commands `didar-update`, `didar-reinstall`, and `didar-uninstall`.

## Update and reinstall

Update when GitHub has a newer release. Reinstall downloads this same release again. The database, `config.local.php`, rooms, recordings, and uploads stay.

```bash
sudo didar-update
sudo didar-reinstall
```

Settings has the same two actions. A failed first install is not repaired by reinstall. Download the release and run the installer again. That wipes MariaDB.

## Ports

These must be open on the public IP. In nat mode, forward them to the server.

- SSH, on the port this machine already uses
- 80 and 443 TCP
- 3478 TCP and UDP
- 5349 TCP
- 7881 TCP
- UDP 49152–49999 and UDP 50000–60000

Outbound HTTPS to Let's Encrypt must be open. If the certificate times out, wait and run the installer again.

Test a call from mobile data. A phone on the same Wi-Fi as the server often cannot open the public name.

LiveKit is pinned to a real address, with `use_external_ip` off. In direct mode, Coturn uses the public card on both sides. In nat mode, it advertises the public IP and relays from the private card. «Force TURN» stays off unless you turn it on in Settings.

Later, Settings can keep the automatic certificate or take a private key, public key, certificate, and bundle. Saving restarts the web server once. If you return to automatic and that certificate is missing, the manual certificate stays.

## Uninstall

```bash
sudo didar-uninstall --soft
sudo didar-uninstall --hard
```

`--soft` waits until you type `REMOVE`. Didar's database, files, site, LiveKit, Coturn, and certificate are removed. Nginx, PHP, MariaDB, other sites, SSH, and UFW stay.

`--hard` waits until you type `DELETE`. This also removes Nginx, PHP, MariaDB and every database, certbot, ffmpeg, the certificates on this server, and the firewall rules the installer opened. SSH and UFW itself stay. Add `--yes` when there is no prompt.

## In a room

Microphone, camera, screen share, whiteboard, and chat. The Files tab holds images, video, and PDF. Notes on a file are live for the room and are not saved. People in the room can download the files. The host deletes them. When the host opens the stage, the whiteboard, or a file, the room follows. Recordings play from the room card. Settings can download a full database backup.

## Donate

Financial support is welcome. USDT on BNB Smart Chain (BEP20):

```
0xAec9F6Ad80940a50e35F453d3354CA8379d0CFaD
```
