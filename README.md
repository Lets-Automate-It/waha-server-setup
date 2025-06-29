# WAHA Server Automated Setup Script

This repository contains an automated setup script for deploying a complete WAHA (WhatsApp HTTP API) server with essential security features and SSL certificates.

## What This Script Does

The script automates the setup of:

- ✅ **WAHA (WhatsApp HTTP API)** - Deploys the latest WAHA version using Docker Compose.
- ✅ **SSL/TLS Encryption** - Automatically obtains and configures Let's Encrypt certificates for secure HTTPS access.
- ✅ **Nginx Reverse Proxy** - Sets up Nginx to act as a reverse proxy, handling incoming web traffic and securely forwarding it to the WAHA Docker container.
- ✅ **Firewall Configuration** - Configures UFW (Uncomplicated Firewall) to allow only essential traffic (SSH, HTTP, HTTPS).
- ✅ **Auto-generated Secure Credentials** - Generates strong, random passwords for the WAHA Dashboard, Swagger UI, and the WAHA API Key.

## Requirements

* **Operating System:** Ubuntu 20.04 LTS or newer (or any Debian-based distribution).
* **Server Access:** Root access or `sudo` privileges.
* **Domain Name:** A registered domain name (or subdomain) that you want to use for your WAHA server (e.g., `api.yourdomain.com`).
* **DNS A Record:** **Crucially**, ensure that the A record for your chosen domain/subdomain points to the public IP address of the server where you will run this script. Certbot needs this to verify domain ownership.

## Quick Start

### 1. Prepare Your Server

* **Update System:**
    ```bash
    sudo apt update && sudo apt upgrade -y
    ```
* **Install Git (if not already installed):**
    ```bash
    sudo apt install git -y
    ```

### 2. Download the Script

```bash
git clone https://github.com/Lets-Automate-It/waha-server-setup.git
cd waha-server-setup
chmod +x waha_setup.sh
````

### 3\. Run the Setup Script

Execute the script with `sudo`:

```bash
sudo ./waha_setup.sh
```

The script will guide you through the following interactive prompts:

  * **Domain Name:** Enter your full domain name (e.g., `api.yourdomain.com`). This will be used for Nginx and SSL.
  * **Email Address:** Provide a valid email for Let's Encrypt certificate registration and expiry notifications.
  * **Dashboard Username:** (Optional) Set a custom username for the WAHA dashboard (default: `waha_admin`).

### 4\. Save the Generated Credentials

The script will auto-generate and display secure credentials for the **WAHA Dashboard, Swagger UI, and the API Key**. **Save these immediately in a secure place\! You will need them to access your WAHA instance.** The script will pause until you confirm you've saved them.

### 5\. Installation Process

After inputting details and saving credentials, the script will proceed with the automated installation steps:

  * Updating system packages.
  * Installing essential tools (curl, wget, git, nano, ufw, certbot).
  * Configuring the UFW firewall (allowing SSH, HTTP, HTTPS).
  * Installing Docker and Docker Compose.
  * Installing Nginx and setting up the reverse proxy configuration for your domain.
  * Deploying the WAHA Docker containers.
  * **Obtaining and configuring your SSL certificate** from Let's Encrypt via Certbot.

## What You'll Get

After successful installation, your WAHA server will be accessible via HTTPS:

### Access URLs
* **Main API Endpoint**: `https://api.yourdomain.com/` (Example for a subdomain setup)
* **WAHA Dashboard**: `https://api.yourdomain.com/dashboard` (Example for a subdomain setup)
* **Swagger UI (API Documentation)**: `https://api.yourdomain.com/swagger` (Example for a subdomain setup)

### Credentials

The script will output the following at the end, which you should have already saved:

  * **Dashboard Username:** (your chosen or default `waha_admin`)
  * **Dashboard Password:** (auto-generated)
  * **Swagger Username:** `swagger_admin`
  * **Swagger Password:** (auto-generated)
  * **API Key:** (auto-generated)

### Security Features

  * SSL/TLS encryption for all traffic with auto-renewal (via Certbot).
  * WAHA's built-in Dashboard and Swagger UI are protected by the credentials generated.
  * WAHA's API endpoints require the generated API key for authentication.
  * The firewall is configured to only expose necessary services.

### File Locations

  * **WAHA Application Data:** `/opt/waha/` (contains `docker-compose.yaml`, `.env`, and WAHA session/media data)
  * **Nginx Configuration:** `/etc/nginx/sites-available/your_domain.com` (symlinked to `sites-enabled`)

## Quick Commands

After installation, you can manage your WAHA server using these commands (navigate to `/opt/waha` first):

```bash
cd /opt/waha

# Check WAHA container status
docker compose ps

# View WAHA logs (streaming)
docker compose logs -f waha

# Restart WAHA service
docker compose restart waha

# Update WAHA to the latest image
docker compose pull waha && docker compose up -d waha
```

## Troubleshooting

### Common Issues

1.  **Domain not resolving**: Ensure your DNS A record for `your_domain.com` correctly points to your server's public IP address. DNS changes can take some time to propagate.
2.  **SSL certificate failed**:
      * Verify your DNS A record is correctly set.
      * Ensure your domain is accessible on port 80 from the internet (check firewall).
      * Review Certbot logs: `cat /var/log/letsencrypt/letsencrypt.log`
3.  **Can't access dashboard/API**:
      * Verify you're using the correct generated credentials.
      * Ensure Nginx is running (`sudo systemctl status nginx`).
      * Check Nginx configuration: `sudo nginx -t` and `sudo cat /etc/nginx/sites-available/your_domain.com`
      * Check Nginx error logs: `sudo tail -f /var/log/nginx/error.log`
      * Check WAHA Docker logs: `cd /opt/waha && docker compose logs -f waha`
4.  **WAHA container not starting**:
      * Check Docker Compose logs: `cd /opt/waha && docker compose logs -f waha`
      * Ensure Docker is running (`sudo systemctl status docker`).

### Getting Help

  * View WAHA logs: `cd /opt/waha && docker compose logs -f waha`
  * Check Nginx service status: `sudo systemctl status nginx`
  * Check Certbot logs: `sudo cat /var/log/letsencrypt/letsencrypt.log`
  * **WAHA Documentation**: `https://waha.devlike.pro/docs/`
  * **Docker Documentation**: `https://docs.docker.com/`
  * **Nginx Documentation**: `https://nginx.org/en/docs/`

## Security Notes

  * 🔒 All sensitive passwords are auto-generated and secure.
  * 🔒 SSL certificates are automatically obtained and renewed via Let's Encrypt.
  * 🔒 WAHA's dashboard and API are protected by credentials.
  * 🔒 The firewall is configured to expose only necessary services.

## Manual Configuration

This script provides a streamlined setup. For advanced users who want to customize further (e.g., integrating additional security layers like Fail2ban, custom basic auth via Nginx, or different WAHA configurations), you will need to manually adjust the generated files after the script completes.

## License

This script is provided as-is for educational and production use. Please review and test in a non-production environment first.

-----

**⚠️ Important**: This script installs production-ready software with security features. Always ensure your DNS A record is correctly set before running, and review generated credentials carefully.

```
```
