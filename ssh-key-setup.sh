#!/usr/bin/env bash

# Make prompts work even when run via: curl ... | bash
exec </dev/tty || { echo "No TTY available for prompts."; exit 1; }

echo "🔐 SSH Key Setup Wizard"

# Ask for username
read -rp "👤 Enter username [default: root]: " user
user=${user:-root}

# Determine home directory
if [ "$user" = "root" ]; then
  home_dir="/root"
else
  home_dir="/home/$user"
fi

# Ask for SSH public key
read -rp "📋 Paste your SSH public key: " ssh_key

# Create .ssh directory
mkdir -p "$home_dir/.ssh"

# Add key to authorized_keys
echo "$ssh_key" >> "$home_dir/.ssh/authorized_keys"

# Set permissions
chmod 700 "$home_dir/.ssh"
chmod 600 "$home_dir/.ssh/authorized_keys"
chown -R "$user:$user" "$home_dir/.ssh"

# Ask to disable password login
read -rp "🚫 Disable password login for SSH? (y/n): " disable_pwd
if [[ "$disable_pwd" =~ ^[Yy]$ ]]; then
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  systemctl restart sshd
  echo "✅ Password login disabled."
fi

echo "🎉 SSH setup complete for user '$user'."
