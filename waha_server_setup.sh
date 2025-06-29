#!/bin/bash

# This script automates the installation of WAHA (WhatsApp Automation Tool) on an Ubuntu DigitalOcean VPS.
# It sets up Docker, Docker Compose, Nginx as a reverse proxy, and secures it with Let's Encrypt SSL.
# The user will be prompted for their subdomain, email, desired WAHA version.
# A strong API key will be automatically generated.

# --- Configuration Variables ---
WAHA_INSTALL_DIR="/opt/waha"
DOCKER_COMPOSE_VERSION="v2.20.2" # A recent stable version of Docker Compose

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

echo ""
echo "Starting installation for $SUBDOMAIN with $WAHA_TYPE and email $EMAIL..."
echo "----------------------------------------------------"

# --- Update System and Install Prerequisites ---
echo "--> Updating system and installing prerequisites..."
apt update -y || die "Failed to update package lists."
apt install -y apt-transport-https ca-certificates curl software-properties-common ufw || die "Failed to install prerequisites."

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

# --- Configure Nginx for WAHA - Stage 2 (HTTPS with Proxy Pass) ---
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

    # Redirect all HTTP traffic to HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl; # Removed http2 as a separate directive due to deprecation warning.
    listen [::]:443 ssl;
    server_name $SUBDOMAIN;

    http2 on; # Explicitly enable HTTP/2 if desired (can be removed if not needed)

    # SSL certificate paths generated by Certbot
    ssl_certificate /etc/letsencrypt/live/$SUBDOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$SUBDOMAIN/privkey.pem;

    # Recommended SSL settings from Certbot (this file should now exist)
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # This file should also exist after certbot

    # Proxy requests to the WAHA Docker container (typically on port 3000)
    location / {
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

    # Proxy for Swagger UI
    location /swagger {
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
echo "Nginx fully configured with SSL and proxy passes."


# --- Deploy WAHA with Docker Compose ---
echo "--> Creating WAHA Docker Compose setup in $WAHA_INSTALL_DIR..."
mkdir -p "$WAHA_INSTALL_DIR" || die "Failed to create WAHA install directory."
cd "$WAHA_INSTALL_DIR" || die "Failed to change to WAHA install directory."

# Create the docker-compose.yml file for WAHA
cat <<EOF > docker-compose.yml
version: '3.8'

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
      # WAHA configuration variables
      - BASE_URL=https://$SUBDOMAIN
      - API_KEY=$WAHA_API_KEY
      # Uncomment and set strong credentials for Dashboard and Swagger if you want to protect them with basic auth.
      # - DASHBOARD_USERNAME=admin
      # - DASHBOARD_PASSWORD=your_dashboard_password
      # - SWAGGER_USERNAME=swagger
      # - SWAGGER_PASSWORD=your_swagger_password
    volumes:
      - ./data:/app/data # Persist WAHA data to a local 'data' directory
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      interval: 30s
      timeout: 10s
      retries: 5
EOF

echo "--> Starting WAHA containers using Docker Compose..."
docker compose up -d || die "Failed to start WAHA containers. Check 'docker compose logs -f' for errors."

echo ""
echo "----------------------------------------------------"
echo "WAHA Installation Complete!"
echo "----------------------------------------------------"
echo "Your WAHA instance should now be accessible at: https://$SUBDOMAIN"
echo "The API documentation (Swagger) should be at: https://$SUBDOMAIN/swagger"
echo "Your chosen API Key for WAHA is: $WAHA_API_KEY"
echo ""
echo "Important Notes:"
echo "- Ensure your DNS A/AAAA records for $SUBDOMAIN are correctly pointing to this VPS's IP address."
echo "- WAHA data is persisted in '$WAHA_INSTALL_DIR/data'."
echo "- To check WAHA logs: 'cd $WAHA_INSTALL_DIR && docker compose logs -f'"
echo "- To stop/start/restart WAHA: 'cd $WAHA_INSTALL_DIR && docker compose stop/start/restart'"
echo "- For enhanced security, consider setting DASHBOARD_USERNAME, DASHBOARD_PASSWORD, SWAGGER_USERNAME, and SWAGGER_PASSWORD in your docker-compose.yml file. Edit '$WAHA_INSTALL_DIR/docker-compose.yml' and then run 'docker compose up -d'."
echo "----------------------------------------------------"

