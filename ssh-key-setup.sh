#!/bin/bash
set -euo pipefail

echo "🔐 SSH Key Setup Wizard"
echo

# Input username (default root)
read -rp "👤 Enter username [default: root]: " user
user=${user:-root}
if [ "$user" = "root" ]; then
  home_dir="/root"
else
  home_dir="/home/$user"
fi

# Input SSH public key (allow multi-line paste)
echo "📋 Paste your SSH public key and press Enter (Ctrl+D when done):"
ssh_key=""
while IFS= read -r line; do
  ssh_key+="${line}"$'\n'
done

# Validate non-empty key
if [ -z "$ssh_key" ]; then
  echo "❌ No key provided, aborting."
  exit 1
fi

# Ask for passphrase (optional - only once)
echo
read -rp "🔑 Enter passphrase for SSH key (optional, press Enter to skip): " -s passphrase
echo

# Setup authorized_keys
mkdir -p "$home_dir/.ssh"
echo "$ssh_key" > "$home_dir/.ssh/authorized_keys"
chmod 700 "$home_dir/.ssh"
chmod 600 "$home_dir/.ssh/authorized_keys"
chown -R "$user:$user" "$home_dir/.ssh"
echo "✅ SSH key added for $user at $home_dir/.ssh/authorized_keys"

# If passphrase provided, add it to SSH config
if [ -n "$passphrase" ]; then
  echo "🔐 Setting up passphrase authentication..."
  
  # Create or update SSH config
  ssh_config="$home_dir/.ssh/config"
  if [ ! -f "$ssh_config" ]; then
    touch "$ssh_config"
    chmod 600 "$ssh_config"
  fi
  
  # Add passphrase configuration
  cat >> "$ssh_config" << EOF

# Passphrase configuration
Host *
    AddKeysToAgent yes
    UseKeychain yes
    IdentitiesOnly yes
EOF
  
  echo "✅ Passphrase configuration added to SSH config"
fi

echo

# Option to disable password authentication
read -rp "🚫 Disable password login for SSH? (y/n): " disable_pwd
if [[ "$disable_pwd" =~ ^[Yy]$ ]]; then
  echo "🔧 Backing up /etc/ssh/sshd_config..."
  cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%s)

  # Edit or append directive
  if grep -q "^#\?PasswordAuthentication" /etc/ssh/sshd_config; then
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  else
    echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
  fi

  # Also disable ChallengeResponseAuthentication just in case
  if grep -q "^#\?ChallengeResponseAuthentication" /etc/ssh/sshd_config; then
    sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
  else
    echo "ChallengeResponseAuthentication no" >> /etc/ssh/sshd_config
  fi

  echo "🧪 Testing SSH config..."
  if sshd -t; then
    echo "✅ Config OK, restarting SSH..."
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || service ssh restart 2>/dev/null
    echo "🔒 Password login disabled."
  else
    echo "❌ SSH config test failed! Reverting backup..."
    cp /etc/ssh/sshd_config.bak.* /etc/ssh/sshd_config
  fi
fi

echo
echo "🎉 SSH setup complete for user '$user'."
if [ -n "$passphrase" ]; then
  echo "🔑 Passphrase authentication configured."
fi
echo "Try logging in using your private key now."
