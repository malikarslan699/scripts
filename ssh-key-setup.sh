#!/bin/bash

echo "🔐 SSH Key Setup Wizard"

read -p "👤 Enter username [default: root]: " user
user=${user:-root}

if [ "$user" == "root" ]; then
  home_dir="/root"
else
  home_dir="/home/$user"
fi

# Force prompt even when piped
echo -n "📋 Paste your SSH public key: "
read ssh_key < /dev/tty

mkdir -p "$home_dir/.ssh"
echo "$ssh_key" >> "$home_dir/.ssh/authorized_keys"
chmod 700 "$home_dir/.ssh"
chmod 600 "$home_dir/.ssh/authorized_keys"
chown -R "$user:$user" "$home_dir/.ssh"

read -p "🚫 Disable password login for SSH? (y/n): " disable_pwd < /dev/tty
if [[ "$disable_pwd" =~ ^[Yy]$ ]]; then
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  systemctl restart sshd
  echo "✅ Password login disabled."
fi

echo "🎉 SSH setup complete for user '$user'."
