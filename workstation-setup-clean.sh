#!/usr/bin/env bash

set -Eeuo pipefail
trap 'echo "[ERROR] Command failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

# Globals
AUTO_YES=false
CLIENT_IP_RESTRICT=""
CREATE_SWAP_SIZE=""  # e.g., 2G
USERNAME=""
ALLOW_SSH_PASSWORDS=false
XRDP_REPAIR=false
SKIP_VSCODE=false

GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; BLUE="\033[1;34m"; RESET="\033[0m"
ok() { echo -e "${GREEN}[OK]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
fail() { echo -e "${RED}[FAIL]${RESET} $*"; }
info() { echo -e "${BLUE}[INFO]${RESET} $*"; }

ask_confirm() {
  local prompt_msg=${1:-"Proceed?"}
  if $AUTO_YES; then info "$prompt_msg [auto-yes]"; return 0; fi
  read -r -p "$prompt_msg [Y/n]: " reply || true; reply=${reply:-Y}
  [[ ${reply} =~ ^[Yy]$ ]]
}

require_root() { if [[ $(id -u) -ne 0 ]]; then fail "Please run as root (use sudo)."; exit 1; fi; }

parse_args() {
  for arg in "$@"; do
    case "$arg" in
      -y|--yes) AUTO_YES=true;;
      --client-ip=*) CLIENT_IP_RESTRICT="${arg#*=}";;
      --swap-size=*) CREATE_SWAP_SIZE="${arg#*=}";;
      --username=*) USERNAME="${arg#*=}";;
      --allow-ssh-passwords) ALLOW_SSH_PASSWORDS=true;;
      --xrdp-repair) XRDP_REPAIR=true;;
      --skip-vscode) SKIP_VSCODE=true;;
      -h|--help)
        cat <<HELP
Usage: sudo ./workstation-setup-clean.sh [options]

Options:
  -y, --yes              Run non-interactively (auto-confirm steps)
  --client-ip=IP         Restrict RDP (3389) and SSH to this IP
  --swap-size=SIZE       Create swap file (e.g., 2G)
  --username=NAME        Create workstation user (default: prompt; e.g., malikws)
  --allow-ssh-passwords  Allow SSH password auth (default: key-only)
  --xrdp-repair          Reinstall XRDP core packages (repair)
  --skip-vscode          Skip installing VS Code (handle later manually)
  -h, --help             Show this help
HELP
        exit 0;;
      *) warn "Unknown option: $arg";;
    esac
  done
}

is_valid_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r o1 o2 o3 o4 <<<"$ip"
  for o in $o1 $o2 $o3 $o4; do
    [[ $o -ge 0 && $o -le 255 ]] || return 1
  done
  return 0
}

# Preflight repo fixes
fix_ms_code_repo_conflict() {
  info "Preflight: sanitizing VS Code repo definitions"
  install -m 0755 -d /etc/apt/keyrings /etc/apt/sources.list.d
  # Ensure canonical key
  [[ -f /etc/apt/keyrings/ms_vscode.gpg ]] || { curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/ms_vscode.gpg; chmod a+r /etc/apt/keyrings/ms_vscode.gpg; }
  # Comment any code repo lines inside main sources file
  sed -i -E 's|^[^#].*packages\.microsoft\.com.*/repos/code.*|# &|' /etc/apt/sources.list 2>/dev/null || true
  # Remove any .list/.sources files that reference the code repo
  while IFS= read -r -d '' f; do rm -f "$f" || true; done < <(grep -RIlZ "packages.microsoft.com/.*/repos/code" /etc/apt/sources.list.d 2>/dev/null || true)
  # Remove common leftover microsoft list files that may duplicate settings
  rm -f /etc/apt/sources.list.d/microsoft-prod.list /etc/apt/sources.list.d/code.list /etc/apt/sources.list.d/vscode.list.save 2>/dev/null || true
  # Write canonical repo entry
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/ms_vscode.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list
  ok "VS Code repo standardized"
}

fix_docker_repo_conflict() {
  info "Preflight: checking Docker repo for conflicts"
  local docker_repo_regex='^[^#].*download.docker.com/linux/ubuntu'
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  local src
  while IFS= read -r -d '' src; do
    if [[ "$src" == "/etc/apt/sources.list" ]]; then
      sed -i -E "s/${docker_repo_regex}/# \0/" "$src" || true
    else
      rm -f "$src" || true
    fi
  done < <(grep -RIlEz "${docker_repo_regex}" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true)
  local codename; codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable" > /etc/apt/sources.list.d/docker.list
  ok "Docker repo standardized"
}

wait_for_apt() {
  local retries=30 delay=2
  for i in $(seq 1 $retries); do
    if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
      warn "apt/dpkg is locked. Waiting ($i/$retries)..."; sleep $delay
    else
      return 0
    fi
  done
  fail "apt lock did not release in time"; return 1
}

apt_update_retry() {
  wait_for_apt
  local tries=5
  for i in $(seq 1 $tries); do
    info "apt update (try $i/$tries)"
    if apt-get update -y; then ok "apt update successful"; return 0; fi
    sleep 2
  done
  fail "apt update failed after retries"; return 1
}

install_packages() { wait_for_apt; DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; }
ensure_packages() { apt_update_retry; install_packages "$@"; }

setup_xrdp_xfce() {
  info "Installing XRDP + XFCE minimal..."
  if $XRDP_REPAIR; then
    info "Reinstalling XRDP core packages (repair)"
    apt_update_retry
    DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall xrdp xorgxrdp || true
  fi
  ensure_packages xrdp xfce4 xfce4-goodies xorgxrdp policykit-1-gnome dbus-x11
  echo startxfce4 > /etc/skel/.xsession
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    sudo -u "${SUDO_USER}" bash -c 'echo startxfce4 > "$HOME/.xsession"'
  else
    echo startxfce4 > "$HOME/.xsession"
  fi
  adduser xrdp ssl-cert || true
  systemctl enable --now xrdp; sleep 1
  systemctl is-active --quiet xrdp && ok "XRDP service is active" || { fail "XRDP service not active"; systemctl status xrdp || true; }
}

configure_firewall() {
  info "Configuring firewall (UFW)..."
  command -v ufw >/dev/null 2>&1 || ensure_packages ufw
  if [[ -n "$CLIENT_IP_RESTRICT" ]]; then ufw allow from "$CLIENT_IP_RESTRICT" to any port 22 proto tcp || true; else ufw allow OpenSSH || true; fi
  if [[ -n "$CLIENT_IP_RESTRICT" ]]; then ufw allow from "$CLIENT_IP_RESTRICT" to any port 3389 proto tcp || true; else warn "No --client-ip provided; allowing 3389 from ANY."; ufw allow 3389/tcp || true; fi
  yes | ufw enable || true
  ufw status || true
}

configure_ufw_rate_limits() {
  info "Applying UFW rate limits (anti-bruteforce)..."
  if [[ -z "$CLIENT_IP_RESTRICT" ]]; then yes | ufw delete allow OpenSSH >/dev/null 2>&1 || true; ufw limit OpenSSH || true; else yes | ufw delete allow OpenSSH >/dev/null 2>&1 || true; fi
  if [[ -z "$CLIENT_IP_RESTRICT" ]]; then ufw limit 3389/tcp || true; fi
  ufw status || true
}

create_user_and_keys() {
  local user="$1"
  if ! id "$user" >/dev/null 2>&1; then
    info "Creating user $user (sudo + docker)"
    adduser --disabled-password --gecos "" "$user"
    usermod -aG sudo "$user"; usermod -aG docker "$user" || true
    if $AUTO_YES; then
      local randpass
      # generate a random password safely without tr SIGPIPE causing pipefail
      set +o pipefail
      randpass=$(head -c 64 /dev/urandom | tr -dc 'A-Za-z0-9!@#$%^&*()_+=' | head -c 16)
      set -o pipefail
      if [[ -z "$randpass" ]]; then
        warn "Password generation fallback"
        randpass=$(date +%s | sha256sum | awk '{print $1}' | head -c 16)
      fi
      echo "$user:$randpass" | chpasswd
      info "Temporary password for $user: $randpass"
    else
      info "Set a strong password for $user"; passwd "$user"
    fi
  else
    info "User $user already exists"
  fi
  if [[ -f /root/.ssh/authorized_keys ]]; then
    install -d -m 700 "/home/$user/.ssh"; cp /root/.ssh/authorized_keys "/home/$user/.ssh/authorized_keys"; chown -R "$user:$user" "/home/$user/.ssh"; chmod 600 "/home/$user/.ssh/authorized_keys"; ok "Copied root authorized_keys to $user"
  else
    warn "No /root/.ssh/authorized_keys found; add an SSH key for $user"
  fi
}

harden_sshd() {
  info "Hardening SSHD (disable root login; configure auth)..."
  local cfg="/etc/ssh/sshd_config"; cp -a "$cfg" "${cfg}.bak.$(date +%s)"
  sed -ri 's/^#?PermitRootLogin.*/PermitRootLogin no/' "$cfg"
  sed -ri 's/^#?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$cfg"
  sed -ri 's/^#?PasswordAuthentication.*/PasswordAuthentication no/' "$cfg"
  $ALLOW_SSH_PASSWORDS && sed -ri 's/^#?PasswordAuthentication.*/PasswordAuthentication yes/' "$cfg"
  if ! grep -q '^MaxAuthTries' "$cfg"; then echo 'MaxAuthTries 3' >> "$cfg"; else sed -ri 's/^#?MaxAuthTries.*/MaxAuthTries 3/' "$cfg"; fi
  sed -ri 's/^#?UsePAM.*/UsePAM yes/' "$cfg"
  systemctl reload ssh || systemctl restart ssh || true
  ok "SSHD hardened (root login disabled)"
}

install_fail2ban_and_jails() {
  info "Installing and configuring Fail2Ban..."; ensure_packages fail2ban
  local ignore_ips="127.0.0.1/8 ::1"; [[ -n "$CLIENT_IP_RESTRICT" ]] && ignore_ips+=" $CLIENT_IP_RESTRICT"
  cat > /etc/fail2ban/jail.local <<JAILCONF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd
ignoreip = ${ignore_ips}
JAILCONF
  cat > /etc/fail2ban/jail.d/sshd.local <<'JAIL_SSHD'
[sshd]
enabled  = true
port     = ssh
filter   = sshd
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
action   = ufw[blocktype=reject]
JAIL_SSHD
  if [[ -f /etc/fail2ban/filter.d/xrdp-sesman.conf ]]; then
    cat > /etc/fail2ban/jail.d/xrdp.local <<'JAIL_XRDP'
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
JAIL_XRDP
  else
    warn "xrdp-sesman filter not found; skipping XRDP jail"
  fi
  systemctl enable --now fail2ban; sleep 1
  systemctl is-active --quiet fail2ban && ok "Fail2Ban service is active" || { fail "Fail2Ban service not active"; systemctl status fail2ban || true; }
}

setup_swap() {
  local size="$1"; [[ -z "$size" ]] && return 0
  info "Creating swap file ($size)..."
  if swapon --show | grep -q "/swapfile"; then warn "Swapfile already active; skipping"; return 0; fi
  fallocate -l "$size" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$(echo "$size" | sed 's/G/000/')
  chmod 600 /swapfile; mkswap /swapfile; swapon /swapfile
  grep -q "/swapfile" /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ok "Swap configured"
}

install_docker() {
  info "Installing Docker Engine + plugins..."
  apt_update_retry; install_packages ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  [[ -f /etc/apt/keyrings/docker.gpg ]] || { curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg; chmod a+r /etc/apt/keyrings/docker.gpg; }
  local codename; codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable" > /etc/apt/sources.list.d/docker.list
  apt_update_retry; install_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  systemctl is-active --quiet docker && ok "Docker service is active" || { fail "Docker service not active"; systemctl status docker || true; }
  # Pick a sensible user to add to docker group
  local target_user
  if [[ -n "$USERNAME" ]] && id "$USERNAME" >/dev/null 2>&1; then
    target_user="$USERNAME"
  elif [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
    target_user="$SUDO_USER"
  else
    target_user=""
  fi
  if [[ -n "$target_user" ]]; then
    usermod -aG docker "$target_user" || true
    info "Added $target_user to docker group"
  fi
}

install_portainer() {
  info "Deploying Portainer (Docker GUI)..."; command -v docker >/dev/null 2>&1 || { fail "Docker not installed; skipping Portainer"; return 1; }
  docker volume create portainer_data >/dev/null 2>&1 || true
  docker ps --format '{{.Names}}' | grep -q '^portainer$' || docker run -d --name portainer --restart=always -p 9000:9000 -p 9443:9443 -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest || true
  sleep 2; docker ps --format '{{.Names}}' | grep -q '^portainer$' && ok "Portainer container is running" || { fail "Portainer failed to start"; docker logs --tail 100 portainer || true; }
}

install_chrome() {
  info "Installing Google Chrome..."
  local deb=/tmp/google-chrome-stable_current_amd64.deb
  curl -fSL -o "$deb" https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  apt-get install -y "$deb" || { warn "Fixing broken deps for Chrome"; apt-get -f install -y; apt-get install -y "$deb"; }
  ok "Chrome installed"
}

install_vscode() {
  info "Installing VS Code..."
  if $SKIP_VSCODE; then
    warn "Skipping VS Code as requested (--skip-vscode)"
    return 0
  fi
  install -m 0755 -d /etc/apt/keyrings
  [[ -f /etc/apt/keyrings/ms_vscode.gpg ]] || { curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/ms_vscode.gpg; chmod a+r /etc/apt/keyrings/ms_vscode.gpg; }
  install -m 0755 -d /etc/apt/sources.list.d
  local code_repo_regex='^[^#].*packages.microsoft.com/.*/repos/code'
  local src
  while IFS= read -r -d '' src; do
    if [[ "$src" == "/etc/apt/sources.list" ]]; then sed -i -E "s/${code_repo_regex}/# \0/" "$src" || true; else rm -f "$src" || true; fi
  done < <(grep -RIlEz "${code_repo_regex}" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true)
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/ms_vscode.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list
  apt_update_retry || { warn "apt update failed; deep clean VS Code repo"; rm -f /etc/apt/sources.list.d/*microsoft* /etc/apt/sources.list.d/vscode*.list || true; sed -i -E "s/${code_repo_regex}/# \0/" /etc/apt/sources.list || true; echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/ms_vscode.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list; apt_update_retry || true; }
  install_packages code || { warn "Repo install failed; fallback to .deb"; local code_deb=/tmp/vscode_latest_amd64.deb; curl -fL -o "$code_deb" https://update.code.visualstudio.com/latest/linux-deb-x64/stable; apt-get install -y "$code_deb" || { apt-get -f install -y || true; apt-get install -y "$code_deb" || true; }; }
  command -v code >/dev/null 2>&1 && ok "VS Code installed" || warn "VS Code not detected after install attempts"
}

install_basics() {
  info "Installing basic tools (curl, git, htop, jq, iproute2, psmisc)..."
  ensure_packages curl git htop jq unzip ca-certificates iproute2 psmisc
}

verify_post_install() {
  info "Verifying services and ports..."; local errors=0
  systemctl is-active --quiet xrdp && ok "XRDP active" || { fail "XRDP inactive"; errors=$((errors+1)); }
  ss -lntup 2>/dev/null | grep -q ":3389" && ok "Port 3389 listening" || { fail "Port 3389 not listening"; errors=$((errors+1)); }
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && ok "Docker ready" || { fail "Docker not ready"; errors=$((errors+1)); }
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^portainer$' && ok "Portainer running" || warn "Portainer not running"
  command -v google-chrome >/dev/null 2>&1 && ok "Chrome installed" || warn "Chrome not found"
  command -v code >/dev/null 2>&1 && ok "VS Code installed" || warn "VS Code not found"
  command -v ufw >/dev/null 2>&1 && ufw status || true
  if command -v fail2ban-client >/dev/null 2>&1; then
    systemctl is-active --quiet fail2ban && ok "Fail2Ban active" || { fail "Fail2Ban inactive"; errors=$((errors+1)); }
    local jails; jails=$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/{print $2}' | xargs || true)
    [[ -n "$jails" ]] && info "Fail2Ban jails: $jails"
    echo "$jails" | grep -qw sshd || { fail "Fail2Ban sshd jail missing"; errors=$((errors+1)); }
  fi
  echo; [[ $errors -eq 0 ]] && ok "Primary checks passed" || fail "$errors check(s) failed"; return $errors
}

double_confirmation_summary() {
  echo; echo "===================== SUMMARY ====================="
  echo "Hostname: $(hostname)"; echo "OS: $(. /etc/os-release; echo "$PRETTY_NAME")"; echo "Kernel: $(uname -r)"
  echo "CPU: $(lscpu | awk -F: '/Model name/{gsub(/^ +/,"",$2); print $2; exit}')"; echo "CPUs: $(nproc)"
  echo "RAM: $(free -h | awk '/Mem:/ {print $2" total, " $7" available"}')"; echo "Swap: $(free -h | awk '/Swap:/ {print $2" total, " $4" free"}')"
  echo "IP addresses:"; ip -brief a || true; echo "Public IP: $(curl -fsS ifconfig.me || curl -fsS https://api.ipify.org || echo unknown)"
  echo "Listening ports (top):"; ss -lntup 2>/dev/null | head -n 20 || ss -lntu | head -n 20 || true
  echo "XRDP: $(systemctl is-active xrdp || true)"; echo "Docker: $(docker --version 2>/dev/null || echo not-installed)"
  echo "Portainer: $(docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^portainer$' && echo running || echo not-running)"
  echo "Chrome: $(command -v google-chrome >/dev/null 2>&1 && google-chrome --version || echo not-installed)"
  echo "VS Code: $(command -v code >/dev/null 2>&1 && code --version | head -n1 || echo not-installed)"
  echo "Firewall (UFW):"; ufw status || true
  if command -v fail2ban-client >/dev/null 2>&1; then
    echo "Fail2Ban: $(systemctl is-active fail2ban || true)"; echo -n "Jails: "; fail2ban-client status 2>/dev/null | awk -F: '/Jail list/{print $2}' | xargs || true
    echo "sshd banned count: $(fail2ban-client status sshd 2>/dev/null | awk -F: '/Currently banned/{print $2}' | xargs || echo 0)"
  fi
  echo "===================================================="
  if verify_post_install; then ok "Double confirmation: All key services are OK"; else fail "Double confirmation failed: see messages above"; fi
}

main() {
  require_root; parse_args "$@"
  info "This will set up: XRDP+XFCE, Docker (+Portainer), Chrome, VS Code, UFW, optional swap."
  ask_confirm "Continue with setup?" || { warn "Aborted by user"; exit 0; }
  # Preflight fixes (dedupe/standardize repos)
  fix_ms_code_repo_conflict || true; fix_docker_repo_conflict || true
  # Validate client IP early to avoid UFW errors
  if [[ -n "$CLIENT_IP_RESTRICT" ]]; then
    if ! is_valid_ipv4 "$CLIENT_IP_RESTRICT" || [[ "$CLIENT_IP_RESTRICT" == "YOUR_PUBLIC_IP" ]]; then
      warn "Invalid or placeholder --client-ip '$CLIENT_IP_RESTRICT'; falling back to ANY"
      CLIENT_IP_RESTRICT=""
    fi
  fi
  # Essentials
  install_basics
  setup_xrdp_xfce
  if [[ -z "$USERNAME" && $AUTO_YES == false ]]; then read -r -p "Enter workstation username (default: malikws): " USERNAME || true; fi
  USERNAME=${USERNAME:-malikws}; create_user_and_keys "$USERNAME"; harden_sshd
  # Firewall + optional swap
  if [[ -z "$CLIENT_IP_RESTRICT" && $AUTO_YES == false ]]; then read -r -p "Enter your client public IP to restrict RDP/SSH (or blank to allow any): " CLIENT_IP_RESTRICT || true; fi
  configure_firewall; configure_ufw_rate_limits
  if [[ -z "$CREATE_SWAP_SIZE" && $AUTO_YES == false ]]; then read -r -p "Create swap? Enter size like 2G (or leave blank to skip): " CREATE_SWAP_SIZE || true; fi
  [[ -n "$CREATE_SWAP_SIZE" ]] && setup_swap "$CREATE_SWAP_SIZE"
  # Apps
  install_docker; install_portainer; install_chrome; install_vscode; install_fail2ban_and_jails
  info "Running final verification..."; verify_post_install || true
  double_confirmation_summary
  ok "Setup complete. RDP port 3389 ready."; info "Portainer at https://<server-ip>:9443; re-login needed for docker group."
}

main "$@"


