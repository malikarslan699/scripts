#!/bin/bash
exec </dev/tty

echo "🔐 SSH Key Setup Wizard"

read -rp "👤 Enter username [default: root]: " user
user=${user:-root}

if [ "$user" = "root" ]; then
  home_dir="/root"
else
  home_dir="/home/$user"
fi

read -rp "📋 Paste your SSH public key: " ssh_key

mkdir -p "$home_dir/.ssh"
echo "$ssh_key" >> "$home_dir/.ssh/authorized_keys"
chmod 700 "$home_dir/.ssh"
chmod 600 "$home_dir/.ssh/authorized_keys"
chown -R "$user:$user" "$home_dir/.ssh"

read -rp "🚫 Disable password login for SSH? (y/n): " disable_pwd
if [[ "$disable_pwd" =~ ^[Yy]$ ]]; then
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  systemctl restart sshd
  echo "✅ Password login disabled."
fi

echo "🎉 SSH setup complete for user '$user'."
