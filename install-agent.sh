#!/usr/bin/env bash
set -euo pipefail
if [[ $EUID -ne 0 ]]; then
  echo "[pulse-agent] Please run as root (sudo bash install-agent.sh ...)."
  exit 1
fi
PULSE_DIR="/opt/pulse-agent"
USER_NAME="pulseagent"
SERVICE_NAME="pulse-agent"
SERVER_NAME="${1:-PulseServer}"
echo "[pulse-agent] Preparing directories..."
mkdir -p "$PULSE_DIR"
chmod 750 "$PULSE_DIR"
if ! id -u "$USER_NAME" >/dev/null 2>&1; then
  useradd --system --home "$PULSE_DIR" --shell /usr/sbin/nologin "$USER_NAME"
fi
echo "[pulse-agent] Generating ed25519 key..."
KEY_PATH="$PULSE_DIR/id_ed25519"
if [[ -f "$KEY_PATH" ]]; then
  echo "[pulse-agent] Existing key detected; skipping regeneration."
else
  ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" >/dev/null
  chown "$USER_NAME":"$USER_NAME" "$KEY_PATH" "$KEY_PATH.pub"
  chmod 600 "$KEY_PATH"
  chmod 644 "$KEY_PATH.pub"
fi
REG_CODE=$(openssl rand -hex 8 | sed 's/\(..\)/\1-/g;s/-$//')
echo "$REG_CODE" > "$PULSE_DIR/registration.code"
cat > "$PULSE_DIR/agent.conf" <<CONF
NAME="$SERVER_NAME"
REGISTRATION_CODE="$REG_CODE"
CONF
chown "$USER_NAME":"$USER_NAME" "$PULSE_DIR/agent.conf" "$PULSE_DIR/registration.code"
echo "[pulse-agent] Installing placeholder systemd service..."
cat > /etc/systemd/system/${SERVICE_NAME}.service <<SERVICE
[Unit]
Description=Pulse Agent Placeholder
After=network.target
[Service]
Type=simple
User=$USER_NAME
WorkingDirectory=$PULSE_DIR
ExecStart=/bin/sh -c "while true; do sleep 3600; done"
Restart=always
[Install]
WantedBy=multi-user.target
SERVICE
systemctl daemon-reload
systemctl enable ${SERVICE_NAME}.service >/dev/null
systemctl restart ${SERVICE_NAME}.service
echo ""
echo "=============================================="
echo "Pulse Agent install complete!"
echo "Server Name : $SERVER_NAME"
echo "Registration Code: $REG_CODE"
echo "Copy this code into the Pulse Tracker panel to finish linking."
echo "Public Key:"
cat "$KEY_PATH.pub"
echo "=============================================="
