## Workstation Handbook (Ubuntu 22.04 + XRDP + XFCE + Docker)

This guide helps you operate, troubleshoot, and maintain your VPS workstation.

### Environment
- OS: Ubuntu 22.04 LTS
- Public IP: 81.0.221.64
- GUI: XRDP + XFCE
- User: `malikws` (root SSH login disabled)
- Security: UFW (rate‑limit 22/3389), Fail2Ban (sshd, xrdp-sesman, recidive)
- Dev: Docker + Portainer, Chrome, VS Code

### Quick access
- RDP: Connect to `81.0.221.64:3389` as `malikws` (your password)
- SSH: `ssh malikws@81.0.221.64` (key‑based recommended)
- Portainer (Docker GUI): `https://81.0.221.64:9443`

## Day‑to‑day operations

### System health
```bash
htop
df -hT
free -h
ss -lntup | head
```

### Updates & reboot
```bash
sudo apt update && sudo apt upgrade -y
sudo reboot
```

### Docker quickstart
```bash
docker ps
docker pull nginx
docker run -d -p 8080:80 --name web nginx
docker logs -f web
docker rm -f web
```

## Accounts & passwords

### Change password for `malikws`
```bash
sudo passwd malikws
```

### Check lock status (should show P)
```bash
passwd -S malikws
```

### Unlock if needed
```bash
sudo passwd -u malikws
```

### Create another admin user
```bash
sudo adduser NEWUSER
sudo usermod -aG sudo,docker NEWUSER
```

## Firewall (UFW)

### Show rules
```bash
sudo ufw status
```

### Allow a new app port (example 3000)
```bash
sudo ufw allow 3000/tcp
```

### RDP/SSH from anywhere but rate‑limited (current setup)
```bash
sudo ufw limit OpenSSH
sudo ufw limit 3389/tcp
```

### Restrict RDP/SSH to a specific IP (optional)
```bash
sudo ufw delete limit 3389/tcp  # if present
sudo ufw allow from YOUR_PUBLIC_IP to any port 3389 proto tcp
sudo ufw allow from YOUR_PUBLIC_IP to any port 22 proto tcp
sudo ufw status
```

## Fail2Ban (brute‑force protection)

### Status overview and specific jails
```bash
sudo systemctl status fail2ban --no-pager
sudo fail2ban-client status
sudo fail2ban-client status sshd
sudo fail2ban-client status xrdp-sesman
sudo fail2ban-client status recidive
```

### Unban your IP (if you lock yourself out)
```bash
sudo fail2ban-client set xrdp-sesman unbanip YOUR_IP
sudo fail2ban-client set sshd unbanip YOUR_IP
```

### Enable recidive (already configured)
```bash
sudo systemctl restart fail2ban
sudo fail2ban-client status recidive
```

### Test XRDP protection
1) Intentionally enter wrong RDP password a few times.
2) Check counters:
```bash
sudo fail2ban-client status xrdp-sesman
```

## XRDP/GUI troubleshooting

### Restart XRDP
```bash
sudo systemctl restart xrdp
sudo systemctl status xrdp --no-pager
```

### Set XFCE session for user (if black screen)
```bash
echo startxfce4 > ~/.xsession
```

### Logs
```bash
sudo journalctl -u xrdp -n 200 --no-pager
sudo tail -n 200 /var/log/syslog | grep -i xrdp
```

## Portainer & Docker troubleshooting

### Portainer container
```bash
docker ps | grep portainer
docker logs --tail 200 portainer
```

### Restart Docker
```bash
sudo systemctl restart docker
sudo systemctl status docker --no-pager
```

## Logs & diagnostics
```bash
sudo journalctl -u fail2ban -n 200 --no-pager
sudo journalctl -u xrdp -n 200 --no-pager
sudo dmesg | tail -n 50
```

## Security notes
- Strong password for `malikws`.
- Root SSH login disabled.
- UFW rate‑limit on 22/3389; add only the ports you need.
- Fail2Ban jails: sshd, xrdp-sesman, recidive.
- For travel, either keep global rate‑limits or temporarily `ufw allow from NEW_IP`.

## Optional installs

### VS Code via .deb (if repo ever conflicts)
```bash
curl -fL -o /tmp/vscode_latest_amd64.deb \
  https://update.code.visualstudio.com/latest/linux-deb-x64/stable
sudo apt-get install -y /tmp/vscode_latest_amd64.deb || { \
  sudo apt-get -f install -y; \
  sudo apt-get install -y /tmp/vscode_latest_amd64.deb; }
```

### Cursor (download in RDP and double‑click the .deb)
```bash
sudo dpkg -i cursor*.deb || sudo apt -f install -y
```

## Reset/repair playbook

### XRDP quick repair
```bash
sudo apt-get update
sudo apt-get install -y --reinstall xrdp xorgxrdp
sudo systemctl restart xrdp
```

### Recreate user session file
```bash
echo startxfce4 > /home/malikws/.xsession
chown malikws:malikws /home/malikws/.xsession
```

### Re‑enable Fail2Ban & reload jails
```bash
sudo systemctl restart fail2ban
sudo fail2ban-client reload
sudo fail2ban-client status
```

### Firewall reset (caution)
```bash
sudo ufw reset
sudo ufw allow OpenSSH
sudo ufw limit 3389/tcp
sudo ufw enable
sudo ufw status
```

## Included scripts (workspace)
- `workstation-setup-clean.sh`: full setup/repair with flags:
  - `--yes` non‑interactive
  - `--username=NAME` user to create/configure
  - `--client-ip=IP` restrict RDP/SSH to IP (optional)
  - `--swap-size=2G` create swap
  - `--xrdp-repair` reinstall XRDP
  - `--skip-vscode` skip Code install
- `vps-check.sh`: prints CPU/RAM/disks/network/open ports

## Backups
- Take a provider snapshot now that the server is clean and configured.

— End of Handbook —


