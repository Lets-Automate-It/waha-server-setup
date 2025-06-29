#!/bin/bash

# This script automates the installation of WAHA (WhatsApp Automation Tool) on an Ubuntu DigitalOcean VPS.
# It sets up Docker, Docker Compose, Apache as a reverse proxy, and secures it with Let's Encrypt SSL.
# The user will be prompted for their subdomain, email, and desired WAHA version.
# A strong API key will be automatically generated.
# Dashboard and Swagger UI access will be secured with Apache basic authentication.
# Additional security measures including comprehensive security headers and Fail2Ban will be configured.

# --- Configuration Variables ---
WAHA_INSTALL_DIR="/opt/waha"
DOCKER_COMPOSE_VERSION="v2.20.2" # A recent stable version of Docker Compose
# .htpasswd files for Apache will be stored in a secure location within Apache's conf
APACHE_HTPASSWD_DIR="/etc/apache2/conf.d" # Directory to store .htpasswd files for Apache basic auth
APACHE_CONF_FILE="/etc/apache2/sites-available/$SUBDOMAIN.conf" # Define it early for consistent usage

# --- Functions ---

# Function to display error and exit
die() {
    echo "ERROR: $1" >&2
    exit 1
}

# --- Preamble and Warnings ---
echo "----------------------------------------------------"
echo "WAHA Automation Installation Script (using Apache)"
echo "----------------------------------------------------"
echo "This script will install Docker, Docker Compose, Apache, Certbot, and Fail2Ban."
echo "It is designed for a fresh Ubuntu 20.04+ DigitalOcean VPS."
echo "IMPORTANT: Ensure your DNS records for your subdomain are pointing to this VPS's IP address BEFORE running this script."
echo "You will be prompted for necessary information."
echo "----------------------------------------------------"
echo ""

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    die "Please run this script with sudo: sudo ./install_waha.sh"
fi

# --- Get User Input ---
read -p "Enter your subdomain (e.g., waha.example.com): " SUBDOMAIN
if [ -z "$SUBDOMAIN" ]; then
    die "Subdomain cannot be empty. Exiting."
fi

read -p "Enter your email address for Let's Encrypt SSL (e.g., your@example.com): " EMAIL
if [ -z "$EMAIL" ]; then
    die "Email cannot be empty. It's required for Let's Encrypt. Exiting."
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

echo "You chose to install $WAHA_TYPE."
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

echo ""
echo "Starting installation for $SUBDOMAIN with $WAHA_TYPE and email $EMAIL..."
echo "----------------------------------------------------"

# --- Update System and Install Prerequisites ---
echo "--> Updating system and installing prerequisites..."
apt update -y || die "Failed to update package lists."
# Install apache2-utils for htpasswd and fail2ban
apt install -y apt-transport-https ca-certificates curl software-properties-common ufw apache2-utils fail2ban || die "Failed to install prerequisites."

# --- Configure UFW Firewall ---
echo "--> Configuring UFW firewall..."
ufw allow OpenSSH || die "Failed to allow OpenSSH."
ufw allow 80/tcp || die "Failed to allow HTTP (port 80)."
ufw allow 443/tcp || die "Failed to allow HTTPS (port 443)."
ufw --force enable || die "Failed to enable UFW."
echo "UFW configured: Ports 80, 443, and SSH are open."

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
usermod -aG docker "$SUDO_USER" # Adds the user who invoked sudo to the docker group
echo "Docker installed successfully."
echo "NOTE: For your user ('$SUDO_USER') to run Docker commands without 'sudo', you may need to log out and log in again, or run 'newgrp docker'."

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
a2ensite "$SUBDOMAIN" || die "Failed to enable Apache site."
a2dissite 000-default || true # Disable default Apache site if it exists
systemctl reload apache2 || die "Failed to reload Apache2. Check logs for details."
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
# Certbot has already created the <VirtualHost *:443> block.
# Now, we need to inject our proxy, basic auth, and security headers into that block.

# Use a temporary file to build the new config for injection
TEMP_APACHE_CONFIG=$(mktemp)

cat <<EOF > "$TEMP_APACHE_CONFIG"
    # Proxy settings
    ProxyRequests Off
    ProxyPreserveHost On
    ProxyTimeout 900 # Increase timeout for long-running operations

    # Main API endpoint (no basic auth here)
    ProxyPass / http://localhost:3000/
    ProxyPassReverse / http://localhost:3000/

    # Proxy for Dashboard with optional Basic Auth
    <Location /dashboard>
        $( [ -n "$DASHBOARD_USERNAME" ] && echo "AuthType Basic" )
        $( [ -n "$DASHBOARD_USERNAME" ] && echo "AuthName \"WAHA Dashboard\"" )
        $( [ -n "$DASHBOARD_USERNAME" ] && echo "AuthUserFile $DASHBOARD_HTPASSWD_FILE" )
        $( [ -n "$DASHBOARD_USERNAME" ] && echo "Require valid-user" )
        # Optional: IP Whitelisting (uncomment and replace with your IP if needed)
        # For example: Require ip YOUR_IP_ADDRESS
        ProxyPass http://localhost:3000/dashboard
        ProxyPassReverse http://localhost:3000/dashboard
    </Location>

    # Proxy for Swagger UI with optional Basic Auth
    <Location /swagger>
        $( [ -n "$SWAGGER_USERNAME" ] && echo "AuthType Basic" )
        $( [ -n "$SWAGGER_USERNAME" ] && echo "AuthName \"WAHA Swagger UI\"" )
        $( [ -n "$SWAGGER_USERNAME" ] && echo "AuthUserFile $SWAGGER_HTPASSWD_FILE" )
        $( [ -n "$SWAGGER_USERNAME" ] && echo "Require valid-user" )
        # Optional: IP Whitelisting (uncomment and replace with your IP if needed)
        # For example: Require ip YOUR_IP_ADDRESS
        ProxyPass http://localhost:3000/swagger
        ProxyPassReverse http://localhost:3000/swagger
    </Location>

    # Proxy for WebSocket connections
    <Location /ws>
        ProxyPass ws://localhost:3000/ws
        ProxyPassReverse ws://localhost:3000/ws
        # Keepalive for WebSockets
        # ProxyPreserveHost On # Already set globally
        RewriteEngine On
        RewriteCond %{HTTP:Upgrade} websocket [NC]
        RewriteCond %{HTTP:Connection} upgrade [NC]
        RewriteRule .* "ws://localhost:3000%{REQUEST_URI}" [P,L]
    </Location>

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
# We look for the line "ServerName $SUBDOMAIN" inside the <VirtualHost *:443> block and insert after it.
# This sed command is complex because it operates on a range and inserts multiline text.
# It finds the first <VirtualHost *:443> block and inserts the content of $TEMP_APACHE_CONFIG after the ServerName line.
sed -i "/<VirtualHost \*:443>/,/<\/VirtualHost>/ {
    /ServerName $SUBDOMAIN/a\\
$(sed -e 's/\\/\\\\/g' -e 's/\//\\\//g' -e '$!s/$/\\/' -e 's/$/\n/' "$TEMP_APACHE_CONFIG")
}" "$APACHE_CONF_FILE" || die "Failed to inject proxy and security configurations into Apache VirtualHost."

rm "$TEMP_APACHE_CONFIG" # Clean up temporary file

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
WAHA_HEALTHCHECK_URL="http://localhost:3000/health" # Default for Plus
if [[ "$WAHA_TYPE" == "WAHA Core" || "$WAHA_TYPE" == "WAHA ARM (Core)" ]]; then
    WAHA_HEALTHCHECK_URL="http://localhost:3000/" # Use root for Core versions
fi


# Start building the environment variables for Docker Compose
WAHA_ENV_VARS="      - BASE_URL=https://$SUBDOMAIN
      - API_KEY=$WAHA_API_KEY"

# Create the docker-compose.yml file for WAHA
cat <<EOF > docker-compose.yml
services:
  waha:
    image: $WAHA_IMAGE
    container_name: waha_container
    restart: always
    ports:
      # Map container port 3000 to host port 3000.
      # Apache will proxy requests to this host port.
      - "3000:3000"
    environment:
$WAHA_ENV_VARS
    volumes:
      - ./data:/app/data # Persist WAHA data to a local 'data' directory
    healthcheck:
      test: ["CMD", "curl", "-f", "$WAHA_HEALTHCHECK_URL"]
      interval: 30s
      timeout: 10s
      retries: 5
EOF

echo "--> Starting WAHA containers using Docker Compose..."
docker compose up -d || die "Failed to start WAHA containers. Check 'docker compose logs -f waha' for errors."

echo ""
echo "----------------------------------------------------"
echo "WAHA Installation Complete!"
echo "----------------------------------------------------"
echo "Your WAHA instance should now be accessible at: https://$SUBDOMAIN"
echo "The API documentation (Swagger) should be at: https://$SUBDOMAIN/swagger"
echo "Your chosen API Key for WAHA is: $WAHA_API_KEY"
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
echo "----------------------------------------------------"
