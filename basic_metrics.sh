#!/bin/bash

# Installationsscript för Prometheus-monitoringstack på Ubuntu VPS (t.ex. Hetzner Cloud)
# Detta script är generellt och återanvändbart. Det frågar efter nödvändig input och installerar:
# - Docker och Docker Compose
# - Nginx som reverse proxy för säker åtkomst
# - Certbot för HTTPS via Let's Encrypt
# - Prometheus, Node Exporter, Grafana, Loki och Promtail via Docker Compose
#
# Förutsättningar:
# - Kör som root (sudo -i) på en frisk Ubuntu 22.04+ VPS.
# - Domännamn pekat mot VPS:ns IP (A-record).
# - Portar 80 och 443 öppna i firewall (scriptet hanterar UFW).
#
# Användning: Kör ./install-monitoring.sh och följ prompts.
# Återanvändning: Kopiera och kör på ny VPS, anpassa variabler om behövs.

# Färger för output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Funktion för att visa fel och avsluta
function error_exit {
    echo -e "${RED}Fel: $1${NC}" >&2
    exit 1
}

# Kontrollera om körs som root
if [ "$EUID" -ne 0 ]; then
    error_exit "Scriptet måste köras som root (använd sudo)."
fi

# Uppdatera systemet
echo -e "${YELLOW}Uppdaterar systemet...${NC}"
apt update && apt upgrade -y || error_exit "Kunde inte uppdatera systemet."

# Installera grundläggande paket
apt install -y curl wget git ufw || error_exit "Kunde inte installera grundpaket."

# Fråga efter input
read -p "Ange domännamn för Grafana/Prometheus (t.ex. monitoring.dindoman.se): " DOMAIN
if [ -z "$DOMAIN" ]; then
    error_exit "Domännamn krävs."
fi

read -p "Ange e-post för Let's Encrypt (för certifikatnotiser): " EMAIL
if [ -z "$EMAIL" ]; then
    error_exit "E-post krävs för Let's Encrypt."
fi

read -p "Ange mapp för installation (standard: /opt/monitoring): " INSTALL_DIR
INSTALL_DIR=${INSTALL_DIR:-/opt/monitoring}
mkdir -p "$INSTALL_DIR" || error_exit "Kunde inte skapa mapp: $INSTALL_DIR"

# Installera Docker
echo -e "${YELLOW}Installerar Docker...${NC}"
apt install -y docker.io || error_exit "Kunde inte installera Docker."
systemctl start docker
systemctl enable docker

# Installera Docker Compose
echo -e "${YELLOW}Installerar Docker Compose...${NC}"
apt install -y docker-compose || error_exit "Kunde inte installera Docker Compose."

# Sätta upp UFW firewall
echo -e "${YELLOW}Konfigurerar firewall (UFW)...${NC}"
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
ufw status

# Installera Nginx och Certbot
echo -e "${YELLOW}Installerar Nginx och Certbot för HTTPS...${NC}"
apt install -y nginx certbot python3-certbot-nginx || error_exit "Kunde inte installera Nginx/Certbot."

# Konfigurera Nginx reverse proxy
cat <<EOF > /etc/nginx/sites-available/monitoring
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    location / {
        proxy_pass http://localhost:3000;  # Grafana
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /prometheus/ {
        proxy_pass http://localhost:9090/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -s /etc/nginx/sites-available/monitoring /etc/nginx/sites-enabled/ || error_exit "Kunde inte aktivera Nginx-site."
nginx -t && systemctl restart nginx || error_exit "Nginx-konfiguration felaktig."

# Hämta HTTPS-certifikat
echo -e "${YELLOW}Hämtar Let's Encrypt-certifikat...${NC}"
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "$EMAIL" --redirect || error_exit "Kunde inte hämta certifikat."

# Skapa Docker Compose-fil
echo -e "${YELLOW}Skapar Docker Compose-konfiguration i $INSTALL_DIR...${NC}"
cd "$INSTALL_DIR"

cat <<EOF > docker-compose.yml
version: '3.8'
services:
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    volumes:
      - ./prometheus:/etc/prometheus
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
    ports:
      - '9090:9090'
    restart: unless-stopped

  node-exporter:
    image: prom/node-exporter:latest
    container_name: node-exporter
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      - '--collector.filesystem.ignored-mount-points=^/(sys|proc|dev|host|etc)($|/)'
    ports:
      - '9100:9100'
    restart: unless-stopped

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    volumes:
      - grafana_data:/var/lib/grafana
    ports:
      - '3000:3000'
    depends_on:
      - prometheus
    restart: unless-stopped

  loki:
    image: grafana/loki:latest
    container_name: loki
    volumes:
      - ./loki:/etc/loki
    command: -config.file=/etc/loki/loki-config.yaml
    ports:
      - '3100:3100'
    restart: unless-stopped

  promtail:
    image: grafana/promtail:latest
    container_name: promtail
    volumes:
      - ./promtail:/etc/promtail
      - /var/log:/var/log:ro
    command: -config.file=/etc/promtail/promtail-config.yaml
    depends_on:
      - loki
    restart: unless-stopped

volumes:
  prometheus_data:
  grafana_data:
EOF

# Skapa konfigurationsmappar och filer
mkdir -p prometheus loki promtail

cat <<EOF > prometheus/prometheus.yml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'node'
    static_configs:
      - targets: ['node-exporter:9100']
EOF

cat <<EOF > loki/loki-config.yaml
auth_enabled: false
server:
  http_listen_port: 3100
ingester:
  lifecycler:
    address: 127.0.0.1
    ring:
      kvstore:
        store: inmemory
      replication_factor: 1
schema_config:
  configs:
    - from: 2020-10-24
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h
storage_config:
  tsdb_shipper:
    active_index_directory: /tmp/loki/tsdb-index
    cache_location: /tmp/loki/tsdb-cache
    cache_ttl: 24h
  filesystem:
    directory: /tmp/loki/chunks
limits_config:
  reject_old_samples: true
  reject_old_samples_max_age: 168h
chunk_store_config:
  max_look_back_period: 0s
table_manager:
  retention_deletes_enabled: false
  retention_period: 0s
EOF

cat <<EOF > promtail/promtail-config.yaml
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://loki:3100/loki/api/v1/push

scrape_configs:
  - job_name: system
    static_configs:
      - targets:
          - localhost
        labels:
          job: varlogs
          __path__: /var/log/*log
EOF

# Starta Docker Compose
echo -e "${YELLOW}Startar monitoringstacken...${NC}"
docker-compose up -d || error_exit "Kunde inte starta Docker Compose."

# Slutmeddelande
echo -e "${GREEN}Installation klar!${NC}"
echo "Åtkomst:"
echo "- Grafana: https://$DOMAIN (standardinlogg: admin/admin)"
echo "- Prometheus: https://$DOMAIN/prometheus/"
echo "Konfigurera Grafana: Lägg till Prometheus[](http://prometheus:9090) och Loki[](http://loki:3100) som datakällor."
echo "För att återanvända: Kopiera detta script och kör på ny VPS."
