#!/usr/bin/env bash

# ================================================================
# server_setup.sh – Förbättrad automatiserad installation för Ubuntu Server
# Optimerad för intelliforge.io med säkerhetsförbättringar
# ================================================================

set -euo pipefail
IFS=$'\n\t'

# -------- Färgade logg-hjälpfunktioner --------------------------
info()  { echo -e "\e[32m[INFO]\e[0m  $*"; }
warn()  { echo -e "\e[33m[WARN]\e[0m  $*"; }
error() { echo -e "\e[31m[ERROR]\e[0m $*" >&2; }
die()   { error "$1"; exit 1; }
success() { echo -e "\e[92m[SUCCESS]\e[0m $*"; }

# -------- Root-kontroll ----------------------------------------
[[ $EUID -ne 0 ]] && die "Kör skriptet som root eller med sudo."

# -------- Standardvärden ---------------------------------------
DOMAIN_NAME="${DOMAIN_NAME:-intelliforge.io}"
TRUSTED_IP="${TRUSTED_IP:-}"
ENABLE_COCKPIT=false
INSTALL_GPU=false
ASSUME_YES=false
INSTALL_MONITORING=true
BACKUP_ENCRYPTION=true

# Config-filer
SECRETS_FILE="/root/.server-secrets"
BACKUP_CONFIG="/root/.backup-config"
SERVICES_CONFIG="/root/.services-config"

# -------- Flagghantering ---------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--domain)      DOMAIN_NAME="$2"; shift 2 ;;
        -t|--trusted-ip)  TRUSTED_IP="$2"; shift 2 ;;
        --cockpit)        ENABLE_COCKPIT=true; shift ;;
        --gpu)            INSTALL_GPU=true; shift ;;
        --no-monitoring)  INSTALL_MONITORING=false; shift ;;
        -y|--yes)         ASSUME_YES=true; shift ;;
        -h|--help)        show_help; exit 0 ;;
        *) die "Okänd flagga: $1" ;;
    esac
done

show_help() {
    cat << EOF
Användning: $0 [ALTERNATIV]

ALTERNATIV:
    -d, --domain DOMÄN     Domän för servern (standard: intelliforge.io)
    -t, --trusted-ip IP    Trusted IP/CIDR för SSH-åtkomst
    --cockpit              Aktivera Cockpit web-admin
    --gpu                  Installera Intel GPU-drivrutiner
    --no-monitoring        Hoppa över monitoring-stack
    -y, --yes              Kör utan interaktiva frågor
    -h, --help             Visa denna hjälp

Exempel:
    $0 --domain intelliforge.io --trusted-ip 192.168.1.0/24 -y
EOF
}

# -------- Säkerhetshantering -----------------------------------
generate_secure_password() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-25
}

create_secrets_file() {
    info "Skapar säkra lösenord och konfiguration..."
    
    # Skapa secrets-fil
    cat > "$SECRETS_FILE" << EOF
# Genererade lösenord - $(date)
POSTGRES_PASSWORD=$(generate_secure_password)
REDIS_PASSWORD=$(generate_secure_password)
CODE_SERVER_PASSWORD=$(generate_secure_password)
PORTAINER_PASSWORD=$(generate_secure_password)
BACKUP_PASSPHRASE=$(generate_secure_password)
DOMAIN_NAME=$DOMAIN_NAME
TRUSTED_IP=$TRUSTED_IP
EOF
    
    chmod 600 "$SECRETS_FILE"
    success "Säkra lösenord skapade i $SECRETS_FILE"
}

# -------- Retry-logik för nätverksoperationer ------------------
retry_command() {
    local cmd="$1"
    local max_attempts=3
    local delay=5
    
    for i in $(seq 1 $max_attempts); do
        if eval "$cmd"; then
            return 0
        fi
        
        if [[ $i -lt $max_attempts ]]; then
            warn "Kommando misslyckades (försök $i/$max_attempts), försöker igen om ${delay}s..."
            sleep $delay
        fi
    done
    
    error "Kommando misslyckades efter $max_attempts försök: $cmd"
    return 1
}

# -------- Apt-basics -------------------------------------------
install_basics() {
    info "Uppdaterar paketindex och installerar grundpaket..."
    
    retry_command "apt-get update"
    
    apt-get install -y --no-install-recommends \
        curl gnupg ca-certificates lsb-release git ufw fail2ban \
        software-properties-common python3-pip python3-venv \
        htop ncdu tree jq borgbackup logrotate \
        apt-transport-https
    
    success "Grundpaket installerade"
}

# -------- Docker med säkerhet ----------------------------------
install_docker() {
    if ! command -v docker &>/dev/null; then
        info "Installerar Docker CE..."
        
        install -m 0755 -d /etc/apt/keyrings
        
        retry_command "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
        
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        retry_command "apt-get update"
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        
        systemctl enable --now docker
        
        # Lägg till användare i docker-gruppen
        if [[ -n "${SUDO_USER:-}" ]]; then
            usermod -aG docker "$SUDO_USER"
        fi
        
        success "Docker installerat och konfigurerat"
    fi
    
    # Skapa nätverk
    docker network create backend 2>/dev/null || true
    docker network create frontend 2>/dev/null || true
    
    install_docker_services
}

install_docker_services() {
    source "$SECRETS_FILE"
    
    info "Installerar Portainer..."
    docker volume create portainer_data >/dev/null 2>&1 || true
    docker run -d --name portainer --restart=always \
        -p 8000:8000 -p 9443:9443 \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v portainer_data:/data \
        --network backend \
        portainer/portainer-ce:latest || warn "Portainer kanske redan körs"
    
    info "Installerar Watchtower..."
    docker run -d --name watchtower --restart=always \
        -v /var/run/docker.sock:/var/run/docker.sock \
        --network backend \
        containrrr/watchtower --label-enable --cleanup --interval 43200 || warn "Watchtower kanske redan körs"
    
    success "Docker-tjänster installerade"
}

# -------- Databaser med säkerhet -------------------------------
install_databases() {
    source "$SECRETS_FILE"
    
    info "Installerar PostgreSQL..."
    docker volume create pg_data >/dev/null 2>&1 || true
    docker run -d --name postgres --restart=always \
        -e POSTGRES_USER=admin \
        -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
        -e POSTGRES_DB=app \
        -v pg_data:/var/lib/postgresql/data \
        --network backend \
        postgres:16-alpine || warn "PostgreSQL kanske redan körs"
    
    info "Installerar Redis..."
    docker run -d --name redis --restart=always \
        --network backend \
        redis:alpine redis-server --requirepass "$REDIS_PASSWORD" || warn "Redis kanske redan körs"
    
    success "Databaser installerade med säkra lösenord"
}

# -------- Nginx Proxy Manager ----------------------------------
install_nginx_proxy() {
    info "Installerar Nginx Proxy Manager..."
    
    docker volume create npm_data >/dev/null 2>&1 || true
    docker volume create npm_ssl >/dev/null 2>&1 || true
    
    docker run -d --name nginx-proxy-manager --restart=always \
        -p 80:80 -p 443:443 -p 81:81 \
        -v npm_data:/data \
        -v npm_ssl:/etc/letsencrypt \
        --network frontend \
        --network backend \
        jc21/nginx-proxy-manager:latest || warn "Nginx Proxy Manager kanske redan körs"
    
    success "Nginx Proxy Manager installerat"
}

# -------- Code Server -------------------------------------------
install_code_server() {
    source "$SECRETS_FILE"
    
    info "Installerar code-server..."
    
    docker volume create code_data >/dev/null 2>&1 || true
    docker run -d --name code-server --restart=always \
        -p 8443:8443 \
        -e PASSWORD="$CODE_SERVER_PASSWORD" \
        -v code_data:/home/coder/project \
        -v /var/run/docker.sock:/var/run/docker.sock \
        --network backend \
        codercom/code-server:latest || warn "Code-server kanske redan körs"
    
    success "Code-server installerat"
}

# -------- Övervakningsstack -------------------------------------
install_monitoring() {
    [[ $INSTALL_MONITORING == false ]] && return
    
    info "Installerar övervakningsstack..."
    
    # Prometheus
    docker volume create prometheus_data >/dev/null 2>&1 || true
    docker run -d --name prometheus --restart=always \
        -p 9090:9090 \
        -v prometheus_data:/prometheus \
        --network backend \
        prom/prometheus:latest || warn "Prometheus kanske redan körs"
    
    # Node Exporter
    docker run -d --name node-exporter --restart=always \
        -p 9100:9100 \
        --network backend \
        --pid="host" \
        -v "/:/host:ro,rslave" \
        prom/node-exporter:latest \
        --path.rootfs=/host || warn "Node Exporter kanske redan körs"
    
    # Grafana
    docker volume create grafana_data >/dev/null 2>&1 || true
    docker run -d --name grafana --restart=always \
        -p 3000:3000 \
        -v grafana_data:/var/lib/grafana \
        --network backend \
        grafana/grafana:latest || warn "Grafana kanske redan körs"
    
    success "Övervakningsstack installerad"
}

# -------- Säkerhetskonfiguration -------------------------------
configure_security() {
    info "Konfigurerar säkerhet..."
    
    # UFW
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    
    # Grundläggande portar
    ufw allow 22/tcp comment "SSH"
    ufw allow 80/tcp comment "HTTP"
    ufw allow 443/tcp comment "HTTPS"
    
    # Trusted IP för alla tjänster
    if [[ -n "$TRUSTED_IP" ]]; then
        ufw allow from "$TRUSTED_IP" to any port 22 proto tcp comment "SSH från trusted IP"
        ufw allow from "$TRUSTED_IP" to any port 9443 proto tcp comment "Portainer från trusted IP"
        ufw allow from "$TRUSTED_IP" to any port 8443 proto tcp comment "Code-server från trusted IP"
        ufw allow from "$TRUSTED_IP" to any port 3000 proto tcp comment "Grafana från trusted IP"
        ufw allow from "$TRUSTED_IP" to any port 9090 proto tcp comment "Prometheus från trusted IP"
        ufw allow from "$TRUSTED_IP" to any port 81 proto tcp comment "NPM Admin från trusted IP"
    fi
    
    # Cockpit om aktiverat
    if [[ $ENABLE_COCKPIT == true ]]; then
        ufw allow 9090/tcp comment "Cockpit"
    fi
    
    yes | ufw enable
    
    # Fail2ban
    systemctl enable --now fail2ban
    
    # Automatiska uppdateringar
    apt-get install -y unattended-upgrades apt-listchanges
    echo 'Unattended-Upgrade::Automatic-Reboot "false";' > /etc/apt/apt.conf.d/50unattended-upgrades
    echo 'Unattended-Upgrade::AutoFixInterruptedDpkg "true";' >> /etc/apt/apt.conf.d/50unattended-upgrades
    
    success "Säkerhetskonfiguration klar"
}

# -------- Backup med systemd -----------------------------------
setup_backup() {
    source "$SECRETS_FILE"
    
    info "Konfigurerar backup-system..."
    
    # Backup-konfiguration
    cat > "$BACKUP_CONFIG" << EOF
BACKUP_SRC="/var/lib/docker/volumes"
BACKUP_DST="/opt/backups/borg-repo"
BORG_PASSPHRASE="$BACKUP_PASSPHRASE"
BORG_RELOCATED_REPO_ACCESS_IS_OK=yes
EOF
    chmod 600 "$BACKUP_CONFIG"
    
    # Skapa backup-mapp
    mkdir -p /opt/backups /opt/backup
    
    # Backup-skript
    cat > /opt/backup/backup.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Läs konfiguration
source /root/.backup-config

# Logga till systemd journal
exec > >(systemd-cat -t backup-service) 2>&1

echo "Startar backup - $(date)"

# Initiera repository om det inte finns
if ! borg info "$BACKUP_DST" &>/dev/null; then
    echo "Initialiserar backup-repository..."
    borg init --encryption=repokey "$BACKUP_DST"
fi

# Skapa backup
echo "Skapar backup..."
borg create --stats --compression zstd \
    --exclude-caches \
    --exclude '*/cache/*' \
    --exclude '*/tmp/*' \
    --exclude '*/logs/*' \
    "$BACKUP_DST::$(date +%Y-%m-%d_%H-%M)" \
    "$BACKUP_SRC"

# Rensa gamla backups
echo "Rensar gamla backups..."
borg prune -v --stats "$BACKUP_DST" \
    --keep-daily=7 \
    --keep-weekly=4 \
    --keep-monthly=6 \
    --keep-yearly=2

echo "Backup klar - $(date)"
EOF
    
    chmod +x /opt/backup/backup.sh
    
    # Systemd service
    cat > /etc/systemd/system/backup.service << EOF
[Unit]
Description=Daily backup service
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/opt/backup/backup.sh
User=root
Environment=HOME=/root
EOF
    
    # Systemd timer
    cat > /etc/systemd/system/backup.timer << EOF
[Unit]
Description=Daily backup timer
Requires=backup.service

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=3600

[Install]
WantedBy=timers.target
EOF
    
    systemctl daemon-reload
    systemctl enable --now backup.timer
    
    success "Backup-system konfigurerat med systemd"
}

# -------- Utvecklingsstack -------------------------------------
install_dev_stacks() {
    info "Installerar utvecklingsverktyg..."
    
    # Python venv
    mkdir -p /opt/venvs
    python3 -m venv /opt/venvs/ai
    /opt/venvs/ai/bin/pip install --upgrade pip wheel setuptools
    
    # Node.js
    if ! command -v node &>/dev/null; then
        retry_command "curl -fsSL https://deb.nodesource.com/setup_20.x | bash -"
        apt-get install -y nodejs
    fi
    
    success "Utvecklingsverktyg installerade"
}

# -------- Intel GPU-drivrutiner --------------------------------
install_gpu_drivers() {
    [[ $INSTALL_GPU == false ]] && return
    
    info "Installerar Intel GPU-drivrutiner..."
    
    # Intel repository
    retry_command "curl -fsSL https://repositories.intel.com/graphics/intel-graphics.key | gpg --dearmor -o /etc/apt/keyrings/intel-graphics.gpg"
    
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/intel-graphics.gpg] https://repositories.intel.com/graphics/ubuntu $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/intel-graphics.list
    
    retry_command "apt-get update"
    apt-get install -y intel-oneapi-runtime-opencl mesa-va-drivers intel-media-va-driver
    
    success "Intel GPU-drivrutiner installerade"
}

# -------- Tjänste-översikt -------------------------------------
create_services_overview() {
    source "$SECRETS_FILE"
    
    cat > "$SERVICES_CONFIG" << EOF
# Tjänster installerade på $(hostname) - $(date)
DOMAIN: $DOMAIN_NAME
TRUSTED_IP: $TRUSTED_IP

TJÄNSTER:
========
Portainer:        https://$DOMAIN_NAME:9443 (eller IP:9443)
Nginx Proxy Mgr:  http://$DOMAIN_NAME:81 (eller IP:81)
Code-Server:      https://$DOMAIN_NAME:8443 (eller IP:8443)
Grafana:          http://$DOMAIN_NAME:3000 (eller IP:3000)
Prometheus:       http://$DOMAIN_NAME:9090 (eller IP:9090)

LÖSENORD:
=========
Code-Server:      $CODE_SERVER_PASSWORD
PostgreSQL:       admin / $POSTGRES_PASSWORD
Redis:            $REDIS_PASSWORD
Backup:           $BACKUP_PASSPHRASE

KOMMANDON:
==========
Visa backup-status:   systemctl status backup.timer
Kör backup manuellt:  systemctl start backup.service
Visa backup-loggar:   journalctl -u backup.service
Visa tjänster:        docker ps
UFW status:           ufw status
EOF
    
    chmod 600 "$SERVICES_CONFIG"
}

# -------- Logrotation -------------------------------------------
setup_logrotation() {
    info "Konfigurerar logrotation..."
    
    cat > /etc/logrotate.d/docker-containers << 'EOF'
/var/lib/docker/containers/*/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    copytruncate
    notifempty
}
EOF
    
    success "Logrotation konfigurerad"
}

# -------- Sammanfattning ---------------------------------------
show_summary() {
    source "$SECRETS_FILE"
    
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')
    
    success "Installation av $DOMAIN_NAME server klar!"
    echo
    echo "🚀 TILLGÄNGLIGA TJÄNSTER:"
    echo "========================"
    echo "Portainer (Container Management): https://$server_ip:9443"
    echo "Nginx Proxy Manager:              http://$server_ip:81"
    echo "Code-Server (Development):        https://$server_ip:8443"
    
    if [[ $INSTALL_MONITORING == true ]]; then
        echo "Grafana (Monitoring):             http://$server_ip:3000"
        echo "Prometheus (Metrics):             http://$server_ip:9090"
    fi
    
    echo
    echo "📋 VIKTIGA FILER:"
    echo "=================="
    echo "Lösenord och secrets:      $SECRETS_FILE"
    echo "Tjänste-översikt:          $SERVICES_CONFIG"
    echo "Backup-konfiguration:      $BACKUP_CONFIG"
    echo
    echo "🔧 NÄSTA STEG:"
    echo "=============="
    echo "1. Konfigurera SSL-certifikat i Nginx Proxy Manager"
    echo "2. Sätt upp domännamn för $DOMAIN_NAME"
    echo "3. Byt standardlösenord i Portainer"
    echo "4. Testa backup: systemctl start backup.service"
    echo "5. Kontrollera brandvägg: ufw status"
    echo
    echo "📚 DOKUMENTATION:"
    echo "=================="
    echo "Konfigurationsfil: $SERVICES_CONFIG"
    echo "Backup-status:     journalctl -u backup.service"
    echo "Docker-tjänster:   docker ps"
    echo
    warn "VIKTIGT: Spara lösenorden från $SECRETS_FILE på säker plats!"
}

# -------- Main --------------------------------------------------
main() {
    info "Startar automatiserad installation för $DOMAIN_NAME..."
    
    create_secrets_file
    install_basics
    install_docker
    install_databases
    install_nginx_proxy
    install_code_server
    install_monitoring
    configure_security
    install_dev_stacks
    setup_backup
    setup_logrotation
    install_gpu_drivers
    create_services_overview
    show_summary
    
    success "Alla komponenter installerade framgångsrikt!"
}

# Kör huvudfunktionen
main "$@"