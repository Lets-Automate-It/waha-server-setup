#!/bin/bash

# waha_server_setup.sh
# This script automates the installation of WAHA (WhatsApp HTTP API) on a VPS.
# It sets up Docker, Docker Compose, Nginx as a reverse proxy, and secures the application with Let's Encrypt SSL.

# --- Configuration Variables ---
WAHA_DIR="/opt/waha" # Directory where WAHA will be installed
NGINX_CONF_DIR="/etc/nginx/sites-available"
NGINX_SYMLINK_DIR="/etc/nginx/sites-enabled"
WAHA_PORT="3000" # Default WAHA port, as per documentation

# --- Functions ---

# Function to display messages
log_message() {
    echo "--- $1 ---"
}

# Function to display errors and exit
error_exit() {
    echo "ERROR: $1" >&2
    exit 1
}

# Function to display warnings
warn_message() {
    echo "WARNING: $1" >&2
}

# Check if script is run as root or with sudo
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run with sudo or as root."
    fi
}

# Validate domain format
validate_domain() {
    local domain="$1"
    
    # Basic format validation - more permissive for subdomains
    # Allows domains/subdomains starting with numbers or letters
    # Format: [subdomain.]domain.tld
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]; then
        error_exit "Invalid domain format: $domain. Please use format like: subdomain.domain.com"
    fi
    
    # Check DNS resolution
    log_message "Checking DNS resolution for $domain..."
    if ! nslookup "$domain" &>/dev/null; then
        warn_message "DNS resolution failed for $domain"
        echo "This might cause SSL certificate issuance to fail."
        read -p "Do you want to continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            error_exit "Aborted by user due to DNS resolution failure."
        fi
    else
        log_message "DNS resolution successful for $domain"
    fi
}

# Validate email format
validate_email() {
    local email="$1"
    if [[ ! "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        error_exit "Invalid email format: $email"
    fi
}

# Check if port is available
check_port_availability() {
    local port="$1"
    if netstat -tuln | grep -q ":$port "; then
        error_exit "Port $port is already in use. Please free the port or choose a different one."
    fi
}

# Install Git
install_git() {
    log_message "Installing Git..."
    apt install -y git || error_exit "Failed to install Git."
    log_message "Git installed successfully."
}

# Install Docker and Docker Compose
install_docker() {
    log_message "Installing Docker and Docker Compose..."

    # Update package list
    apt update || error_exit "Failed to update package list."

    # Install necessary packages for Docker
    apt install -y apt-transport-https ca-certificates curl software-properties-common || error_exit "Failed to install Docker prerequisites."

    # Add Docker's official GPG key
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg || error_exit "Failed to add Docker GPG key."

    # Add Docker repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null || error_exit "Failed to add Docker repository."

    # Update package list again after adding Docker repo
    apt update || error_exit "Failed to update package list after adding Docker repo."

    # Install Docker Engine
    apt install -y docker-ce docker-ce-cli containerd.io || error_exit "Failed to install Docker Engine."

    # Install Docker Compose (using the plugin method for newer versions)
    apt install -y docker-compose-plugin || error_exit "Failed to install Docker Compose plugin."

    # Start and enable Docker service
    systemctl start docker || error_exit "Failed to start Docker service."
    systemctl enable docker || error_exit "Failed to enable Docker service."

    # Verify Docker installation
    docker run hello-world || error_exit "Docker installation failed. 'hello-world' test failed."

    # Add current user to docker group to run docker commands without sudo
    if [ -n "$SUDO_USER" ]; then
        usermod -aG docker "$SUDO_USER" || error_exit "Failed to add $SUDO_USER to docker group."
        log_message "Added $SUDO_USER to docker group."
    fi
    
    if [ "$USER" != "root" ]; then
        usermod -aG docker "$USER" || error_exit "Failed to add current user to docker group."
    fi

    log_message "Docker and Docker Compose installed successfully."
    echo "Please log out and log back in (or run 'newgrp docker') for Docker group changes to take effect."
    sleep 3
}

# Install Nginx
install_nginx() {
    log_message "Installing Nginx..."
    apt install -y nginx || error_exit "Failed to install Nginx."
    systemctl start nginx || error_exit "Failed to start Nginx."
    systemctl enable nginx || error_exit "Failed to enable Nginx."

    # Remove default Nginx site to avoid conflicts
    if [ -f "/etc/nginx/sites-enabled/default" ]; then
        rm /etc/nginx/sites-enabled/default || warn_message "Failed to remove default Nginx site."
    fi

    log_message "Nginx installed successfully."
}

# Configure UFW firewall
configure_ufw() {
    log_message "Configuring UFW firewall..."
    
    # Install UFW if not present
    if ! command -v ufw &> /dev/null; then
        apt install -y ufw || error_exit "Failed to install UFW."
    fi
    
    ufw allow OpenSSH || error_exit "Failed to allow OpenSSH through UFW."
    ufw allow "Nginx Full" || error_exit "Failed to allow Nginx Full through UFW."
    ufw --force enable || error_exit "Failed to enable UFW."
    log_message "UFW configured successfully. Allowed OpenSSH and Nginx Full."
}

# Generate strong random string
generate_random_string() {
    openssl rand -base64 32 | tr -dc A-Za-z0-9 | head -c "$1"
}

# Create HTTP-only Nginx configuration
setup_nginx_http_only() {
    local subdomain="$1"
    local nginx_conf_file="$NGINX_CONF_DIR/$subdomain.conf"
    
    log_message "Creating HTTP-only Nginx configuration for $subdomain..."

    cat <<EOF > "$nginx_conf_file"
server {
    listen 80;
    listen [::]:80;
    server_name $subdomain;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;

    # Hide Nginx version
    server_tokens off;

    location / {
        proxy_pass http://127.0.0.1:$WAHA_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    error_log /var/log/nginx/$subdomain.error.log warn;
    access_log /var/log/nginx/$subdomain.access.log;
}
EOF

    # Create symlink to enable the site
    ln -sf "$nginx_conf_file" "$NGINX_SYMLINK_DIR/" || error_exit "Failed to create Nginx symlink."

    # Test Nginx configuration
    nginx -t || error_exit "Nginx configuration test failed. Please check $nginx_conf_file for errors."

    # Reload Nginx to apply new configuration
    systemctl reload nginx || error_exit "Failed to reload Nginx."

    log_message "HTTP-only Nginx configuration created and applied."
}

# Install and configure Certbot
install_certbot() {
    log_message "Installing Certbot..."

    # Install snapd if not present
    if ! command -v snap &> /dev/null; then
        apt install -y snapd || error_exit "Failed to install snapd."
        systemctl enable snapd || error_exit "Failed to enable snapd."
        systemctl start snapd || error_exit "Failed to start snapd."
        
        # Wait for snapd to be ready
        sleep 5
    fi

    # Ensure snap core is installed and up to date
    snap install core 2>/dev/null || snap refresh core || error_exit "Failed to install/refresh snap core."

    # Remove any existing certbot packages to avoid conflicts
    apt remove -y certbot python3-certbot-nginx 2>/dev/null || true

    # Install Certbot snap
    snap install --classic certbot || error_exit "Failed to install Certbot snap."
    
    # Create symlink if it doesn't exist
    if [ ! -L /usr/bin/certbot ]; then
        ln -s /snap/bin/certbot /usr/bin/certbot || error_exit "Failed to create certbot symlink."
    fi

    log_message "Certbot installed successfully."
}

# Obtain SSL certificate and update Nginx config
obtain_ssl_certificate() {
    local subdomain="$1"
    local email="$2"
    
    log_message "Obtaining SSL certificate for $subdomain..."

    # Obtain certificate using Nginx plugin
    certbot --nginx -d "$subdomain" --non-interactive --agree-tos --email "$email" --redirect || error_exit "Failed to obtain SSL certificate with Certbot."

    log_message "SSL certificate obtained and Nginx configuration updated automatically."
}

# Verify WAHA is running
verify_waha_running() {
    local subdomain="$1"
    local max_attempts=30
    local attempt=1
    
    log_message "Verifying WAHA is running..."
    
    while [ $attempt -le $max_attempts ]; do
        if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$WAHA_PORT" | grep -q "200\|401\|403"; then
            log_message "WAHA is running successfully on port $WAHA_PORT"
            return 0
        fi
        
        echo "Attempt $attempt/$max_attempts: Waiting for WAHA to start..."
        sleep 5
        ((attempt++))
    done
    
    error_exit "WAHA failed to start after $max_attempts attempts. Check Docker logs: cd $WAHA_DIR && docker compose logs"
}

# Show usage information
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -d, --domain DOMAIN       Domain name (e.g., waha.yourdomain.com)"
    echo "  -e, --email EMAIL         Email address for Let's Encrypt"
    echo "  -i, --interactive         Run in interactive mode"
    echo "  -h, --help                Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 -d waha.example.com -e admin@example.com"
    echo "  $0 --interactive"
    echo "  curl -fsSL https://raw.githubusercontent.com/Lets-Automate-It/waha-server-setup/main/waha_server_setup.sh | sudo bash -s -- -d waha.example.com -e admin@example.com"
}

# Parse command line arguments
INTERACTIVE_MODE=false
SUBDOMAIN=""
LETSENCRYPT_EMAIL=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--domain)
            SUBDOMAIN="$2"
            shift 2
            ;;
        -e|--email)
            LETSENCRYPT_EMAIL="$2"
            shift 2
            ;;
        -i|--interactive)
            INTERACTIVE_MODE=true
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# --- Main Script ---

check_root

log_message "Starting WAHA Installation Script"

echo "IMPORTANT: Before proceeding, ensure your chosen subdomain's A/AAAA DNS records"
echo "are pointing to this VPS's IP address. This is crucial for SSL certificate issuance."
echo ""

# Handle interactive vs non-interactive mode
if [ "$INTERACTIVE_MODE" = true ] || { [ -z "$SUBDOMAIN" ] && [ -z "$LETSENCRYPT_EMAIL" ]; }; then
    # Interactive mode
    if [ -t 0 ]; then
        read -p "Press Enter to continue..."
    else
        echo "ERROR: Interactive mode requires a terminal. Use command line arguments instead."
        echo "Example: curl -fsSL https://raw.githubusercontent.com/Lets-Automate-It/waha-server-setup/main/waha_server_setup.sh | sudo bash -s -- -d waha.example.com -e admin@example.com"
        exit 1
    fi
    
    # 1. Ask for subdomain and validate it
    while true; do
        read -p "Enter the subdomain for WAHA (e.g., waha.yourdomain.com): " SUBDOMAIN
        if [ -z "$SUBDOMAIN" ]; then
            echo "Subdomain cannot be empty. Please try again."
            continue
        fi
        
        validate_domain "$SUBDOMAIN"
        break
    done

    # 2. Ask for email and validate it
    while true; do
        read -p "Enter your email address for Let's Encrypt notifications: " LETSENCRYPT_EMAIL
        if [ -z "$LETSENCRYPT_EMAIL" ]; then
            echo "Email cannot be empty. Please try again."
            continue
        fi
        
        validate_email "$LETSENCRYPT_EMAIL"
        break
    done
else
    # Non-interactive mode - validate provided arguments
    if [ -z "$SUBDOMAIN" ] || [ -z "$LETSENCRYPT_EMAIL" ]; then
        echo "ERROR: Both domain and email are required for non-interactive mode."
        show_usage
        exit 1
    fi
    
    echo "Running in non-interactive mode..."
    echo "Domain: $SUBDOMAIN"
    echo "Email: $LETSENCRYPT_EMAIL"
    echo ""
    
    validate_domain "$SUBDOMAIN"
    validate_email "$LETSENCRYPT_EMAIL"
    
    sleep 3
fi

# 3. Check port availability
check_port_availability "$WAHA_PORT"

# 4. Generate strong API key and dashboard credentials
log_message "Generating API Key and Dashboard Credentials..."
WAHA_API_KEY=$(generate_random_string 48)
WAHA_DASHBOARD_USERNAME="admin" # Default, can be changed later
WAHA_DASHBOARD_PASSWORD=$(generate_random_string 24)

echo "Generated WAHA API Key: $WAHA_API_KEY"
echo "WAHA Dashboard Username: $WAHA_DASHBOARD_USERNAME"
echo "WAHA Dashboard Password: $WAHA_DASHBOARD_PASSWORD"
echo "Please save these credentials securely!"
echo ""
if [ "$INTERACTIVE_MODE" = true ] || [ -t 0 ]; then
    read -p "Press Enter to continue with installation..."
else
    echo "Continuing with installation in 5 seconds..."
    sleep 5
fi

# 6. Install system dependencies
log_message "Installing system dependencies..."
apt update || error_exit "Failed to update package list."
apt install -y curl wget gnupg2 lsb-release net-tools || error_exit "Failed to install system dependencies."

# 7. Install Docker and Docker Compose
install_docker

# 8. Install Nginx
install_nginx

# 9. Configure UFW
configure_ufw

# 10. Setup WAHA directory and configuration
log_message "Setting up WAHA configuration..."
# Remove existing WAHA directory if it exists to ensure a clean install
if [ -d "$WAHA_DIR" ]; then
    warn_message "WAHA directory already exists. Removing it..."
    rm -rf "$WAHA_DIR" || error_exit "Failed to remove existing WAHA directory."
fi

mkdir -p "$WAHA_DIR" || error_exit "Failed to create WAHA directory."

# Clone WAHA repository
log_message "Cloning WAHA repository into $WAHA_DIR..."
git clone https://github.com/devlikeapro/waha.git "$WAHA_DIR" || error_exit "Failed to clone WAHA repository."
cd "$WAHA_DIR" || error_exit "Failed to change directory to WAHA_DIR."

# Modify the cloned docker-compose.yaml to use the 'latest' image
log_message "Modifying docker-compose.yaml to use 'devlikeapro/waha:latest' image..."
# Use a temporary file for sed to work correctly across different systems
sed -i.bak 's|image: devlikeapro/waha|image: devlikeapro/waha:latest|g' docker-compose.yaml || error_exit "Failed to update docker-compose.yaml image."
rm -f docker-compose.yaml.bak # Clean up the backup file

# Ensure the docker-compose file is named .yml for consistency with Docker Compose's preference
if [ -f "docker-compose.yaml" ]; then
    mv docker-compose.yaml docker-compose.yml || error_exit "Failed to rename docker-compose.yaml to docker-compose.yml."
fi

log_message "WAHA docker-compose configuration updated."

# 11. Configure WAHA .env file
log_message "Configuring WAHA .env file..."

# Create .env file with WAHA Core configuration
cat <<EOF > "$WAHA_DIR/.env"
# WAHA Core Configuration
WAHA_API_KEY=$WAHA_API_KEY
WAHA_DASHBOARD_USERNAME=$WAHA_DASHBOARD_USERNAME
WAHA_DASHBOARD_PASSWORD=$WAHA_DASHBOARD_PASSWORD

# Server Configuration
WAHA_PORT=3000
WAHA_HOST=0.0.0.0

# Optional: Webhook Configuration
# WAHA_WEBHOOK_URL=https://your-webhook-url.com/webhook
# WAHA_WEBHOOK_EVENTS=message,message.any,state.change

# Optional: File Storage
# WAHA_FILES_FOLDER=/app/files
# WAHA_FILES_LIFETIME=180

# Optional: Session Configuration
# WAHA_SESSIONS_FOLDER=/app/sessions
# WAHA_SESSIONS_SAVE_TO_FILE=true
EOF

log_message "WAHA .env file configured."

# 12. Pull WAHA Core image and start containers
log_message "Pulling WAHA Core Docker image..."
# Use docker-compose.yml explicitly if it was renamed
docker compose -f docker-compose.yml pull || error_exit "Failed to pull WAHA Core image."

log_message "Starting WAHA Docker containers..."
# Use docker-compose.yml explicitly if it was renamed
docker compose -f docker-compose.yml up -d || error_exit "Failed to start WAHA containers with Docker Compose."

# 13. Wait for WAHA to be ready
verify_waha_running "$SUBDOMAIN"

# 14. Create HTTP-only Nginx configuration
setup_nginx_http_only "$SUBDOMAIN"

# 15. Install Certbot
install_certbot

# 16. Obtain SSL certificate (this will automatically update Nginx config)
obtain_ssl_certificate "$SUBDOMAIN" "$LETSENCRYPT_EMAIL"

# 17. Final verification
log_message "Performing final verification..."
if curl -s -k "https://$SUBDOMAIN" | grep -q "WAHA\|WhatsApp\|API" || curl -s -I "https://$SUBDOMAIN" | grep -q "HTTP/"; then
    log_message "WAHA is accessible via HTTPS!"
else
    warn_message "WAHA HTTPS verification failed. Please check manually."
fi

log_message "WAHA installation completed successfully!"
echo ""
echo "================================================================="
echo "WAHA Installation Summary"
echo "================================================================="
echo "WAHA URL: https://$SUBDOMAIN"
echo "API Key: $WAHA_API_KEY"
echo "Dashboard Username: $WAHA_DASHBOARD_USERNAME"
echo "Dashboard Password: $WAHA_DASHBOARD_PASSWORD"
echo "Let's Encrypt Email: $LETSENCRYPT_EMAIL"
echo ""
echo "Important Notes:"
echo "- Keep your API key and dashboard credentials secure"
echo "- SSL certificates will renew automatically"
echo "- Check logs if needed: cd $WAHA_DIR && docker compose logs"
echo "- Nginx logs: /var/log/nginx/$SUBDOMAIN.error.log"
echo "- To restart WAHA: cd $WAHA_DIR && docker compose restart"
echo "================================================================="
