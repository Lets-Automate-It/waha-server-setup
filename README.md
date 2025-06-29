WAHA Automated Installation Script (Apache)
This script automates the deployment of a WAHA (WhatsApp HTTP API) instance on an Ubuntu DigitalOcean VPS, using Apache as a reverse proxy and securing it with Let's Encrypt SSL. It's designed to streamline the setup process, incorporating various security best practices.

Table of Contents
Features

Prerequisites

How to Use

Script Prompts

Access Details

Security Measures Implemented

Troubleshooting & Management

Important Notes

Features
Automated Installation: Installs Docker, Docker Compose, Apache2, Certbot, and Fail2Ban.

WAHA Version Selection: Allows choosing between WAHA Core, WAHA Plus, or WAHA ARM.

Subdomain & SSL Setup: Configures Apache for your specified subdomain and obtains a Let's Encrypt SSL certificate for HTTPS.

Auto-generated API Key: Automatically generates a strong API key for WAHA.

Apache Basic Authentication: Secures the WAHA Dashboard and Swagger UI with optional HTTP Basic Authentication (username/password prompts). This applies regardless of the chosen WAHA version, protecting these web interfaces via Apache.

Security Headers: Implements various security headers (HSTS, X-Frame-Options, X-Content-Type-Options, X-XSS-Protection, Referrer-Policy, Content-Security-Policy) to harden your Apache server.

Fail2Ban Integration: Configures Fail2Ban to monitor Apache logs for failed authentication attempts and excessive requests, automatically banning malicious IPs.

Docker Compose Deployment: Sets up WAHA as a Docker container using docker compose for easy management and persistence.

Nginx Uninstallation: Includes a step to detect and uninstall Nginx if it was previously installed, preventing port conflicts.

Prerequisites
A fresh Ubuntu 20.04+ DigitalOcean VPS (or any similar Ubuntu server).

DNS records for your subdomain (e.g., waha.yourdomain.com) must be correctly pointing to your VPS's IP address BEFORE running this script.

How to Use
SSH into your DigitalOcean Droplet:

ssh your_user@your_droplet_ip

(Replace your_user and your_droplet_ip with your actual login details.)

Install Git (if not already installed):

sudo apt update
sudo apt install git -y

Clone this GitHub Repository:

cd ~
git clone https://github.com/Lets-Automate-It/waha-server-setup.git # Replace with your actual repo URL if different

(If your repository is private, you will be prompted for your GitHub username and Personal Access Token.)

Navigate into the cloned directory:

cd waha-server-setup

Make the script executable:

chmod +x waha_server_setup.sh

Run the script:

sudo ./waha_server_setup.sh

The script will then guide you through the setup process with interactive prompts.

Script Prompts
During execution, the script will ask for:

Your Subdomain: The domain name where WAHA will be accessible (e.g., waha.example.com).

Your Email Address: Used by Let's Encrypt for SSL certificate registration and urgent notices.

WAHA Version Choice:

WAHA Core (Free, open-source)

WAHA Plus (Commercial, advanced features)

WAHA ARM (For ARM-based architectures like Raspberry Pi)

Dashboard Username (Optional): A username for HTTP Basic Authentication for the /dashboard interface. Leave empty to skip.

Dashboard Password (Optional): A password if a Dashboard username was provided.

Swagger Username (Optional): A username for HTTP Basic Authentication for the /swagger interface. Leave empty to skip.

Swagger Password (Optional): A password if a Swagger username was provided.

Access Details
Upon successful completion, the script will output:

WAHA Instance URL: https://your_subdomain

API Documentation (Swagger): https://your_subdomain/swagger

Your WAHA API Key: The auto-generated key to be used for API requests.

Dashboard Basic Auth Credentials: (If set) Username and Password for the /dashboard interface.

Swagger UI Basic Auth Credentials: (If set) Username and Password for the /swagger interface.

Security Measures Implemented
Apache Basic Authentication: Secure login for /dashboard and /swagger paths, protecting these web interfaces.

API Key Authentication: The main / API endpoint is secured by the API_KEY passed to the WAHA container.

Let's Encrypt SSL/TLS: All traffic is encrypted using free SSL certificates from Let's Encrypt.

HTTP to HTTPS Redirection: All HTTP requests are automatically redirected to HTTPS.

Firewall (UFW): Configured to only allow essential ports (SSH, HTTP, HTTPS).

Apache Security Headers: Implements X-Frame-Options, X-Content-Type-Options, X-XSS-Protection, Referrer-Policy, Strict-Transport-Security (HSTS), and a basic Content-Security-Policy.

Sensitive File Protection: Apache configuration includes rules to deny access to hidden files (.ht*) like .htpasswd.

Fail2Ban: Monitors Apache logs for:

apache-auth: Failed HTTP Basic Authentication attempts.

apache-noscript: Attempts to execute scripts where they shouldn't.

Automatically bans malicious IPs for 30 minutes after 10 failed attempts within 10 minutes.

Troubleshooting & Management
Blank Page After Dashboard/Swagger Login (Core Versions): If you chose WAHA Core or WAHA ARM (Core), the Dashboard and Swagger UI are not part of the application itself. Apache's basic authentication will work, but the backend will serve no content, leading to a blank page. These interfaces require WAHA Plus.

500 Internal Server Error: This usually means the WAHA Docker container is not running or is encountering an internal error.

To debug:

cd /opt/waha
docker compose logs -f waha

Look for error messages within the WAHA logs.

Blocked by Fail2Ban: If your IP gets banned due to too many failed attempts or rate limit violations, you can unban it (replace YOUR_IP with your actual IP address):

sudo fail2ban-client set apache-auth unbanip YOUR_IP
sudo fail2ban-client set apache-noscript unbanip YOUR_IP

Check Fail2Ban Status:

sudo fail2ban-client status

Flush Local DNS Cache: If you experience access issues despite successful installation, try clearing your browser cache or flushing your local machine's DNS cache.

WAHA Data Persistence: WAHA data (sessions, etc.) is persisted in the /opt/waha/data directory on your VPS.

Managing WAHA Containers:

cd /opt/waha
docker compose stop    # To stop WAHA
docker compose start   # To start WAHA
docker compose down    # To stop and remove containers/networks/volumes

Important Notes
This script provides a strong foundation for security, but no system is 100% impervious to attack. Regularly update your system (sudo apt update && sudo apt upgrade -y) and monitor logs.

The Content-Security-Policy header provided is a basic example. Depending on future WAHA updates or any custom integrations, you may need to adjust this policy to allow specific external resources (e.g., Google Fonts, external JavaScript libraries). Monitor your browser's developer console for CSP errors.

Apache's built-in rate limiting capabilities (e.g., with mod_qos) are more complex than Nginx's limit_req and are not included in this script to simplify the initial setup and avoid potential over-blocking. For high-traffic production environments, consider researching and implementing advanced Apache rate limiting.
