#!/bin/bash

# This script automates the installation of WAHA (WhatsApp Automation Tool) on an Ubuntu DigitalOcean VPS.
# It sets up Docker, Docker Compose, Apache as a reverse proxy, and secures it with Let's Encrypt SSL.
# The user will be prompted for their subdomain, email, and desired WAHA version.
# A strong API key will be automatically generated.
# Dashboard and Swagger UI access will be secured with Apache basic authentication.
# Additional security measures including comprehensive security headers and Fail2Ban will be configured.

# --- Configuration Variables ---
WAHA_INSTALL_DIR="/opt/waha"
LOG_FILE="/var/log/waha-install.log"
BACKUP_DIR="/opt/waha-backups/$(date +%Y%m%d_%H%M%S)"
DEFAULT_WAHA_PORT="3000"
# .htpasswd files for Apache will be stored in a secure location within Apache's conf
APACHE_HTPASSWD_DIR="/etc/apache2/conf.d" # Directory to store .htpasswd files for Apache basic auth

# --- Logging Setup ---
mkdir -p "$(dirname "$LOG_FILE")"
exec 1> >(tee -a "$LOG_FILE")
exec 2> >(tee -a "$LOG_FILE" >&2)

# --- Cleanup Trap ---
cleanup() {
    if [ -n "$TEMP_APACHE_CONFIG" ] && [ -f "$TEMP_APACHE_CONFIG" ]; then
        rm -f "$TEMP_APACHE_CONFIG"
    fi
}
trap cleanup EXIT

# --- Functions ---

# Function to display error and exit
die() {
    echo "ERROR: $1" >&2
    echo "Check the installation log at: $LOG_FILE" >&2
    exit 1
}

# Function to validate domain format
validate_domain() {
    if [[ ! "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        die "Invalid domain format: $1"
    fi
}

# Function to validate email format
validate_email() {
    if [[ ! "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        die "Invalid email format: $1"
    fi
}

# Function to backup existing configuration
backup_config() {
    local config_file="$1"
    if [ -f "$config_file" ]; then
        mkdir -p "$BACKUP_DIR"
        cp "$config_file" "$BACKUP_DIR/$(basename "$config_file").backup"
        echo "Backed up existing config: $config_file"
    fi
}

# Function to get latest Docker Compose version
get_docker_compose_version() {
    local version
    version=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep -Po '"tag_name": "\K.*?(?=")' 2>/dev/null)
    if [ -z "$version" ]; then
        echo "v2.20.2" # Fallback version
    else
        echo "$version"
    fi
}

# Function to create rollback script
create_rollback_script() {
    local rollback_script="/opt/waha-rollback.sh"
    cat <<EOF > "$rollback_script"
#!/bin/bash
# WAHA Installation Rollback Script
# Generated on $(date)

echo "Rolling back WAHA installation..."

# Stop and remove containers
if [ -d "$WAHA_INSTALL_DIR" ]; then
    cd "$WAHA_INSTALL_DIR"
    docker compose down 2>/dev/null || true
fi

# Restore Apache configurations
if [ -d "$BACKUP_DIR" ]; then
    for backup in "$BACKUP_DIR"/*.backup; do
        if [ -f "\$backup" ]; then
            original="\${backup%.backup}"
            original="/etc/apache2/sites-available/\$(basename "\$original")"
            cp "\$backup" "\$original"
            echo "Restored \$original"
        fi
    done
fi

# Disable Apache site
a2dissite "$SUBDOMAIN" 2>/dev/null || true
systemctl reload apache2 2>/dev/null || true

# Remove installation directory
rm -rf "$WAHA_INSTALL_DIR"

# Remove .htpasswd files
rm -f "$APACHE_HTPASSWD_DIR/${SUBDOMAIN}_dashboard.htpasswd"
rm -f "$APACHE_HTPASSWD_DIR/${SUBDOMAIN}_swagger.htpasswd"

# Remove Fail2Ban config
rm -f "/etc/fail2ban/jail.d/apache-waha.conf"
systemctl restart fail2ban 2>/dev/null || true

echo "Rollback completed. Check services manually."
EOF
    chmod +x "$rollback_script"
    echo "Rollback script created at: $rollback_script"
}

# Function to parse command line arguments
parse_args() {
    DRY_RUN=false
    CUSTOM_PORT=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --port)
                CUSTOM_PORT="$2"
                shift 2
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                die "Unknown option: $1. Use --help for usage information."
                ;;
        esac
    done
}

# Function to show help
show_help() {
    cat <<EOF
WAHA Installation Script

Usage: $0 [OPTIONS]

Options:
    --dry-run       Show what would be done without making changes
    --port PORT     Custom port for WAHA container (default: $DEFAULT_WAHA_PORT)
    --help          Show this help message

Examples:
    $0                    # Normal installation
    $0 --dry-run         # Preview changes without executing
    $0 --port 3001       # Use custom port 3001
EOF
}

# --- Preamble and Warnings ---
echo "----------------------------------------------------"
echo "WAHA Automation Installation Script (using Apache)"
echo "Enhanced Version with Rollback and Monitoring Support"
echo "----------------------------------------------------"
echo "This script will install Docker, Docker Compose, Apache, Certbot, and Fail2Ban."
echo "It is designed for a fresh Ubuntu 20.04+ DigitalOcean VPS."
echo "IMPORTANT: Ensure your DNS records for your subdomain are pointing to this VPS's IP address BEFORE running this script."
echo "You will be prompted for necessary information."
echo "Installation log will be saved to: $LOG_FILE"
echo "----------------------------------------------------"
echo ""

# Parse command line arguments
parse_args "$@"

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    die "Please run this script with sudo: sudo ./install_waha.sh"
fi

# Handle SUDO_USER safely
ACTUAL_USER="${SUDO_USER:-$USER}"
if [ -z "$ACTUAL_USER" ] || [ "$ACTUAL_USER" = "root" ]; then
    echo "Warning: Could not determine non-root user. Docker group assignment may not work properly."
    ACTUAL_USER=""
fi

# --- Get User Input ---
read -p "Enter your subdomain (e.g., waha.example.com): " SUBDOMAIN
if [ -z "$SUBDOMAIN" ]; then
    die "Subdomain cannot be empty. Exiting."
fi
validate_domain "$SUBDOMAIN"

read -p "Enter your email address for Let's Encrypt SSL (e.g., your@example.com): " EMAIL
if [ -z "$EMAIL" ]; then
    die "Email cannot be empty. It's required for Let's Encrypt. Exiting."
fi
validate_email "$EMAIL"

# Set up port configuration
WAHA_PORT="${CUSTOM_PORT:-$DEFAULT_WAHA_PORT}"
if [[ ! "$WAHA_PORT" =~ ^[0-9]+$ ]] || [ "$WAHA_PORT" -lt 1024 ] || [ "$WAHA_PORT" -gt 65535 ]; then
    die "Invalid port number: $WAHA_PORT. Must be between 1024-65535."
fi

echo "Choose your WAHA version:"
echo "1) WAHA Core (Free, open-source)"
echo "2) WAHA Plus (Commercial, advanced features)"
echo "3) WAHA ARM (For ARM-based architectures like Raspberry Pi)"
read -p "Enter 1, 2, or 3: " WAHA_CHOICE

WAHA_IMAGE=""
WAHA_TYPE=""
case "$WAHA_CHOICE" in
    1) WAHA_IMAGE="devlikeapro/waha:latest"; WAHA_TYPE="WAHA Core";;
    2) WAHA_IMAGE="devlikeapro/waha-plus:latest"; WAHA_TYPE="WAHA Plus";;
    3) WAHA_IMAGE="devlikeapro/waha:arm"; WAHA_TYPE="WAHA ARM (Core)";;
    *) die "Invalid choice. Please choose 1, 2, or 3. Exiting.";;
esac

echo "You chose to install $WAHA_TYPE on port $WAHA_PORT."
# Inform the user about Dashboard/Swagger availability for Core versions
if [[ "$WAHA_TYPE" == "WAHA Core" || "$WAHA_TYPE" == "WAHA ARM (Core)" ]]; then
    echo "Note: The WAHA Dashboard and Swagger UI are features of WAHA Plus. If you proceed with a Core version,"
    echo "Apache basic authentication will still be configured for /dashboard and /swagger, but the WAHA"
    echo "application itself will not serve content at those paths, resulting in a blank page after login."
    echo "The main API endpoint (/) will function as expected."
fi
echo ""

# --- Auto-generate a strong API key ---
echo "--> Automatically generating a strong WAHA API Key..."
WAHA_API_KEY=$(openssl rand -base64 32)
if [ -z "$WAHA_API_KEY" ]; then
    die "Failed to auto-generate API Key. Exiting."
fi
echo "Generated API Key: $WAHA_API_KEY"
echo ""

# --- Get Dashboard and Swagger UI Apache Basic Auth Credentials (Optional) ---
DASHBOARD_HTPASSWD_FILE="$APACHE_HTPASSWD_DIR/${SUBDOMAIN}_dashboard.htpasswd"
SWAGGER_HTPASSWD_FILE="$APACHE_HTPASSWD_DIR/${SUBDOMAIN}_swagger.htpasswd"

read -p "Set a username for WAHA Dashboard Basic Authentication (leave empty for no dashboard basic auth): " DASHBOARD_USERNAME
if [ -n "$DASHBOARD_USERNAME" ]; then
    read -s -p "Set a password for WAHA Dashboard: " DASHBOARD_PASSWORD
    echo "" # Add a newline after silent password input
    if [ -z "$DASHBOARD_PASSWORD" ]; then
        die "Dashboard password cannot be empty if username is set. Exiting."
    fi
fi

read -p "Set a username for WAHA Swagger UI Basic Authentication (leave empty for no Swagger basic auth): " SWAGGER_USERNAME
if [ -n "$SWAGGER_USERNAME" ]; then
    read -s -p "Set a password for WAHA Swagger UI: " SWAGGER_PASSWORD
    echo "" # Add a newline after silent password input
    if [ -z "$SWAGGER_PASSWORD" ]; then
        die "Swagger password cannot be empty if username is set. Exiting."
    fi
fi

# Optional monitoring setup
read -p "Would you like to enable basic monitoring with Prometheus metrics? (y/N): " ENABLE_MONITORING
ENABLE_MONITORING=${ENABLE_MONITORING,,} # Convert to lowercase

# Define Apache config file path
APACHE_CONF_FILE="/etc/apache2/sites-available/$SUBDOMAIN.conf"

# Dry run check
if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "=== DRY RUN MODE - No changes will be made ==="
    echo "Would install:"
    echo "- WAHA Type: $WAHA_TYPE"
    echo "- Subdomain: $SUBDOMAIN"
    echo "- Email: $EMAIL"
    echo "- Port: $WAHA_PORT"
    echo "- Apache config: $APACHE_CONF_FILE"
    echo "- Install directory: $WAHA_INSTALL_DIR"
    echo "- Monitoring: $([ "$ENABLE_MONITORING" = "y" ] && echo "Enabled" || echo "Disabled")"
    echo "=== END DRY RUN ==="
    exit 0
fi

echo ""
echo "Starting installation for $SUBDOMAIN with $WAHA_TYPE and email $EMAIL..."
echo "----------------------------------------------------"

# Create rollback script early
create_rollback_script

# --- Update System and Install Prerequisites ---
echo "--> Updating system and installing prerequisites..."
apt update -y || die "Failed to update package lists."
# Install apache2-utils for htpasswd and fail2ban
apt install -y apt-transport-https ca-certificates curl software-properties-common ufw apache2-utils fail2ban jq || die "Failed to install prerequisites."

# --- Configure UFW Firewall ---
echo "--> Configuring UFW firewall..."
ufw allow OpenSSH || die "Failed to allow OpenSSH."
ufw allow 80/tcp || die "Failed to allow HTTP (port 80)."
ufw allow 443/tcp || die "Failed to allow HTTPS (port 443)."
# Add custom port if different from default
if [ "$WAHA_PORT" != "$DEFAULT_WAHA_PORT" ]; then
    ufw allow "$WAHA_PORT/tcp" || die "Failed to allow custom WAHA port ($WAHA_PORT)."
fi
# Add monitoring port if enabled
if [ "$ENABLE_MONITORING" = "y" ]; then
    ufw allow 9090/tcp || die "Failed to allow Prometheus port (9090)."
fi
ufw --force enable || die "Failed to enable UFW."
echo "UFW configured: Ports 80, 443, SSH$([ "$WAHA_PORT" != "$DEFAULT_WAHA_PORT" ] && echo ", $WAHA_PORT")$([ "$ENABLE_MONITORING" = "y" ] && echo ", 9090") are open."

# --- Install Docker ---
echo "--> Installing Docker..."
# Add Docker's official GPG key
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg || die "Failed to add Docker GPG key."

# Set up the stable Docker repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null || die "Failed to add Docker repository."

# Install Docker packages
apt update -y || die "Failed to update package lists after adding Docker repo."
apt install -y docker-ce docker-ce-cli containerd.io || die "Failed to install Docker."

# Add current user to the docker group (to run docker commands without sudo)
if [ -n "$ACTUAL_USER" ]; then
    usermod -aG docker "$ACTUAL_USER" # Adds the user who invoked sudo to the docker group
    echo "Docker installed successfully."
    echo "NOTE: For your user ('$ACTUAL_USER') to run Docker commands without 'sudo', you may need to log out and log in again, or run 'newgrp docker'."
else
    echo "Docker installed successfully (user group assignment skipped)."
fi

# Get latest Docker Compose version
echo "--> Getting latest Docker Compose version..."
DOCKER_COMPOSE_VERSION=$(get_docker_compose_version)
echo "Using Docker Compose version: $DOCKER_COMPOSE_VERSION"

# --- Uninstall Nginx (if present) ---
echo "--> Checking for and uninstalling Nginx if present..."
if dpkg -s nginx >/dev/null 2>&1; then
    systemctl stop nginx || true
    apt purge -y nginx nginx-common || die "Failed to purge Nginx."
    apt autoremove -y || die "Failed to autoremove Nginx dependencies."
    rm -f /etc/nginx/sites-available/$SUBDOMAIN # Clean up old Nginx site config
    rm -f /etc/nginx/sites-enabled/$SUBDOMAIN
    rm -f "$APACHE_HTPASSWD_DIR/waha_security_headers_and_rate_limits.conf" # Clean up global Nginx config if it existed there
    # Remove include from nginx.conf if it was added
    sed -i '/include \/etc\/nginx\/conf\.d\/waha_security_headers_and_rate_limits\.conf;/d' /etc/nginx/nginx.conf || true
    echo "Nginx uninstalled."
else
    echo "Nginx not found, skipping uninstallation."
fi

# --- Install Apache and Certbot Apache Plugin ---
echo "--> Installing Apache2 and Certbot Apache plugin..."
apt install -y apache2 python3-certbot-apache || die "Failed to install Apache2 or Certbot Apache plugin."

# --- Enable Apache Modules ---
echo "--> Enabling Apache modules..."
a2enmod proxy proxy_http ssl headers rewrite authz_core auth_basic || die "Failed to enable Apache modules."
systemctl restart apache2 || die "Failed to restart Apache2 after enabling modules."

# --- Backup existing Apache configurations ---
backup_config "$APACHE_CONF_FILE"

# --- Create .htpasswd files if credentials provided ---
mkdir -p "$APACHE_HTPASSWD_DIR" || die "Failed to create .htpasswd directory for Apache."
if [ -n "$DASHBOARD_USERNAME" ]; then
    echo "Creating .htpasswd for Dashboard (Apache)..."
    htpasswd -cb "$DASHBOARD_HTPASSWD_FILE" "$DASHBOARD_USERNAME" "$DASHBOARD_PASSWORD" || die "Failed to create dashboard .htpasswd file."
    chmod 640 "$DASHBOARD_HTPASSWD_FILE" # Secure permissions
    chown root:www-data "$DASHBOARD_HTPASSWD_FILE" # Ensure Apache can read it
fi

if [ -n "$SWAGGER_USERNAME" ]; then
    echo "Creating .htpasswd for Swagger UI (Apache)..."
    htpasswd -cb "$SWAGGER_HTPASSWD_FILE" "$SWAGGER_USERNAME" "$SWAGGER_PASSWORD" || die "Failed to create swagger .htpasswd file."
    chmod 640 "$SWAGGER_HTPASSWD_FILE" # Secure permissions
    chown root:www-data "$SWAGGER_HTPASSWD_FILE" # Ensure Apache can read it
fi

# --- Configure Apache Virtual Host for WAHA - Stage 1 (HTTP and Certbot Challenge) ---
echo "--> Configuring Apache Virtual Host for $SUBDOMAIN (Stage 1: HTTP and Certbot Challenge)..."

cat <<EOF > "$APACHE_CONF_FILE"
<VirtualHost *:80>
    ServerName $SUBDOMAIN
    DocumentRoot /var/www/html # Certbot expects this for challenges

    # Deny access to sensitive files (like .htpasswd)
    <Files ".ht*">
        Require all denied
    </Files>

    # Redirect all HTTP traffic to HTTPS
    RewriteEngine On
    RewriteCond %{HTTPS} off
    RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]
</VirtualHost>
EOF

# Enable the Apache site and disable the default one
echo "--> Enabling site $SUBDOMAIN and disabling 000-default..."
a2ensite "$SUBDOMAIN" || die "Failed to enable Apache site. Check Apache logs for details: systemctl status apache2.service"
a2dissite 000-default || true # Disable default Apache site if it exists

# IMPORTANT: Test Apache configuration syntax after enabling the site
echo "--> Testing Apache configuration syntax..."
apachectl configtest || die "Apache configuration test failed after site enablement. Check error logs."

# Reload Apache to pick up the new site configuration
systemctl reload apache2 || die "Failed to reload Apache2 after enabling sites. Check logs for details."
echo "Apache Stage 1 configured. Proceeding to obtain SSL certificate..."

# --- Obtain Let's Encrypt SSL Certificate ---
echo "--> Obtaining Let's Encrypt SSL certificate for $SUBDOMAIN..."
# Create webroot directory for certbot challenges
mkdir -p /var/www/html/.well-known/acme-challenge
chown -R www-data:www-data /var/www/html # Ensure Apache can access this
chmod -R 755 /var/www/html/.well-known/acme-challenge

# Run Certbot to get and install the SSL certificate using the Apache plugin.
# Certbot will automatically modify the Apache config to add the HTTPS block.
certbot --apache -d "$SUBDOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect || die "Failed to obtain SSL certificate. Please ensure your DNS is correctly set up for $SUBDOMAIN and try again."

echo "SSL certificate obtained. Updating Apache for HTTPS proxy and enhanced security..."

# --- Configure Apache Virtual Host for WAHA - Stage 2 (HTTPS with Proxy Pass and Basic Auth) ---
# Create a more maintainable template-based approach
TEMP_APACHE_CONFIG=$(mktemp)

# Build proxy configuration for monitoring if enabled
MONITORING_PROXY=""
if [ "$ENABLE_MONITORING" = "y" ]; then
    MONITORING_PROXY="
    # Prometheus metrics endpoint
    <Location /metrics>
        ProxyPass http://localhost:9090/metrics
        ProxyPassReverse http://localhost:9090/metrics
        # Optional: Restrict access to monitoring
        # Require ip YOUR_MONITORING_IP
    </Location>"
fi

# Create the enhanced Apache configuration
cat <<EOF > "$TEMP_APACHE_CONFIG"
    # Proxy settings
    ProxyRequests Off
    ProxyPreserveHost On
    ProxyTimeout 900 # Increase timeout for long-running operations

    # Main API endpoint (no basic auth here)
    ProxyPass / http://localhost:$WAHA_PORT/
    ProxyPassReverse / http://localhost:$WAHA_PORT/

    # Proxy for Dashboard with optional Basic Auth
    <Location /dashboard>
        $( [ -n "$DASHBOARD_USERNAME" ] && echo "AuthType Basic" )
        $( [ -n "$DASHBOARD_USERNAME" ] && echo "AuthName \"WAHA Dashboard\"" )
        $( [ -n "$DASHBOARD_USERNAME" ] && echo "AuthUserFile $DASHBOARD_HTPASSWD_FILE" )
        $( [ -n "$DASHBOARD_USERNAME" ] && echo "Require valid-user" )
        # Optional: IP Whitelisting (uncomment and replace with your IP if needed)
        # For example: Require ip YOUR_IP_ADDRESS
        ProxyPass http://localhost:$WAHA_PORT/dashboard
        ProxyPassReverse http://localhost:$WAHA_PORT/dashboard
    </Location>

    # Proxy for Swagger UI with optional Basic Auth
    <Location /swagger>
        $( [ -n "$SWAGGER_USERNAME" ] && echo "AuthType Basic" )
        $( [ -n "$SWAGGER_USERNAME" ] && echo "AuthName \"WAHA Swagger UI\"" )
        $( [ -n "$SWAGGER_USERNAME" ] && echo "AuthUserFile $SWAGGER_HTPASSWD_FILE" )
        $( [ -n "$SWAGGER_USERNAME" ] && echo "Require valid-user" )
        # Optional: IP Whitelisting (uncomment and replace with your IP if needed)
        # For example: Require ip YOUR_IP_ADDRESS
        ProxyPass http://localhost:$WAHA_PORT/swagger
        ProxyPassReverse http://localhost:$WAHA_PORT/swagger
    </Location>

    # Proxy for WebSocket connections
    <Location /ws>
        ProxyPass ws://localhost:$WAHA_PORT/ws
        ProxyPassReverse ws://localhost:$WAHA_PORT/ws
        # Keepalive for WebSockets
        # ProxyPreserveHost On # Already set globally
        RewriteEngine On
        RewriteCond %{HTTP:Upgrade} websocket [NC]
        RewriteCond %{HTTP:Connection} upgrade [NC]
        RewriteRule .* "ws://localhost:$WAHA_PORT%{REQUEST_URI}" [P,L]
    </Location>
$MONITORING_PROXY

    # Security Headers (mod_headers must be enabled)
    Header always set X-Frame-Options SAMEORIGIN
    Header always set X-Content-Type-Options nosniff
    Header always set X-XSS-Protection "1; mode=block"
    Header always set Referrer-Policy "no-referrer-when-downgrade"
    Header always set Strict-Transport-Security "max-age=15768000; includeSubDomains; preload"
    # Content-Security-Policy: IMPORTANT: This can break websites if not properly configured.
    Header always set Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self';"
EOF

# Inject the generated configuration into the Certbot-modified HTTPS VirtualHost
sed -i "/<VirtualHost \*:443>/,/<\/VirtualHost>/ {
    /ServerName $SUBDOMAIN/a\\
$(sed -e 's/\\/\\\\/g' -e 's/\//\\\//g' -e '$!s/$/\\/' -e 's/$/\n/' "$TEMP_APACHE_CONFIG")
}" "$APACHE_CONF_FILE" || die "Failed to inject proxy and security configurations into Apache VirtualHost."

systemctl reload apache2 || die "Failed to reload Apache2 after SSL and proxy config. Check logs for details."
echo "Apache fully configured with SSL, proxy passes, and security headers."

# --- Configure Fail2Ban for Apache protection ---
echo "--> Configuring Fail2Ban for Apache protection..."
FAIL2BAN_JAIL_FILE="/etc/fail2ban/jail.d/apache-waha.conf"

cat <<EOF > "$FAIL2BAN_JAIL_FILE"
[apache-auth]
enabled = true
port = http,https
filter = apache-auth
logpath = /var/log/apache2/error.log
maxretry = 10    ; Ban after 10 failed authentication attempts
bantime = 1800   ; Ban for 30 minutes (1800 seconds)
findtime = 600   ; Look for failures within 10 minutes (600 seconds)

[apache-noscript]
enabled = true
port = http,https
filter = apache-noscript
logpath = /var/log/apache2/error.log
maxretry = 10
bantime = 1800
findtime = 600

# You may add other Apache-related jails here if needed, e.g., apache-badbots, apache-overflows
EOF

systemctl enable fail2ban || die "Failed to enable Fail2Ban service."
systemctl restart fail2ban || die "Failed to restart Fail2Ban service. Check logs for details."
echo "Fail2Ban configured and started."

# --- Deploy WAHA with Docker Compose ---
echo "--> Creating WAHA Docker Compose setup in $WAHA_INSTALL_DIR..."
mkdir -p "$WAHA_INSTALL_DIR" || die "Failed to create WAHA install directory."
cd "$WAHA_INSTALL_DIR" || die "Failed to change to WAHA install directory."

# Determine the correct healthcheck URL based on WAHA_TYPE
WAHA_HEALTHCHECK_URL="http://localhost:$WAHA_PORT/health" # Default for Plus
if [[ "$WAHA_TYPE" == "WAHA Core" || "$WAHA_TYPE" == "WAHA ARM (Core)" ]]; then
    WAHA_HEALTHCHECK_URL="http://localhost:$WAHA_PORT/" # Use root for Core versions
fi

# Start building the environment variables for Docker Compose
WAHA_ENV_VARS="      - BASE_URL=https://$SUBDOMAIN
      - API_KEY=$WAHA_API_KEY"

# Add monitoring configuration if enabled
MONITORING_SERVICE=""
if [ "$ENABLE_MONITORING" = "y" ]; then
    MONITORING_SERVICE="
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus_container
    restart: always
    ports:
      - \"9090:9090\"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--web.console.libraries=/etc/prometheus/console_libraries'
      - '--web.console.templates=/etc/prometheus/consoles'

volumes:
  prometheus_data:"
fi

# Create the docker-compose.yml file for WAHA
cat <<EOF > docker-compose.yml
services:
  waha:
    image: $WAHA_IMAGE
    container_name: waha_container
    restart: always
    ports:
      # Map container port 3000 to host port $WAHA_PORT.
      # Apache will proxy requests to this host port.
      - "$WAHA_PORT:3000"
    environment:
$WAHA_ENV_VARS
    volumes:
      - ./data:/app/data # Persist WAHA data to a local 'data' directory
    healthcheck:
      test: ["CMD", "curl", "-f", "$WAHA_HEALTHCHECK_URL"]
      interval: 30s
      timeout: 10s
      retries: 5
$MONITORING_SERVICE
EOF

# Create Prometheus configuration if monitoring is enabled
if [ "$ENABLE_MONITORING" = "y" ]; then
    echo "--> Creating Prometheus configuration..."
    cat <<EOF > prometheus.yml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'waha'
    static_configs:
      - targets: ['localhost:$WAHA_PORT']
    metrics_path: '/metrics'
    scrape_interval: 30s
EOF
fi

# Create data backup script
echo "--> Creating data backup script..."
cat <<EOF > backup-data.sh
#!/bin/bash
# WAHA Data Backup Script
BACKUP_DATE=\$(date +%Y%m%d_%H%M%S)
BACKUP_PATH="/opt/waha-data-backups/\$BACKUP_DATE"

mkdir -p "\$BACKUP_PATH"
cp -r "$WAHA_INSTALL_DIR/data" "\$BACKUP_PATH/"

echo "Backup completed: \$BACKUP_PATH"

# Keep only last 7 backups
find /opt/waha-data-backups -maxdepth 1 -type d -name "20*" | sort | head -n -7 | xargs rm -rf
EOF
chmod +x backup-data.sh

echo "--> Starting WAHA containers using Docker Compose..."
docker compose up -d || die "Failed to start WAHA containers. Check 'docker compose logs -f waha' for errors."

echo ""
echo "----------------------------------------------------"
echo "WAHA Installation Complete!"
echo "----------------------------------------------------"
echo "Your WAHA instance should now be accessible at: https://$SUBDOMAIN"
echo "The API documentation (Swagger) should be at: https://$SUBDOMAIN/swagger"
echo "Your chosen API Key for WAHA is: $WAHA_API_KEY"
echo "WAHA is running on port: $WAHA_PORT"
echo ""

if [ -n "$DASHBOARD_USERNAME" ]; then
    echo "Dashboard Basic Auth Credentials:"
    echo "  Username: $DASHBOARD_USERNAME"
    echo "  Password: $DASHBOARD_PASSWORD"
fi

if [ -n "$SWAGGER_USERNAME" ]; then
    echo "Swagger UI Basic Auth Credentials:"
    echo "  Username: $SWAGGER_USERNAME"
    echo "  Password: $SWAGGER_PASSWORD"
fi

if [ "$ENABLE_MONITORING" = "y" ]; then
    echo ""
    echo "Monitoring Setup:"
    echo "- Prometheus is available at: http://$(hostname -I | awk '{print $1}'):9090"
    echo "- Metrics endpoint: https://$SUBDOMAIN/metrics"
fi

echo ""
echo "Backup and Maintenance:"
echo "- Data backup script: $WAHA_INSTALL_DIR/backup-data.sh"
echo "- Run backup: cd $WAHA_INSTALL_DIR && ./backup-data.sh"
echo "- Installation log: $LOG_FILE"
echo "- Configuration backups: $BACKUP_DIR"
echo "- Rollback script: /opt/waha-rollback.sh"
echo ""

echo "Important Notes for Secure Access:"
echo "- Your instance is now protected with Apache Basic Authentication for Dashboard/Swagger, API Key for the main API, Security Headers, and Fail2Ban."
echo "- **Important for Dashboard/Swagger:** Even with Apache basic authentication, if you chose WAHA Core (or ARM Core), the WAHA application itself does not serve content at /dashboard or /swagger. You will see a blank page after login as the backend provides no content. These interfaces require WAHA Plus."
echo "- Rate limiting in Apache is typically achieved with modules like mod_qos, which are more complex than Nginx's built-in options and are not included in this script to prevent initial access issues. Consider adding them if needed for high traffic scenarios."
echo "- If you are getting a '500 Internal Server Error' after authentication, this likely means"
echo "  the WAHA Docker container is not running or is experiencing an internal error."
echo "  To debug this, navigate to the WAHA installation directory and check the container logs:"
echo "  cd $WAHA_INSTALL_DIR"
echo "  docker compose logs -f waha"
echo "  Look for error messages within the WAHA logs to pinpoint the issue."
echo "- If you get blocked by Fail2Ban, you can unban your IP (replace YOUR_IP) with:"
echo "  sudo fail2ban-client set apache-auth unbanip YOUR_IP"
echo "  sudo fail2ban-client set apache-noscript unbanip YOUR_IP"
echo "- To check Fail2Ban status: sudo fail2ban-client status"
echo "- To flush your local DNS cache if access issues persist, refer to your OS instructions."
echo "- WAHA data is persisted in '$WAHA_INSTALL_DIR/data'."
echo "- To stop/start/restart WAHA: 'cd $WAHA_INSTALL_DIR && docker compose stop/start/restart'"
echo ""

echo "Management Commands:"
echo "- View container status: cd $WAHA_INSTALL_DIR && docker compose ps"
echo "- View logs: cd $WAHA_INSTALL_DIR && docker compose logs -f"
echo "- Update containers: cd $WAHA_INSTALL_DIR && docker compose pull && docker compose up -d"
echo "- System rollback: sudo /opt/waha-rollback.sh"
echo ""

if [ "$ENABLE_MONITORING" = "y" ]; then
    echo "Monitoring Commands:"
    echo "- Check Prometheus status: docker compose ps prometheus"
    echo "- View Prometheus logs: docker compose logs -f prometheus"
    echo "- Access Prometheus UI: http://$(hostname -I | awk '{print $1}'):9090"
    echo ""
fi

echo "Security Recommendations:"
echo "- Regularly update your system: sudo apt update && sudo apt upgrade"
echo "- Monitor fail2ban logs: sudo tail -f /var/log/fail2ban.log"
echo "- Check Apache access logs: sudo tail -f /var/log/apache2/access.log"
echo "- Review Docker container logs periodically"
echo "- Consider setting up automated backups using cron"
echo "- Review and update your firewall rules as needed"
echo "- Monitor SSL certificate expiration (auto-renewal should work via certbot)"
echo ""

echo "Troubleshooting:"
echo "- If containers fail to start, check: docker compose logs"
echo "- If Apache returns 502/503 errors, verify container is running: docker compose ps"
echo "- For SSL issues, check certificate status: sudo certbot certificates"
echo "- For DNS issues, verify your domain points to this server's IP"
echo "- Check disk space: df -h"
echo "- Check memory usage: free -h"
echo ""

echo "----------------------------------------------------"
echo "Installation completed successfully!"
echo "Please save this output for your records."
echo "----------------------------------------------------"
