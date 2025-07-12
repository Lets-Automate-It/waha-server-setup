#!/bin/bash

# WAHA Server Automated Setup Script
# This script replicates a complete WAHA (WhatsApp HTTP API) server setup
# Adjusted to include Nginx Reverse Proxy and SSL with Certbot for subdomain setup

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
    read -p "Enter your full domain name (e.g., api.yourdomain.com): " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        error "Domain name is required!"
        exit 1
    fi
    
    # Email for SSL certificate
    read -p "Enter your email address for SSL certificate (e.g., certadmin@yourdomain.com): " EMAIL
    if [[ -z "$EMAIL" ]]; then
        error "Email is required for SSL certificate!"
        exit 1
    fi
    
    # Dashboard username (optional, default provided)
    read -p "Enter dashboard username [default: waha_admin]: " DASHBOARD_USER
    DASHBOARD_USER=${DASHBOARD_USER:-waha_admin}
    
    # Generate secure passwords
    DASHBOARD_PASSWORD=$(openssl rand -base64 32 | tr -d '\n\r=+/' | cut -c1-20) # Shorter, URL-safe
    SWAGGER_PASSWORD=$(openssl rand -base64 32 | tr -d '\n\r=+/' | cut -c1-20)   # Shorter, URL-safe
    API_KEY=$(openssl rand -hex 32)
    
    info "Auto-generated secure credentials (SAVE THESE CAREFULLY!):"
    echo -e "${YELLOW}Dashboard Username: $DASHBOARD_USER${NC}"
    echo -e "${YELLOW}Dashboard Password: $DASHBOARD_PASSWORD${NC}"
    echo -e "${YELLOW}Swagger Username: swagger_admin${NC}"
    echo -e "${YELLOW}Swagger Password: $SWAGGER_PASSWORD${NC}"
    echo -e "${YELLOW}API Key: $API_KEY${NC}"
    echo ""
    read -p "Press Enter to continue AFTER you have saved these credentials in a secure place..."
    
    # Confirmation
    echo ""
    info "=== Configuration Summary ==="
    echo "Domain: $DOMAIN"
    echo "Email for SSL: $EMAIL"
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
        apt-transport-https ca-certificates gnupg lsb-release apache2-utils certbot python3-certbot-nginx
    log "Essential packages installed"
}

# Configure firewall
configure_firewall() {
    log "Configuring firewall..."
    ufw allow ssh
    ufw allow http # Allow port 80 for Certbot validation
    ufw allow https # Allow port 443 for SSL
    ufw --force enable
    log "Firewall configured and enabled"
}

# Install Docker and Docker Compose
install_docker() {
    log "Installing Docker..."
    
    # Add Docker repository (using a more modern approach if possible, but current one is still common)
    if [[ ! -f "/usr/share/keyrings/docker-archive-keyring.gpg" ]]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    fi
    
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
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

    # Create Nginx server block for WAHA
    log "Creating Nginx configuration for $DOMAIN..."
    cat > "/etc/nginx/sites-available/$DOMAIN" <<NGINX_CONF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location / {
        # Proxy to WAHA Docker container
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    # Optional: Basic authentication for /swagger and /dashboard if desired (Certbot will add SSL)
    # location /swagger {
    #     auth_basic "Swagger Restricted Access";
    #     auth_basic_user_file /etc/nginx/.htpasswd_swagger;
    #     proxy_pass http://127.0.0.1:3000/swagger;
    #     # ... other proxy headers ...
    # }

    # location /dashboard {
    #     auth_basic "Dashboard Restricted Access";
    #     auth_basic_user_file /etc/nginx/.htpasswd_dashboard;
    #     proxy_pass http://127.0.0.1:3000/dashboard;
    #     # ... other proxy headers ...
    # }
}
NGINX_CONF

    # Enable the Nginx site
    ln -s "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/"
    
    # Test Nginx configuration
    nginx -t
    if [ $? -eq 0 ]; then
        log "Nginx configuration for $DOMAIN is valid."
    else
        error "Nginx configuration for $DOMAIN is invalid. Check /etc/nginx/sites-available/$DOMAIN"
        exit 1
    fi
    
    systemctl reload nginx
    log "Nginx configured for WAHA."
}

# Setup WAHA
setup_waha() {
    log "Setting up WAHA..."
    
    # Create WAHA directory
    mkdir -p /opt/waha # Using /opt for application data
    cd /opt/waha
    
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
      # Bind to localhost so Nginx can proxy, and WAHA is not directly exposed
      - '127.0.0.1:3000:3000/tcp' 

    volumes:
      # Store sessions in the .sessions folder
      - './sessions:/app/.sessions'
      # Save media files
      - './.media:/app/.media'

    env_file:
      - .env

volumes:
  mongodb_data: {} # Not used by default WAHA, but often included in examples
  minio_data: {}   # Not used by default WAHA, but often included in examples
  pg_data: {}      # Not used by default WAHA, but often included in examples
COMPOSE_EOF
    
    # Create .env configuration file
    cat > .env << ENV_EOF
# WAHA Configuration
# WAHA_BASE_URL is now handled by Nginx proxy
# WAHA_BASE_URL=https://$DOMAIN 

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
    
    # Start WAHA
    log "Starting WAHA Docker containers..."
    docker compose up -d
    
    # Wait for WAHA to start
    sleep 15 # Give WAHA a bit more time to fully initialize
    
    # Verify WAHA is running
    if docker compose ps | grep -q "Up"; then
        log "WAHA started successfully and is listening on 127.0.0.1:3000"
    else
        error "WAHA failed to start. Check docker compose logs."
        docker compose logs
        exit 1
    fi
}

# Install SSL certificate with Certbot
install_ssl() {
    log "Installing SSL certificate for $DOMAIN using Certbot..."
    
    # Ensure Nginx is running and configured correctly before Certbot
    systemctl status nginx > /dev/null || systemctl start nginx

    # Remove default Nginx welcome page, as it can interfere with Certbot
    if [ -f "/etc/nginx/sites-enabled/default" ]; then
        rm "/etc/nginx/sites-enabled/default"
        systemctl reload nginx
    fi
    
    # Attempt to obtain certificate
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "$EMAIL"
    
    if [ $? -eq 0 ]; then
        log "SSL certificate obtained and configured successfully for $DOMAIN"
        log "Certificates are renewed automatically by Certbot."
    else
        error "Failed to obtain SSL certificate for $DOMAIN. Check Certbot logs for details."
        error "You may need to ensure your DNS A record for $DOMAIN points to this server's public IP."
        exit 1
    fi
    
    # Reload Nginx to ensure SSL config is active
    systemctl reload nginx
}

# Main execution
main() {
    echo ""
    echo "==========================================="
    echo "       WAHA Server Automated Setup"
    echo " (with Nginx Reverse Proxy & SSL/Certbot)"
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
    install_ssl
    
    log "WAHA server setup completed successfully!"
    echo ""
    info "Access your WAHA server securely at: https://$DOMAIN"
    echo ""
    info "Remember your credentials:"
    echo "• Dashboard URL: https://$DOMAIN/dashboard"
    echo "  Username: $DASHBOARD_USER"
    echo "  Password: $DASHBOARD_PASSWORD"
    echo ""
    echo "• API Key (for integrations): $API_KEY"
    echo ""
    echo "• Swagger UI (API Documentation): https://$DOMAIN/swagger"
    echo "  Username: swagger_admin"
    echo "  Password: $SWAGGER_PASSWORD"
    echo ""
    warning "Ensure your DNS A record for '$DOMAIN' points to this server's public IP address."
    info "If you encounter issues, check firewall rules (ufw status) and Docker/Nginx logs."
}

# Run main function
main "$@"
