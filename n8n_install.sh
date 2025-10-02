#!/bin/bash

# Optimal n8n Installation Script for Hetzner Cloud Ubuntu VPS
# Focus: Stability (error handling, healthchecks, restarts) and Autonomy (auto-backups, systemd)
# Requirements: Fresh Ubuntu 22.04/24.04 LTS; root access; domain pointed to VPS IP
# Usage: sudo bash install-n8n.sh

set -euo pipefail  # Enable strict error handling
trap 'echo "Error on line $LINENO"; exit 1' ERR

# Variables (prompt for user input)
read -p "Enter your domain (e.g., n8n.example.com): " DOMAIN
read -sp "Enter strong PostgreSQL password: " PG_PASS; echo
read -sp "Enter n8n encryption key (random string): " ENC_KEY; echo
read -sp "Enter basic auth user (default: admin): " AUTH_USER; AUTH_USER=${AUTH_USER:-admin}; echo
read -sp "Enter basic auth password: " AUTH_PASS; echo
EMAIL="your.email@example.com"  # Change to your email for Let's Encrypt

LOG_FILE="/var/log/n8n-install.log"
exec > >(tee -a "$LOG_FILE") 2>&1  # Log everything

echo "Starting n8n installation on Hetzner Ubuntu VPS..."

# Step 1: System Update and Dependencies
apt update && apt upgrade -y
apt install -y git ufw fail2ban curl gnupg software-properties-common

# Step 2: Install Docker and Compose (if not present)
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm get-docker.sh
fi
apt install -y docker-compose-plugin

# Step 3: Firewall Setup (allow SSH, HTTP/S)
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# Step 4: Clone Repo and Setup Directories
mkdir -p /opt/n8n
cd /opt/n8n
git clone https://github.com/n8n-io/n8n-docker-caddy.git .
mkdir -p backups

# Step 5: Configure Environment Variables
cat <<EOF > .env
CADDY_DOMAIN=$DOMAIN
N8N_HOST=$DOMAIN
N8N_PORT=5678
N8N_PROTOCOL=https
WEBHOOK_URL=https://$DOMAIN/
N8N_BASIC_AUTH_ACTIVE=true
N8N_BASIC_AUTH_USER=$AUTH_USER
N8N_BASIC_AUTH_PASSWORD=$AUTH_PASS
N8N_ENCRYPTION_KEY=$ENC_KEY
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=postgres
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=n8n
DB_POSTGRESDB_USER=n8n
DB_POSTGRESDB_PASSWORD=$PG_PASS
EXECUTIONS_MODE=queue
QUEUE_BULL_REDIS_HOST=redis
QUEUE_BULL_REDIS_PORT=6379
GENERIC_TIMEZONE=Europe/Berlin  # Adjust to your timezone
EOF

# Step 6: Docker Compose File with Postgres, Redis, Healthchecks
cat <<EOF > docker-compose.yml
version: '3.8'

services:
  caddy:
    image: caddy:2
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - caddy_data:/data
      - caddy_config:/config
      - ./caddy_config/Caddyfile:/etc/caddy/Caddyfile
    environment:
      - EMAIL=$EMAIL

  postgres:
    image: postgres:15
    restart: unless-stopped
    environment:
      POSTGRES_DB: n8n
      POSTGRES_USER: n8n
      POSTGRES_PASSWORD: $PG_PASS
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U n8n"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  n8n:
    image: n8nio/n8n:latest
    restart: unless-stopped
    env_file:
      - .env
    volumes:
      - n8n_data:/home/node/.n8n
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy

volumes:
  caddy_data:
  caddy_config:
  postgres_data:
  n8n_data:
EOF

# Step 7: Configure Caddyfile for Reverse Proxy
sed -i "s/your.domain.com/$DOMAIN/g" caddy_config/Caddyfile

# Step 8: Start Services
docker compose up -d

# Step 9: Setup Systemd for Autonomy
cat <<EOF > /etc/systemd/system/n8n.service
[Unit]
Description=n8n Service
After=docker.service

[Service]
WorkingDirectory=/opt/n8n
ExecStart=/usr/bin/docker compose up
ExecStop=/usr/bin/docker compose down
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable n8n.service
systemctl start n8n.service

# Step 10: Automated Backups (cron job)
cat <<EOF > /opt/n8n/backup.sh
#!/bin/bash
docker compose down
tar -czf /opt/n8n/backups/n8n_backup_\$(date +%Y%m%d).tar.gz /opt/n8n
docker compose up -d
EOF
chmod +x /opt/n8n/backup.sh
(crontab -l 2>/dev/null; echo "0 2 * * * /opt/n8n/backup.sh") | crontab -

# Step 11: Fail2ban for Security
jail_local="/etc/fail2ban/jail.local"
echo "[sshd]" > $jail_local
echo "enabled = true" >> $jail_local
systemctl restart fail2ban

echo "Installation complete! Access n8n at https://$DOMAIN. Credentials: $AUTH_USER / $AUTH_PASS"
echo "Logs: $LOG_FILE | Backups: /opt/n8n/backups"
