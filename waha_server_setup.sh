#!/bin/bash

# This script automates the installation of WAHA (WhatsApp Automation Tool) on an Ubuntu DigitalOcean VPS.
# It sets up Docker, Docker Compose, Nginx as a reverse proxy, and secures it with Let's Encrypt SSL.
# The user will be prompted for their subdomain, email, desired WAHA version.
# A strong API key will be automatically generated.
# Dashboard and Swagger UI access will be secured with Nginx basic authentication, regardless of WAHA version.
# Additional security measures including Nginx rate limiting, security headers, and Fail2Ban will be configured.

# --- Configuration Variables ---
WAHA_INSTALL_DIR="/opt/waha"
DOCKER_COMPOSE_VERSION="v2.20.2" # A recent stable version of Docker Compose
HTPASSWD_DIR="/etc/nginx/conf.d" # Directory to store .htpasswd files
NGINX_CONF_D_DIR="/etc/nginx/conf.d" # Directory for additional Nginx configs

# --- Functions ---

# Function to display error and exit
die() {
    echo "ERROR: $1" >&2
    exit 1
}

# --- Preamble and Warnings ---
echo "----------------------------------------------------"
echo "WAHA Automation Installation Script"
echo "----------------------------------------------------"
echo "This script will install Docker, Docker Compose, Nginx, Certbot, and WAHA."
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
echo ""

# --- Auto-generate a strong API key ---
echo "--> Automatically generating a strong WAHA API Key..."
WAHA_API_KEY=$(openssl rand -base64 32)
if [ -z "$WAHA_API_KEY" ]; then
    die "Failed to auto-generate API Key. Exiting."
fi
echo "Generated API Key: $WAHA_API_KEY"
echo ""

# --- Get Dashboard and Swagger UI Nginx Basic Auth Credentials (Optional) ---
DASHBOARD_HTPASSWD_FILE="$HTPASSWD_DIR/${SUBDOMAIN}_dashboard.htpasswd"
SWAGGER_HTPASSWD_FILE="$HTPASSWD_DIR/${SUBDOMAIN}_swagger.htpasswd"

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
# Added fail2ban to prerequisites
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
echo "NOTE: For your user ('$SUDO_USER') to run Docker commands without 'sudo', you may need to log out and log back in, or run 'newgrp docker'."

# --- Install Nginx and Certbot ---
echo "--> Installing Nginx and Certbot..."
apt install -y nginx certbot python3-certbot-nginx || die "Failed to install Nginx or Certbot."

# --- Create .htpasswd files if credentials provided ---
mkdir -p "$HTPASSWD_DIR" || die "Failed to create .htpasswd directory."
if [ -n "$DASHBOARD_USERNAME" ]; then
    echo "Creating .htpasswd for Dashboard..."
    htpasswd -cb "$DASHBOARD_HTPASSWD_FILE" "$DASHBOARD_USERNAME" "$DASHBOARD_PASSWORD" || die "Failed to create dashboard .htpasswd file."
    chmod 640 "$DASHBOARD_HTPASSWD_FILE" # Secure permissions
fi

if [ -n "$SWAGGER_USERNAME" ]; then
    echo "Creating .htpasswd for Swagger UI..."
    htpasswd -cb "$SWAGGER_HTPASSWD_FILE" "$SWAGGER_USERNAME" "$SWAGGER_PASSWORD" || die "Failed to create swagger .htpasswd file."
    chmod 640 "$SWAGGER_HTPASSWD_FILE" # Secure permissions
fi

# --- Configure Nginx Rate Limiting Zones and Security Headers ---
echo "--> Configuring Nginx global security settings and rate limiting zones..."
mkdir -p "$NGINX_CONF_D_DIR" || die "Failed to create Nginx conf.d directory."

# Create a file for global Nginx settings (rate limiting zones, security headers)
cat <<EOF > "$NGINX_CONF_D_DIR/waha_security_headers_and_rate_limits.conf"
# Rate limiting zones (located in http context, so define in /etc/nginx/conf.d/)
# Limit dashboard/swagger requests to 100 requests per second, with a burst of 50.
# This allows for a burst of requests (e.g., loading multiple JS files) but limits sustained rate.
limit_req_zone \$binary_remote_addr zone=dashboard_req_limit:10m rate=100r/s;
# Limit main API requests to 50 requests per second, with a burst of 50.
limit_req_zone \$binary_remote_addr zone=api_req_limit:10m rate=50r/s;

# Optional: Limit concurrent connections per IP
# limit_conn_zone \$binary_remote_addr zone=conn_limit:10m;

# Global Security Headers
add_header X-Frame-Options SAMEORIGIN always;
add_header X-Content-Type-Options nosniff always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "no-referrer-when-downgrade" always;
# Strict-Transport-Security (HSTS)
# This header ensures that the browser only communicates with the server over HTTPS,
# preventing MITM attacks. Max-age typically 6 months to 2 years.
add_header Strict-Transport-Security "max-age=15768000; includeSubDomains; preload" always;
# Content-Security-Policy: IMPORTANT: This can break websites if not properly configured.
# This policy is a basic one that allows content from the same origin ('self') and
# allows inline styles ('unsafe-inline') which are common for dashboards.
# You might need to adjust this based on specific external resources or inline scripts
# used by WAHA's dashboard/swagger.
# For example, if it uses Google Fonts, you'd need to add 'fonts.googleapis.com' to font-src.
add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self';" always;
EOF

# Link this global config file to Nginx's main config
# Check if the line already exists in nginx.conf to avoid duplicates
if ! grep -q "include $NGINX_CONF_D_DIR/waha_security_headers_and_rate_limits.conf;" /etc/nginx/nginx.conf; then
    # Add include statement to the http block in nginx.conf
    # This requires a bit of sed magic to insert inside the http block
    sed -i '/^http {/a \ \ include /etc/nginx/conf.d/waha_security_headers_and_rate_limits.conf;' /etc/nginx/nginx.conf || die "Failed to add Nginx security headers include."
fi


# --- Configure Nginx for WAHA - Stage 1 (HTTP and Certbot Challenge) ---
echo "--> Configuring Nginx for $SUBDOMAIN (Stage 1: HTTP and Certbot Challenge)..."
NGINX_CONFIG_FILE="/etc/nginx/sites-available/$SUBDOMAIN"

cat <<EOF > "$NGINX_CONFIG_FILE"
server {
    listen 80;
    listen [::]:80;
    server_name $SUBDOMAIN;

    # Certbot challenge path
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # Redirect all HTTP traffic to HTTPS (temporary, will be updated after cert)
    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

# Enable the Nginx site by creating a symlink
ln -sf "$NGINX_CONFIG_FILE" /etc/nginx/sites-enabled/ || die "Failed to create Nginx symlink." # Use -sf to force symlink update if it exists

# Test Nginx configuration for syntax errors
nginx -t || die "Nginx configuration test failed. Please check the config file."
systemctl reload nginx || die "Failed to reload Nginx. Check logs for details."
echo "Nginx Stage 1 configured. Proceeding to obtain SSL certificate..."

# --- Obtain Let's Encrypt SSL Certificate ---
echo "--> Obtaining Let's Encrypt SSL certificate for $SUBDOMAIN..."
# Create a dummy webroot for certbot initial challenge
mkdir -p /var/www/certbot
chmod -R 755 /var/www/certbot

# Run Certbot to get and install the SSL certificate
# --no-redirect is important so Certbot doesn't automatically add a redirect to 443 here,
# we will add the full 443 block later.
certbot --nginx -d "$SUBDOMAIN" --non-interactive --agree-tos -m "$EMAIL" --no-redirect || die "Failed to obtain SSL certificate. Please ensure your DNS is correctly set up for $SUBDOMAIN and try again."

echo "SSL certificate obtained. Updating Nginx for HTTPS proxy..."

# --- Configure Nginx for WAHA - Stage 2 (HTTPS with Proxy Pass and Basic Auth) ---
# Now that Certbot has run and created the necessary SSL files,
# we can update the Nginx config to include the HTTPS block and proxy passes.
cat <<EOF > "$NGINX_CONFIG_FILE"
server {
    listen 80;
    listen [::]:80;
    server_name $SUBDOMAIN;

    # Certbot challenge path
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # Deny access to hidden files like .htpasswd or .env
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    # Redirect all HTTP traffic to HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $SUBDOMAIN;

    http2 on; # Explicitly enable HTTP/2 if desired

    # SSL certificate paths generated by Certbot
    ssl_certificate /etc/letsencrypt/live/$SUBDOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$SUBDOMAIN/privkey.pem;

    # Recommended SSL settings from Certbot (this file should now exist)
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    # Main API endpoint
    location / {
        limit_req zone=api_req_limit burst=50 nodelay; # Apply rate limiting
        # Optional: IP Whitelisting (uncomment and replace with your IP if needed)
        # allow YOUR_IP_ADDRESS;
        # deny all;

        proxy_pass http://localhost:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        # Increase timeouts for potentially long-running WAHA operations
        proxy_read_timeout 900;
        proxy_send_timeout 900;
        proxy_connect_timeout 900;
        send_timeout 900;
    }

    # Proxy for Dashboard with optional Basic Auth
    location /dashboard {
        limit_req zone=dashboard_req_limit burst=50 nodelay; # Apply rate limiting
        # Basic authentication for dashboard if username was provided
        $( [ -n "$DASHBOARD_USERNAME" ] && echo "auth_basic \"WAHA Dashboard\";" )
        $( [ -n "$DASHBOARD_USERNAME" ] && echo "auth_basic_user_file $DASHBOARD_HTPASSWD_FILE;" )
        # Optional: IP Whitelisting (uncomment and replace with your IP if needed)
        # allow YOUR_IP_ADDRESS;
        # deny all;

        proxy_pass http://localhost:3000/dashboard;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # Proxy for Swagger UI with optional Basic Auth
    location /swagger {
        limit_req zone=dashboard_req_limit burst=50 nodelay; # Use dashboard rate limit for Swagger too
        # Basic authentication for swagger if username was provided
        $( [ -n "$SWAGGER_USERNAME" ] && echo "auth_basic \"WAHA Swagger UI\";" )
        $( [ -n "$SWAGGER_USERNAME" ] && echo "auth_basic_user_file $SWAGGER_HTPASSWD_FILE;" )
        # Optional: IP Whitelisting (uncomment and replace with your IP if needed)
        # allow YOUR_IP_ADDRESS;
        # deny all;

        proxy_pass http://localhost:3000/swagger;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# Test Nginx configuration for syntax errors after full config
nginx -t || die "Nginx final configuration test failed. Please check the config file."
systemctl reload nginx || die "Failed to reload Nginx after final SSL/proxy config. Check logs for details."
echo "Nginx fully configured with SSL, proxy passes, rate limiting, and security headers."


# --- Configure Fail2Ban ---
echo "--> Configuring Fail2Ban for Nginx protection..."
FAIL2BAN_JAIL_FILE="/etc/fail2ban/jail.d/nginx-waha.conf"

cat <<EOF > "$FAIL2BAN_JAIL_FILE"
[nginx-http-auth]
enabled = true
port = http,https
filter = nginx-http-auth
logpath = /var/log/nginx/access.log
maxretry = 10
bantime = 1800 ; 30 minutes
findtime = 600  ; 10 minutes

[nginx-req-limit]
enabled = true
port = http,https
filter = nginx-req-limit
logpath = /var/log/nginx/error.log
maxretry = 10
bantime = 1800 ; 30 minutes
findtime = 600  ; 10 minutes
EOF

# Add Nginx filters for Fail2Ban if they don't exist
# For http-auth failures
if [ ! -f "/etc/fail2ban/filter.d/nginx-http-auth.conf" ]; then
cat <<'EOF' > "/etc/fail2ban/filter.d/nginx-http-auth.conf"
[Definition]
failregex = ^<HOST> -.* " (GET|POST|HEAD|PUT|DELETE|OPTIONS) .* HTTP/\d\.\d" 401 \d+ ".*" ".*"$
ignoreregex =
EOF
fi

# For rate limit violations (these usually appear in error.log)
if [ ! -f "/etc/fail2ban/filter.d/nginx-req-limit.conf" ]; then
cat <<'EOF' > "/etc/fail2ban/filter.d/nginx-req-limit.conf"
[Definition]
failregex = ^\s*\[error\] \d+#\d+: \(#\d+\) *limiting requests, excess: \d\.\d+ by zone ".*", client: <HOST>
ignoreregex =
EOF
fi

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
      # Nginx will proxy requests to this host port.
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
echo "- Your instance is now protected with Nginx Basic Authentication for Dashboard/Swagger, API Key for the main API, Nginx Rate Limiting, Security Headers, and Fail2Ban."
echo "- If you are getting a '500 Internal Server Error' after authentication, this likely means"
echo "  the WAHA Docker container is not running or is experiencing an internal error."
echo "  To debug this, navigate to the WAHA installation directory and check the container logs:"
echo "  cd $WAHA_INSTALL_DIR"
echo "  docker compose logs -f waha"
echo "  Look for error messages within the WAHA logs to pinpoint the issue."
echo "- If you get blocked by Fail2Ban, you can unban your IP (replace YOUR_IP) with:"
echo "  sudo fail2ban-client set nginx-http-auth unbanip YOUR_IP"
echo "  sudo fail2ban-client set nginx-req-limit unbanip YOUR_IP"
echo "- To check Fail2Ban status: sudo fail2ban-client status"
echo "- To flush your local DNS cache if access issues persist, refer to your OS instructions."
echo "- WAHA data is persisted in '$WAHA_INSTALL_DIR/data'."
echo "- To stop/start/restart WAHA: 'cd $WAHA_INSTALL_DIR && docker compose stop/start/restart'"
echo "----------------------------------------------------"
