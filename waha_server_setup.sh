#!/bin/bash

# WAHA Server Automated Setup Script
# This script replicates a complete WAHA (WhatsApp HTTP API) server setup

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}" >&2
}

warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

info() {
    echo -e "${BLUE}[INFO] $1${NC}"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root. Use: sudo $0"
        exit 1
    fi
}

# Collect user inputs
collect_inputs() {
    echo ""
    info "=== WAHA Server Setup Configuration ==="
    echo ""
    
    # Domain configuration
    read -p "Enter your domain name (e.g., api.yourdomain.com): " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        error "Domain name is required!"
        exit 1
    fi
    
    # Email for SSL certificate
    read -p "Enter your email address for SSL certificate: " EMAIL
    if [[ -z "$EMAIL" ]]; then
        error "Email is required for SSL certificate!"
        exit 1
    fi
    
    # Dashboard username (optional, default provided)
    read -p "Enter dashboard username [default: waha_admin]: " DASHBOARD_USER
    DASHBOARD_USER=${DASHBOARD_USER:-waha_admin}
    
    # Generate secure passwords
    DASHBOARD_PASSWORD=$(openssl rand -base64 32)
    SWAGGER_PASSWORD=$(openssl rand -base64 32)
    API_KEY=$(openssl rand -hex 32)
    
    info "Auto-generated secure credentials (save these!):"
    echo "Dashboard Password: $DASHBOARD_PASSWORD"
    echo "Swagger Password: $SWAGGER_PASSWORD"
    echo "API Key: $API_KEY"
    echo ""
    read -p "Press Enter to continue after saving these credentials..."
    
    # Confirmation
    echo ""
    info "=== Configuration Summary ==="
    echo "Domain: $DOMAIN"
    echo "Email: $EMAIL"
    echo "Dashboard User: $DASHBOARD_USER"
    echo "Setup will create a production-ready WAHA server with SSL, security, and monitoring."
    echo ""
    read -p "Continue with installation? (y/n): " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        info "Installation cancelled."
        exit 0
    fi
}

# Update system
update_system() {
    log "Updating system packages..."
    apt update && apt upgrade -y
    log "System updated successfully"
}

# Install essential packages
install_essentials() {
    log "Installing essential packages..."
    apt install -y curl wget git nano ufw software-properties-common \
        apt-transport-https ca-certificates gnupg lsb-release apache2-utils
    log "Essential packages installed"
}

# Configure firewall
configure_firewall() {
    log "Configuring firewall..."
    ufw allow ssh
    ufw allow 80
    ufw allow 443
    ufw --force enable
    log "Firewall configured and enabled"
}

# Install Docker and Docker Compose
install_docker() {
    log "Installing Docker..."
    
    # Add Docker repository
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Install Docker
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    
    # Start and enable Docker
    systemctl start docker
    systemctl enable docker
    
    # Verify installation
    docker --version
    docker compose version
    
    log "Docker installed successfully"
}

# Install and configure Nginx
install_nginx() {
    log "Installing and configuring Nginx..."
    
    apt install -y nginx
    systemctl start nginx
    systemctl enable nginx
    
    # Test Nginx
    if curl -s http://localhost > /dev/null; then
        log "Nginx installed and running successfully"
    else
        error "Nginx installation failed"
        exit 1
    fi
}

# Setup WAHA
setup_waha() {
    log "Setting up WAHA..."
    
    # Create WAHA directory
    mkdir -p /root/waha
    cd /root/waha
    
    # Create docker-compose.yaml
    cat > docker-compose.yaml << 'COMPOSE_EOF'
# https://waha.devlike.pro/docs/how-to/install/
services:
  waha:
    restart: always
    # WAHA Core
    image: devlikeapro/waha:latest

    logging:
      driver: 'json-file'
      options:
        max-size: '100m'
        max-file: '10'

    ports:
      - '127.0.0.1:3000:3000/tcp'

    volumes:
      # Store sessions in the .sessions folder
      - './sessions:/app/.sessions'
      # Save media files
      - './.media:/app/.media'

    env_file:
      - .env

volumes:
  mongodb_data: {}
  minio_data: {}
  pg_data: {}
COMPOSE_EOF
    
    # Create .env configuration file
    cat > .env << ENV_EOF
# WAHA Configuration
WAHA_BASE_URL=https://$DOMAIN

# Security - API Authentication
WHATSAPP_API_KEY=$API_KEY

# Dashboard Authentication
WAHA_DASHBOARD_ENABLED=true
WAHA_DASHBOARD_USERNAME=$DASHBOARD_USER
WAHA_DASHBOARD_PASSWORD=$DASHBOARD_PASSWORD

# Swagger Documentation Authentication
WHATSAPP_SWAGGER_USERNAME=swagger_admin
WHATSAPP_SWAGGER_PASSWORD=$SWAGGER_PASSWORD

# Logging
WAHA_LOG_FORMAT=JSON
WAHA_LOG_LEVEL=info

# Engine
WHATSAPP_DEFAULT_ENGINE=WEBJS

# Sessions
WAHA_PRINT_QR=False

# Media - Local Storage
WAHA_MEDIA_STORAGE=LOCAL
WHATSAPP_FILES_LIFETIME=0
WHATSAPP_FILES_FOLDER=/app/.media
ENV_EOF
    
    # Start WAHA temporarily for initial setup
    docker compose up -d
    
    # Wait for WAHA to start
    sleep 10
    
    # Verify WAHA is running
    if docker compose ps | grep -q "Up"; then
        log "WAHA started successfully"
    else
        error "WAHA failed to start"
        docker compose logs
        exit 1
    fi
}

# Main execution
main() {
    echo ""
    echo "==========================================="
    echo "       WAHA Server Automated Setup"
    echo "==========================================="
    echo ""
    
    check_root
    collect_inputs
    
    log "Starting WAHA server setup..."
    
    update_system
    install_essentials
    configure_firewall
    install_docker
    install_nginx
    setup_waha
    
    log "Basic setup completed! Additional configuration needed for SSL and security."
    echo ""
    info "Credentials:"
    echo "• Dashboard User: $DASHBOARD_USER"
    echo "• Dashboard Password: $DASHBOARD_PASSWORD"
    echo "• API Key: $API_KEY"
    echo "• Swagger Password: $SWAGGER_PASSWORD"
}

# Run main function
main "$@"
