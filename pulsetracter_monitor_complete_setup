#!/bin/bash
# ==========================================================
# 🚀 Pulse Tracker Professional v7.0 - Auto Deployment Script
# ==========================================================
# Author  : ChatGPT Deployment Engine
# Purpose : Full automated deployment for Pulse Tracker Pro
# Path    : /var/www/html/public_html/pulse_tracker_pro
# ==========================================================

set -e

# -----------------------------
# 🧩 INITIAL VARIABLES
# -----------------------------
APP_NAME="pulsetrackerpro"
INSTALL_DIR="/var/www/html/public_html/pulse_tracker_pro"
LOG_DIR="/var/log/pulsetracker"
PM2_PROCESS="pulsetrackerpro"
DOMAIN_NAME="pulsetracker.net"
NGINX_CONF="/etc/nginx/sites-available/pulsetracker.net"
ENV_FILE="$INSTALL_DIR/.env"

echo ""
echo "=========================================================="
echo "🚀 Starting Pulse Tracker Professional v7.0 Deployment"
echo "=========================================================="
sleep 1

# -----------------------------
# 🧠 PREPARATION
# -----------------------------
echo "📦 Preparing directories..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/utils"
mkdir -p "$INSTALL_DIR/frontend"
mkdir -p "$LOG_DIR"

# Secure log folder
chmod 700 "$LOG_DIR"

# -----------------------------
# 🧾 CLEAN OLD VERSION
# -----------------------------
if pm2 list | grep -q "$PM2_PROCESS"; then
  echo "🧹 Stopping existing PM2 process..."
  pm2 stop "$PM2_PROCESS" || true
  pm2 delete "$PM2_PROCESS" || true
fi

if [ -f "$NGINX_CONF" ]; then
  echo "🧹 Cleaning old Nginx configuration..."
  rm -f "$NGINX_CONF"
fi

echo "🧩 Clearing old installation files..."
rm -rf "$INSTALL_DIR"/*
sleep 1

# -----------------------------
# ⚙️ CREATE BACKEND FILES
# -----------------------------
echo "🧠 Creating backend files..."

cat > "$INSTALL_DIR/server.js" <<'EOF'
const express = require("express");
const cors = require("cors");
const http = require("http");
const socketIo = require("socket.io");
const dotenv = require("dotenv");
const { checkAllServers } = require("./utils/healthCheck");
const { initDB } = require("./utils/db");
const { sendAlertEmail, sendDailySummary } = require("./utils/emailService");
const fs = require("fs");
const path = require("path");
const cron = require("node-cron");

dotenv.config();

const app = express();
app.use(cors());
app.use(express.json());

const server = http.createServer(app);
const io = socketIo(server, {
  cors: { origin: "*" }
});

const PORT = process.env.PORT || 3000;
const REFRESH_INTERVAL = parseInt(process.env.REFRESH_INTERVAL || "10000", 10);
const ALERT_DOWN_HOURS = parseInt(process.env.ALERT_DOWN_HOURS || "1", 10);

const LOG_DIR = "/var/log/pulsetracker";
if (!fs.existsSync(LOG_DIR)) fs.mkdirSync(LOG_DIR, { recursive: true });
const appLog = fs.createWriteStream(path.join(LOG_DIR, "app.log"), { flags: "a" });
const errLog = fs.createWriteStream(path.join(LOG_DIR, "error.log"), { flags: "a" });

function log(type, msg) {
  const time = new Date().toISOString().replace("T", " ").substring(0, 19);
  const line = \`[\${time}] [\${type}] \${msg}\n\`;
  if (type === "ERROR") errLog.write(line); else appLog.write(line);
  console.log(line.trim());
}

(async () => {
  await initDB();
  log("SYSTEM", "✅ Database initialized successfully.");
})();

// Serve frontend
app.use(express.static(path.join(__dirname, "frontend")));

app.get("/api/health", (req, res) => {
  res.json({ status: "ok", time: new Date().toLocaleTimeString() });
});

io.on("connection", (socket) => {
  log("SOCKET", "🟢 Dashboard connected.");
});

setInterval(async () => {
  try {
    const updates = await checkAllServers(io, ALERT_DOWN_HOURS, log);
    io.emit("update", updates);
  } catch (e) {
    log("ERROR", e.message);
  }
}, REFRESH_INTERVAL);

// Daily summary at midnight
cron.schedule("0 0 * * *", () => {
  sendDailySummary(log);
});

server.listen(PORT, () => {
  log("SYSTEM", \`🚀 Pulse Tracker Pro running on port \${PORT}\`);
});
EOF

# -----------------------------
# ⚙️  UTILITY MODULES
# -----------------------------
echo "🧩 Writing utility modules..."

# --- Database utility ---
cat > "$INSTALL_DIR/utils/db.js" <<'EOF'
const mysql = require("mysql2/promise");
const dotenv = require("dotenv");
dotenv.config();

let pool;

async function initDB() {
  if (!pool) {
    pool = mysql.createPool({
      host: process.env.DB_HOST,
      user: process.env.DB_USER,
      password: process.env.DB_PASS,
      database: process.env.DB_NAME,
      port: process.env.DB_PORT || 3306,
      waitForConnections: true,
      connectionLimit: 10,
    });
  }
  return pool;
}

async function query(sql, params) {
  const connection = await pool.getConnection();
  try {
    const [rows] = await connection.execute(sql, params);
    return rows;
  } finally {
    connection.release();
  }
}

module.exports = { initDB, query };
EOF

# --- Health-check logic ---
cat > "$INSTALL_DIR/utils/healthCheck.js" <<'EOF'
const { query } = require("./db");
const { sendAlertEmail } = require("./emailService");
const axios = require("axios");

async function checkAllServers(io, alertDownHours, log) {
  const servers = await query("SELECT * FROM servers");
  const results = [];

  for (const s of servers) {
    let status = "DOWN";
    let cpu = 0, ram = 0;

    try {
      const res = await axios.get(`http://${s.ip_address}:3000/api/health`, { timeout: 5000 });
      if (res.status === 200) status = "UP";
      cpu = res.data.cpuLoad || 0;
      ram = res.data.memory || 0;
    } catch {
      status = "DOWN";
    }

    const now = new Date();
    await query(
      "INSERT INTO server_checks (server_id, status, check_time) VALUES (?, ?, ?)",
      [s.id, status, now]
    );

    if (status === "DOWN") {
      const downFor = await query(
        "SELECT TIMESTAMPDIFF(HOUR, down_since, NOW()) as diff FROM server_checks WHERE server_id=? AND down_since IS NOT NULL ORDER BY id DESC LIMIT 1",
        [s.id]
      );
      if (downFor.length && downFor[0].diff >= alertDownHours) {
        await sendAlertEmail(s.server_name, s.ip_address, downFor[0].diff, log);
      }
    }

    results.push({
      id: s.id,
      name: s.server_name,
      ip: s.ip_address,
      status,
      cpu,
      ram,
      checked: now.toLocaleTimeString(),
    });
  }

  return results;
}

module.exports = { checkAllServers };
EOF

# --- Email service ---
cat > "$INSTALL_DIR/utils/emailService.js" <<'EOF'
const nodemailer = require("nodemailer");
const { query } = require("./db");
const dotenv = require("dotenv");
dotenv.config();

const transporter = nodemailer.createTransport({
  host: process.env.SMTP_HOST,
  port: process.env.SMTP_PORT,
  secure: false,
  auth: {
    user: process.env.SMTP_USER,
    pass: process.env.SMTP_PASS,
  },
});

async function sendAlertEmail(serverName, ip, hours, log) {
  const msg = {
    from: process.env.FROM_EMAIL,
    to: process.env.ADMIN_EMAIL,
    subject: `🚨 Server DOWN: ${serverName}`,
    text: `Server ${serverName} (${ip}) has been DOWN for ${hours} hours.`,
  };
  try {
    await transporter.sendMail(msg);
    log("ALERT", `📧 Alert email sent for ${serverName}`);
  } catch (err) {
    log("ERROR", `Failed to send email: ${err.message}`);
  }
}

async function sendDailySummary(log) {
  try {
    const stats = await query(
      "SELECT server_name, status, MAX(check_time) as last_check FROM servers s JOIN server_checks c ON s.id=c.server_id GROUP BY s.id"
    );
    let body = "Daily Server Summary:\n\n";
    for (const s of stats) {
      body += `${s.server_name}: ${s.status} (Last check: ${s.last_check})\n`;
    }
    const msg = {
      from: process.env.FROM_EMAIL,
      to: process.env.ADMIN_EMAIL,
      subject: "📅 Daily Pulse Tracker Summary",
      text: body,
    };
    await transporter.sendMail(msg);
    log("SYSTEM", "📧 Daily summary email sent.");
  } catch (err) {
    log("ERROR", "Failed daily summary email: " + err.message);
  }
}

module.exports = { sendAlertEmail, sendDailySummary };
EOF

# --- Frontend UI ---
echo "🎨 Writing frontend files..."
cat > "$INSTALL_DIR/frontend/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>Pulse Tracker Pro v7.0</title>
<link rel="stylesheet" href="style.css" />
<script src="https://cdn.socket.io/4.5.4/socket.io.min.js"></script>
</head>
<body>
  <h1>💓 Pulse Tracker Pro Dashboard</h1>
  <div id="servers"></div>
  <script src="script.js"></script>
</body>
</html>
EOF

cat > "$INSTALL_DIR/frontend/script.js" <<'EOF'
const socket = io();
const box = document.getElementById("servers");

socket.on("update", (servers) => {
  box.innerHTML = servers.map(s => `
    <div class="server-card ${s.status}">
      <h3>${s.name} (${s.ip})</h3>
      <p>Status: ${s.status}</p>
      <p>CPU: ${s.cpu}% | RAM: ${s.ram}%</p>
      <small>Checked: ${s.checked}</small>
    </div>
  `).join("");
});
EOF

cat > "$INSTALL_DIR/frontend/style.css" <<'EOF'
body { font-family: sans-serif; background: #0d1117; color: #e6edf3; text-align:center; }
h1 { color: #58a6ff; }
.server-card { border: 1px solid #30363d; border-radius: 10px; padding:10px; margin:10px; display:inline-block; width:220px; }
.UP { background: #152a18; color:#00ff80; }
.DOWN { background: #2a1515; color:#ff6060; }
EOF
# -----------------------------
# END OF PART 2
# -----------------------------
# -----------------------------
# ⚙️  CREATE ENV FILE
# -----------------------------
echo "🧾 Creating environment configuration..."

cat > "$ENV_FILE" <<EOF
# --- Pulse Tracker Pro Environment ---
PORT=3000
REFRESH_INTERVAL=10000
ALERT_DOWN_HOURS=1

# --- MySQL ---
DB_HOST=localhost
DB_PORT=3306
DB_USER=pulse_tracker_user
DB_PASS=PulseTracker2024!@#
DB_NAME=pulse_tracker_professional

# --- SMTP ---
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=malik.g72@gmail.com
SMTP_PASS=pijn fpik lfrq fksk
FROM_EMAIL=malik.g72@gmail.com
ADMIN_EMAIL=malik.g72@gmail.com
EOF

chmod 600 "$ENV_FILE"

# -----------------------------
# ⚙️ INSTALL DEPENDENCIES
# -----------------------------
echo "📦 Installing dependencies..."
cd "$INSTALL_DIR"
npm init -y >/dev/null 2>&1
npm install express cors dotenv mysql2 nodemailer axios socket.io node-cron --save

# -----------------------------
# 🧩 NGINX CONFIGURATION
# -----------------------------
echo "🌐 Configuring Nginx..."

cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN_NAME www.$DOMAIN_NAME;

    root $INSTALL_DIR/frontend;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }

    access_log /var/log/nginx/pulsetracker_access.log;
    error_log /var/log/nginx/pulsetracker_error.log;
}
EOF

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/pulsetracker.net
nginx -t && systemctl reload nginx

# -----------------------------
# 🧩 PM2 SETUP
# -----------------------------
echo "🧠 Configuring PM2..."
pm2 stop "$PM2_PROCESS" >/dev/null 2>&1 || true
pm2 delete "$PM2_PROCESS" >/dev/null 2>&1 || true
pm2 start server.js --name "$PM2_PROCESS" --cwd "$INSTALL_DIR"
pm2 save
pm2 startup systemd -u root --hp /root

# -----------------------------
# 🔁 LOG ROTATION
# -----------------------------
echo "🌀 Setting up weekly log rotation..."
cat > /etc/logrotate.d/pulsetracker <<'EOF'
/var/log/pulsetracker/*.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 640 root adm
    sharedscripts
    postrotate
        pm2 reload all > /dev/null 2>&1 || true
    endscript
}
EOF

# -----------------------------
# 🧠 HEALTH VERIFICATION
# -----------------------------
echo "✅ Checking health endpoint..."
sleep 3
if curl -s http://127.0.0.1:3000/api/health | grep -q '"status":"ok"'; then
  echo "🎯 Deployment successful!"
else
  echo "⚠️  Warning: API did not respond as expected."
fi

echo ""
echo "=========================================================="
echo "🎉 Pulse Tracker Professional v7.0 is now deployed!"
echo "Dashboard: https://$DOMAIN_NAME"
echo "PM2 Name : $PM2_PROCESS"
echo "Logs     : /var/log/pulsetracker/"
echo "=========================================================="
EOF
