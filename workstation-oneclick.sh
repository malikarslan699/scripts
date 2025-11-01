#!/usr/bin/env bash

set -Eeuo pipefail
trap 'echo "[ERROR] Command failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

# Defaults suitable for ANY VPS (Ubuntu/Debian)
AUTO_YES=false
USERNAME=""
ALLOW_SSH_PASSWORDS=false
CLIENT_IP_RESTRICT=""         # default: open to all with rate-limits
CREATE_SWAP_SIZE=""           # e.g., 2G
SKIP_VSCODE=false
NO_DOCKER=false
NO_CHROME=false
XRDP_REPAIR=false

GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; BLUE="\033[1;34m"; RESET="\033[0m"
ok() { echo -e "${GREEN}[OK]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
fail() { echo -e "${RED}[FAIL]${RESET} $*"; }
info() { echo -e "${BLUE}[INFO]${RESET} $*"; }

require_root() { if [[ $(id -u) -ne 0 ]]; then fail "Run as root (use sudo)"; exit 1; fi; }

ask_confirm() { local m=${1:-Proceed?}; $AUTO_YES && { info "$m [auto-yes]"; return 0; }; read -r -p "$m [Y/n]: " r || true; r=${r:-Y}; [[ $r =~ ^[Yy]$ ]]; }

is_supported_os() {
  if [[ -r /etc/os-release ]]; then . /etc/os-release; fi
  case "${ID:-}-${VERSION_ID:-}" in
    ubuntu-*|debian-*) return 0;;
    *) return 1;;
  esac
}

parse_args() {
  for a in "$@"; do
    case "$a" in
      -y|--yes) AUTO_YES=true;;
      --username=*) USERNAME="${a#*=}";;
      --allow-ssh-passwords) ALLOW_SSH_PASSWORDS=true;;
      --client-ip=*) CLIENT_IP_RESTRICT="${a#*=}";;
      --swap-size=*) CREATE_SWAP_SIZE="${a#*=}";;
      --skip-vscode) SKIP_VSCODE=true;;
      --no-docker) NO_DOCKER=true;;
      --no-chrome) NO_CHROME=true;;
      --xrdp-repair) XRDP_REPAIR=true;;
      -h|--help)
        cat <<USAGE
Usage: sudo ./workstation-oneclick.sh [options]
  -y, --yes                 Non-interactive
  --username=NAME           Create/admin user (default: prompt; e.g., malikws)
  --allow-ssh-passwords     Allow SSH password auth (default: key-only)
  --client-ip=IP            Restrict SSH/RDP to IP (default: open to all with limits)
  --swap-size=SIZE          Create swap file (e.g., 2G)
  --skip-vscode             Skip VS Code install
  --no-docker               Skip Docker/Portainer
  --no-chrome               Skip Chrome
  --xrdp-repair             Reinstall XRDP core packages
USAGE
        exit 0;;
      *) warn "Unknown option: $a";;
    esac
  done
}

wait_for_apt() {
  local retries=30 delay=2
  for i in $(seq 1 $retries); do
    if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
      warn "apt/dpkg locked. Waiting ($i/$retries)..."; sleep $delay
    else
      return 0
    fi
  done; fail "apt lock stuck"; return 1
}

apt_update_retry() { wait_for_apt; local t=5; for i in $(seq 1 $t); do info "apt update (try $i/$t)"; if apt-get update -y; then ok "apt update ok"; return 0; fi; sleep 2; done; fail "apt update failed"; return 1; }
install_packages() { wait_for_apt; DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; }
ensure_packages() { apt_update_retry; install_packages "$@"; }

# Preflight repo fixes (VS Code / Docker dedupe)
fix_vscode_repo() {
  install -m 0755 -d /etc/apt/keyrings /etc/apt/sources.list.d
  [[ -f /etc/apt/keyrings/ms_vscode.gpg ]] || { curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/ms_vscode.gpg; chmod a+r /etc/apt/keyrings/ms_vscode.gpg; }
  sed -i -E 's|^[^#].*packages\.microsoft\.com.*/repos/code.*|# &|' /etc/apt/sources.list 2>/dev/null || true
  while IFS= read -r -d '' f; do rm -f "$f" || true; done < <(grep -RIlZ "packages.microsoft.com/.*/repos/code" /etc/apt/sources.list.d 2>/dev/null || true)
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/ms_vscode.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list
}
fix_docker_repo() {
  install -m 0755 -d /etc/apt/keyrings /etc/apt/sources.list.d
  [[ -f /etc/apt/keyrings/docker.gpg ]] || { curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg; chmod a+r /etc/apt/keyrings/docker.gpg; }
  local codename; codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
  sed -i -E 's|^[^#].*download\.docker\.com/linux/ubuntu.*|# &|' /etc/apt/sources.list 2>/dev/null || true
  while IFS= read -r -d '' f; do rm -f "$f" || true; done < <(grep -RIlZ "download.docker.com/linux/ubuntu" /etc/apt/sources.list.d 2>/dev/null || true)
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable" > /etc/apt/sources.list.d/docker.list
}

setup_basics() { info "Installing basics"; ensure_packages curl git htop jq unzip ca-certificates iproute2 psmisc; }

setup_xrdp_xfce() {
  info "Setting up XRDP + XFCE"
  $XRDP_REPAIR && { apt_update_retry; DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall xrdp xorgxrdp || true; }
  ensure_packages xrdp xfce4 xfce4-goodies xorgxrdp policykit-1-gnome dbus-x11
  echo startxfce4 > /etc/skel/.xsession
  echo startxfce4 > "$HOME/.xsession" || true
  adduser xrdp ssl-cert || true
  systemctl enable --now xrdp; sleep 1
  systemctl is-active --quiet xrdp && ok "XRDP active" || { fail "XRDP inactive"; systemctl status xrdp || true; }
}

create_user() {
  local user="$1"
  if ! id "$user" >/dev/null 2>&1; then
    info "Creating user $user"
    adduser --disabled-password --gecos "" "$user"
    usermod -aG sudo "$user" || true
  else
    info "User $user exists"
  fi
  # Set password (auto or prompt)
  if $AUTO_YES; then
    local pw; set +o pipefail; pw=$(head -c 64 /dev/urandom | tr -dc 'A-Za-z0-9!@#$%^&*()_+=' | head -c 16); set -o pipefail
    [[ -z "$pw" ]] && pw=$(date +%s | sha256sum | awk '{print $1}' | head -c 16)
    echo "$user:$pw" | chpasswd; info "Temporary password for $user: $pw"
  else
    passwd "$user"
  fi
  # Copy root key if present
  if [[ -f /root/.ssh/authorized_keys ]]; then
    install -d -m 700 "/home/$user/.ssh"; cp /root/.ssh/authorized_keys "/home/$user/.ssh/authorized_keys"; chown -R "$user:$user" "/home/$user/.ssh"; chmod 600 "/home/$user/.ssh/authorized_keys"; ok "SSH key copied"
  fi
}

harden_sshd() {
  info "Hardening SSHD"
  local cfg="/etc/ssh/sshd_config"; cp -a "$cfg" "${cfg}.bak.$(date +%s)"
  sed -ri 's/^#?PermitRootLogin.*/PermitRootLogin no/' "$cfg"
  sed -ri 's/^#?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$cfg"
  sed -ri 's/^#?PasswordAuthentication.*/PasswordAuthentication no/' "$cfg"
  $ALLOW_SSH_PASSWORDS && sed -ri 's/^#?PasswordAuthentication.*/PasswordAuthentication yes/' "$cfg"
  if ! grep -q '^MaxAuthTries' "$cfg"; then echo 'MaxAuthTries 3' >> "$cfg"; else sed -ri 's/^#?MaxAuthTries.*/MaxAuthTries 3/' "$cfg"; fi
  sed -ri 's/^#?UsePAM.*/UsePAM yes/' "$cfg"
  systemctl reload ssh || systemctl restart ssh || true
}

valid_ipv4() { local ip="$1"; [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1; IFS='.' read -r a b c d <<<"$ip"; for o in $a $b $c $d; do [[ $o -ge 0 && $o -le 255 ]] || return 1; done; }

setup_firewall() {
  info "Configuring UFW"
  command -v ufw >/dev/null 2>&1 || ensure_packages ufw
  # SSH rule
  if [[ -n "$CLIENT_IP_RESTRICT" && "$CLIENT_IP_RESTRICT" != "YOUR_PUBLIC_IP" ]] && valid_ipv4 "$CLIENT_IP_RESTRICT"; then
    ufw allow from "$CLIENT_IP_RESTRICT" to any port 22 proto tcp || true
  else
    ufw allow OpenSSH || true
  fi
  # RDP rule
  if [[ -n "$CLIENT_IP_RESTRICT" && "$CLIENT_IP_RESTRICT" != "YOUR_PUBLIC_IP" ]] && valid_ipv4 "$CLIENT_IP_RESTRICT"; then
    ufw allow from "$CLIENT_IP_RESTRICT" to any port 3389 proto tcp || true
  else
    ufw allow 3389/tcp || true
  fi
  # Rate limits
  ufw limit OpenSSH || true
  ufw limit 3389/tcp || true
  yes | ufw enable || true
  ufw status || true
}

setup_swap() {
  local size="$1"; [[ -z "$size" ]] && return 0
  info "Configuring swap ($size)"
  swapon --show | grep -q '/swapfile' && { warn "Swap exists"; return 0; }
  fallocate -l "$size" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$(echo "$size" | sed 's/G/000/')
  chmod 600 /swapfile; mkswap /swapfile; swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
}

install_docker() {
  $NO_DOCKER && { warn "Skipping Docker"; return 0; }
  info "Installing Docker + Compose + Portainer"
  ensure_packages ca-certificates curl gnupg
  fix_docker_repo; apt_update_retry
  install_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  systemctl is-active --quiet docker && ok "Docker active" || { fail "Docker inactive"; systemctl status docker || true; }
  docker volume create portainer_data >/dev/null 2>&1 || true
  docker ps --format '{{.Names}}' | grep -q '^portainer$' || docker run -d --name portainer --restart=always -p 9000:9000 -p 9443:9443 -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest || true
}

install_chrome() {
  $NO_CHROME && { warn "Skipping Chrome"; return 0; }
  info "Installing Chrome"
  local deb=/tmp/google-chrome-stable_current_amd64.deb
  curl -fSL -o "$deb" https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  apt-get install -y "$deb" || { apt-get -f install -y; apt-get install -y "$deb"; }
}

install_vscode() {
  $SKIP_VSCODE && { warn "Skipping VS Code"; return 0; }
  info "Installing VS Code"
  fix_vscode_repo; apt_update_retry
  if ! install_packages code; then
    warn "VS Code repo failed; using .deb fallback"
    local code_deb=/tmp/vscode_latest_amd64.deb
    curl -fL -o "$code_deb" https://update.code.visualstudio.com/latest/linux-deb-x64/stable
    apt-get install -y "$code_deb" || { apt-get -f install -y; apt-get install -y "$code_deb"; }
  fi
}

setup_fail2ban() {
  info "Configuring Fail2Ban"
  ensure_packages fail2ban
  local ignore_ips="127.0.0.1/8 ::1"; [[ -n "$CLIENT_IP_RESTRICT" && "$CLIENT_IP_RESTRICT" != "YOUR_PUBLIC_IP" ]] && ignore_ips+=" $CLIENT_IP_RESTRICT"
  cat > /etc/fail2ban/jail.local <<J
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd
ignoreip = ${ignore_ips}
J
  # SSH jail
  cat > /etc/fail2ban/jail.d/sshd.local <<'J'
[sshd]
enabled  = true
port     = ssh
filter   = sshd
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
action   = ufw[blocktype=reject]
J
  # XRDP filter (create if missing)
  [[ -f /etc/fail2ban/filter.d/xrdp-sesman.conf ]] || cat > /etc/fail2ban/filter.d/xrdp-sesman.conf <<'F'
[Definition]
failregex = ^.*xrdp-sesman\[.*\]: .*login failed for user .* from <HOST>.*$
            ^.*xrdp-sesman\[.*\]: PAM auth error: Authentication failure.* from <HOST>.*$
ignoreregex =
F
  # XRDP jail
  cat > /etc/fail2ban/jail.d/xrdp.local <<'J'
[xrdp-sesman]
enabled  = true
port     = 3389
filter   = xrdp-sesman
logpath  = /var/log/syslog
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
action   = ufw[blocktype=reject]
J
  # Recidive
  cat > /etc/fail2ban/jail.d/recidive.local <<'J'
[recidive]
enabled  = true
logpath  = /var/log/fail2ban.log
bantime  = 1d
findtime = 1d
maxretry = 5
action   = ufw[blocktype=reject]
J
  systemctl enable --now fail2ban; sleep 1
}

summary() {
  echo; echo "===================== SUMMARY ====================="
  echo "OS: $(. /etc/os-release; echo "$PRETTY_NAME")  Kernel: $(uname -r)"
  echo "User: ${USERNAME:-<unchanged>}"
  echo "RDP: 3389 (XRDP $(systemctl is-active xrdp || true))"
  echo "Firewall:"; ufw status || true
  echo "Fail2Ban jails:"; fail2ban-client status 2>/dev/null | sed -n '1,20p' || true
  command -v docker >/dev/null 2>&1 && { echo "Docker: $(docker --version)"; docker ps --format 'running: {{.Names}}' || true; }
  command -v google-chrome >/dev/null 2>&1 && google-chrome --version || true
  command -v code >/dev/null 2>&1 && code --version | head -n1 || true
  echo "===================================================="
}

main() {
  require_root; parse_args "$@"
  if ! is_supported_os; then fail "Unsupported OS (only Debian/Ubuntu)"; exit 1; fi
  info "This will set up: XRDP+XFCE, hardening (UFW+Fail2Ban), Docker(+Portainer), Chrome, VS Code."
  ask_confirm "Continue?" || { warn "Aborted"; exit 0; }

  # Preflight repo fixes
  fix_vscode_repo || true
  fix_docker_repo || true

  setup_basics
  setup_xrdp_xfce

  if [[ -z "$USERNAME" && $AUTO_YES == false ]]; then read -r -p "Workstation username (default: malikws): " USERNAME || true; fi
  USERNAME=${USERNAME:-malikws}
  create_user "$USERNAME"
  harden_sshd

  setup_firewall
  [[ -n "$CREATE_SWAP_SIZE" ]] && setup_swap "$CREATE_SWAP_SIZE"

  install_docker
  install_chrome
  install_vscode
  setup_fail2ban

  info "Final verification..."
  summary
  ok "One-click setup complete. RDP on 3389 ready."
}

main "$@"


