cat <<'EOF' > setup.sh
#!/bin/bash

echo "🔐 SSH Key Setup Wizard"

# Ask for username
read -p "👤 Enter username [default: root]: " user
user=${user:-root}

# Determine home directory
if [ "$user" == "root" ]; then
  home_dir="/root"
else
  home_dir="/home/$user"
fi

# Ask for SSH public key
read -p "📋 Paste your SSH public key: " ssh_key

# Create .ssh directory
mkdir -p "$home_dir/.ssh"

# Add key to authorized_keys
echo "$ssh_key" >> "$home_dir/.ssh/authorized_keys"

# Set permissions
chmod 700 "$home_dir/.ssh"
chmod 600 "$home_dir/.ssh/authorized_keys"
chown -R "$user:$user" "$home_dir/.ssh"

# Ask to disable password login
read -p "🚫 Disable password login for SSH? (y/n): " disable_pwd
if [[ "$disable_pwd" =~ ^[Yy]$ ]]; then
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  systemctl restart sshd
  echo "✅ Password login disabled."
fi

echo "🎉 SSH setup complete for user '$user'."
EOF
