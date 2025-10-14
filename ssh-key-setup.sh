bash -lc '
# 🎨 Colors
RED=$(tput setaf 1); GRN=$(tput setaf 2); BLU=$(tput setaf 4); RST=$(tput sgr0)
ok(){ echo -e "$GRN[OK]$RST $1"; }
fail(){ echo -e "$RED[FAIL]$RST $1"; exit 1; }
i=1

echo "🔐 SSH Full Setup Wizard"
echo

# 🗝️ Step 1: Ask for SSH public key
read -rp "📋 Paste your SSH public key: " PUBKEY
[ -z "$PUBKEY" ] && fail "No SSH key provided!"

install -d -m700 /root/.ssh || fail "Failed to create ~/.ssh"
printf "%s\n" "$PUBKEY" | tr -d "\r" > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
chown -R root:root /root/.ssh
ok "$((i++)). Public key written to /root/.ssh/authorized_keys"

# 🧠 Step 2: Ask for password login preference
read -rp "🚫 Disable password login? (y/n): " DISABLE_PWD
if [[ "$DISABLE_PWD" =~ ^[Yy]$ ]]; then
  PASS_AUTH="no"
else
  PASS_AUTH="yes"
fi

# 🧱 Step 3: Backup main config
TS=$(date +%s)
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$TS && ok "$((i++)). Backed up sshd_config (.$TS)" || fail "$i. Backup failed"

# 🧹 Step 4: Clean duplicates from all configs
grep -Rl "PasswordAuthentication\|PubkeyAuthentication\|ChallengeResponseAuthentication\|PermitRootLogin\|AuthorizedKeysFile" /etc/ssh/ | xargs -r sed -i "/PasswordAuthentication\|PubkeyAuthentication\|ChallengeResponseAuthentication\|PermitRootLogin\|AuthorizedKeysFile/d"
ok "$((i++)). Cleaned old conflicting directives"

# 🪶 Step 5: Ensure Include directive
if ! grep -qE "Include[[:space:]]+/etc/ssh/sshd_config.d/\*" /etc/ssh/sshd_config; then
  echo "Include /etc/ssh/sshd_config.d/*.conf" >> /etc/ssh/sshd_config
  ok "$((i++)). Added Include directive"
else
  ok "$((i++)). Include directive already present"
fi

# 🧾 Step 6: Write fresh drop-in config
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-keyonly.conf <<EOF
# Managed automatically
PasswordAuthentication $PASS_AUTH
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
EOF
ok "$((i++)). Wrote /etc/ssh/sshd_config.d/99-keyonly.conf"

# 🧩 Step 7: Ensure /run/sshd
install -d -m0755 -o root -g root /run/sshd && ok "$((i++)). Ensured /run/sshd"

# 🧪 Step 8: Test and restart SSH
if sshd -t; then
  ok "$((i++)). Config test passed"
else
  fail "$i. SSH config test failed"
fi

systemctl daemon-reload >/dev/null 2>&1 || true
(systemctl restart sshd 2>/dev/null || systemctl restart ssh) && ok "$((i++)). SSH service restarted" || fail "$i. Restart failed"

# 🧾 Step 9: Final values
echo -e "$BLU--- Effective SSH Values ---$RST"
sshd -T 2>/dev/null | awk "/^pubkeyauthentication|^passwordauthentication|^challengeresponseauthentication|^permitrootlogin/ {printf \"  %s\n\", \$0}"
echo
ok "✅ All done! Try SSH key login now."
'
