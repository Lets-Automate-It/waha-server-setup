# WAHA Server Automated Setup

This repository contains an automated setup script for deploying a complete WAHA (WhatsApp HTTP API) server with security features, SSL certificates, and monitoring.

## What This Script Does

The script automatically sets up:

- ✅ **WAHA (WhatsApp HTTP API)** - Latest version with Docker
- ✅ **SSL/TLS Encryption** - Let's Encrypt certificates
- ✅ **Nginx Reverse Proxy** - With security headers and rate limiting
- ✅ **HTTP Basic Authentication** - For dashboard and API docs
- ✅ **Fail2ban Protection** - Against brute force attacks
- ✅ **Firewall Configuration** - UFW with proper ports
- ✅ **Auto-generated Secure Credentials** - API keys and passwords
- ✅ **Complete Documentation** - Quick reference guide

## Requirements

- Ubuntu 22.04+ server
- Root or sudo access
- Domain name pointing to your server IP
- Valid email address for SSL certificate

## Quick Start

### 1. Download and Run the Script

```bash
# Download the script
wget https://raw.githubusercontent.com/YOUR_USERNAME/waha-server-setup/main/waha_server_setup.sh

# Make it executable
chmod +x waha_server_setup.sh

# Run as root
sudo ./waha_server_setup.sh
```

### 2. Follow the Interactive Prompts

The script will ask you for:
- Your domain name (e.g., `api.yourdomain.com`)
- Your email address (for SSL certificate)
- Dashboard username (default: `waha_admin`)

### 3. Save the Generated Credentials

The script will generate secure credentials. **Save these immediately!**

## What You'll Get

After successful installation:

### Access URLs
- **Main API**: `https://yourdomain.com/`
- **Dashboard**: `https://yourdomain.com/dashboard/`
- **API Documentation**: `https://yourdomain.com/docs`

### Security Features
- SSL/TLS encryption with auto-renewal
- HTTP Basic Authentication for sensitive areas
- API key authentication for endpoints
- Fail2ban protection against attacks
- Security headers (HSTS, XSS protection, etc.)
- Firewall configuration

### Files Created
- Configuration: `/root/waha/.env`
- Quick Reference: `/root/waha/WAHA_QUICK_REFERENCE.md`
- Nginx Config: `/etc/nginx/sites-available/waha-secure`

## Quick Commands

After installation, you can manage your WAHA server with these commands:

```bash
# Check WAHA status
cd /root/waha && docker compose ps

# View WAHA logs
docker compose logs waha --tail 20

# Restart WAHA
docker compose restart

# Update WAHA
docker compose pull && docker compose up -d
```

## Troubleshooting

### Common Issues

1. **Domain not resolving**: Ensure your DNS A record points to your server IP
2. **SSL certificate failed**: Check that your domain is accessible on port 80
3. **Can't access dashboard**: Verify you're using the correct credentials
4. **WAHA container not starting**: Check logs with `docker compose logs waha`

### Getting Help

- Check the generated quick reference guide: `/root/waha/WAHA_QUICK_REFERENCE.md`
- View WAHA logs: `cd /root/waha && docker compose logs waha`
- Check system logs: `journalctl -u nginx` or `journalctl -u fail2ban`

## Security Notes

- 🔒 All passwords are auto-generated and secure
- 🔒 Dashboard and API docs are protected with HTTP Basic Auth
- 🔒 API endpoints require API key authentication
- 🔒 Fail2ban monitors and blocks suspicious activity
- 🔒 SSL certificates auto-renew every 90 days
- 🔒 Security headers are configured in Nginx

## Manual Configuration

For advanced users who want to customize the installation, refer to the complete installation guide that includes:

- Custom password setup
- Advanced security configuration
- Monitoring setup
- Backup procedures

## Support

- **WAHA Documentation**: https://waha.devlike.pro/docs/
- **Docker Documentation**: https://docs.docker.com/
- **Nginx Documentation**: https://nginx.org/en/docs/

## License

This script is provided as-is for educational and production use. Please review and test in a non-production environment first.

---

**⚠️ Important**: This script installs production-ready software with security features. Always backup your data and test in a development environment first.
