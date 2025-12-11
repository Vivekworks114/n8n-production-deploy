# n8n Production Deployment

A production-ready Docker Compose setup for deploying n8n on a DigitalOcean droplet with PostgreSQL, Traefik reverse proxy, automatic updates via Watchtower, and automated backups to Wasabi.

## 🚀 Features

- **n8n** - Latest stable version with production optimizations
- **PostgreSQL 16** - Reliable database backend
- **Traefik v3.1** - Reverse proxy with automatic HTTPS via Let's Encrypt
- **Watchtower** - Automatic container updates for n8n
- **Automated Backups** - Daily PostgreSQL backups to Wasabi cloud storage
- **Security Hardened** - Internal networks, encrypted data, best practices

## 📋 Prerequisites

Before deploying, ensure your DigitalOcean droplet has:

- **Ubuntu 22.04 LTS** (or similar Linux distribution)
- **Docker** (version 20.10+)
- **Docker Compose** (version 2.0+)
- **Domain name** pointing to your droplet's IP address
- **Firewall configured** (see Security section below)

### Installing Docker & Docker Compose

If not already installed:

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker $USER

# Install Docker Compose
sudo apt install docker-compose-plugin -y

# Log out and back in for group changes to take effect
```

Verify installation:

```bash
docker --version
docker compose version
```

## 🔒 Security Setup

### Firewall Configuration (UFW)

Configure UFW to allow only necessary ports:

```bash
# Allow SSH (adjust port if you use non-standard)
sudo ufw allow 22/tcp

# Allow HTTP and HTTPS
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

# Enable firewall
sudo ufw enable

# Check status
sudo ufw status
```

### DNS Configuration

Point your domain to your droplet's IP address:

- Create an **A record** in your DNS settings:
  - **Name**: `n8n` (or your subdomain)
  - **Type**: `A`
  - **Value**: Your droplet's IP address
  - **TTL**: 3600 (or default)

Wait for DNS propagation (can take a few minutes to 48 hours).

## 📦 Installation

### 1. Clone the Repository

```bash
git clone https://github.com/Vivekworks114/n8n-production-deploy.git
cd n8n-production-deploy
```

### 2. Configure Environment Variables

```bash
# Copy the example environment file
cp .env.example .env

# Edit with your preferred editor
nano .env
```

**Critical values to set:**

- `POSTGRES_PASSWORD` - Strong password for PostgreSQL
- `N8N_HOST` - Your domain name (e.g., `n8n.example.com`)
- `WEBHOOK_URL` - Full URL matching your domain
- `N8N_ENCRYPTION_KEY` - Generate with: `openssl rand -base64 32`
- `ACME_EMAIL` - Your email for Let's Encrypt notifications

### 3. Set Up Traefik ACME Storage

```bash
# Create acme.json with correct permissions
touch traefik/acme.json
chmod 600 traefik/acme.json
```

### 4. Set Up Wasabi Backup (Optional but Recommended)

Install rclone:

```bash
curl https://rclone.org/install.sh | sudo bash
```

Configure rclone for Wasabi:

```bash
rclone config
```

When prompted, use these settings:

- **Name**: `wasabi`
- **Storage type**: `s3`
- **Provider**: `Other` (then select Wasabi)
- **Access Key ID**: Your Wasabi access key
- **Secret Access Key**: Your Wasabi secret key
- **Region**: Your Wasabi region (e.g., `us-east-1`)
- **Endpoint**: `s3.wasabisys.com` (or your region endpoint)

Add this to your rclone config (`~/.config/rclone/rclone.conf`):

```ini
[wasabi]
type = s3
provider = Wasabi
access_key_id = YOUR_ACCESS_KEY
secret_access_key = YOUR_SECRET_KEY
region = us-east-1
endpoint = s3.wasabisys.com
```

### 5. Fix Permissions (Important!)

Before starting services, ensure proper permissions for data directories:

```bash
# Run the permissions fix script
./scripts/fix-permissions.sh
```

**Or manually fix permissions:**

```bash
# Fix n8n data directory (runs as UID 1000)
sudo chown -R 1000:1000 ./data
sudo chmod -R 755 ./data

# Fix postgres data directory (runs as UID 999)
sudo chown -R 999:999 ./postgres
sudo chmod -R 755 ./postgres

# Fix diun data directory
sudo chown -R 1000:1000 ./diun/data
sudo chmod -R 755 ./diun/data
```

**Note:** If you encounter `EACCES: permission denied` errors, this is a permissions issue. The containers run as specific users (n8n as UID 1000, postgres as UID 999), and the host directories must be owned by these users.

### 6. Start the Services

```bash
# Start all services
docker compose up -d

# Check status
docker compose ps

# View logs
docker compose logs -f
```

### 7. Access n8n

Once services are running and DNS has propagated:

1. Open your browser and navigate to: `https://your-domain.com`
2. You should see the n8n setup page
3. Create your first user account (this becomes the owner if user management is disabled)

## 📊 Monitoring & Logs

### View Logs

```bash
# All services
docker compose logs -f

# Specific service
docker compose logs -f n8n
docker compose logs -f postgres
docker compose logs -f traefik

# Last 100 lines
docker compose logs --tail=100 n8n
```

### Check Service Status

```bash
# Container status
docker compose ps

# Resource usage
docker stats

# Network connectivity
docker network ls
docker network inspect n8n-production-deploy_traefik-network
```

## 🔄 Automatic Updates

**Watchtower** automatically updates the n8n container when new versions are released.

- **Update interval**: Every hour (3600 seconds)
- **Auto-cleanup**: Old images are automatically removed
- **Only n8n updates**: Traefik and Watchtower require manual updates for stability

### Manual Update

To manually update n8n:

```bash
# Pull latest image
docker compose pull n8n

# Restart service
docker compose up -d n8n
```

## 💾 Backup System

### Automated Backups

The backup script (`backups/backup.sh`) runs daily via cron and:

1. Creates a PostgreSQL dump
2. Compresses it with gzip
3. Uploads to Wasabi: `n8n-prod/db-backups/YYYY-MM-DD/`
4. Cleans local backups older than 14 days

### Setting Up Automated Backups

Add to crontab:

```bash
# Edit crontab
crontab -e

# Add this line (runs daily at 2 AM)
0 2 * * * /path/to/n8n-production-deploy/backups/backup.sh >> /var/log/n8n-backup.log 2>&1
```

### Manual Backup

```bash
# Run backup script manually
./backups/backup.sh
```

### Backup File Structure

Backups are stored in Wasabi with the following structure:

```
n8n-prod/
└── db-backups/
    └── 2024-01-15/
        └── n8n_backup_2024-01-15_02-00-00.sql.gz
```

### Wasabi Lifecycle Rules

To automatically delete old backups from Wasabi (e.g., keep only 90 days):

1. Log into Wasabi Console
2. Navigate to your bucket: `n8n-prod`
3. Go to **Lifecycle Rules**
4. Create a new rule:
   - **Rule Name**: `Delete old backups`
   - **Prefix**: `db-backups/`
   - **Action**: Delete objects
   - **Days**: `90`
   - **Status**: Enabled

## 🔧 Restore Database

### Prerequisites

1. Stop n8n service (prevents data corruption)
2. Have backup file ready (from Wasabi or local)

### Restore Steps

1. **Download backup from Wasabi** (if needed):

```bash
rclone copy wasabi:n8n-prod/db-backups/2024-01-15/n8n_backup_2024-01-15_02-00-00.sql.gz ./backups/
```

2. **Stop n8n**:

```bash
docker compose stop n8n
```

3. **Run restore script**:

```bash
# Make script executable (if not already)
chmod +x scripts/restore.sh

# Run restore (replace with your backup file)
./scripts/restore.sh backups/n8n_backup_2024-01-15_02-00-00.sql.gz
```

4. **Start n8n**:

```bash
docker compose start n8n
```

5. **Verify**:

```bash
# Check logs
docker compose logs -f n8n

# Access n8n in browser and verify workflows
```

## 🛠️ Troubleshooting

### Permission Denied Errors (EACCES)

If you see errors like `EACCES: permission denied, open '/home/node/.n8n/config'`:

1. **Run the permissions fix script**:
   ```bash
   ./scripts/fix-permissions.sh
   ```

2. **Or manually fix permissions**:
   ```bash
   # Stop services first
   docker compose down
   
   # Fix n8n data directory
   sudo chown -R 1000:1000 ./data
   sudo chmod -R 755 ./data
   
   # Fix postgres data directory
   sudo chown -R 999:999 ./postgres
   sudo chmod -R 755 ./postgres
   
   # Restart services
   docker compose up -d
   ```

3. **Verify the fix**:
   ```bash
   # Check n8n logs - should no longer show permission errors
   docker compose logs n8n
   
   # Check service status
   docker compose ps
   ```

**Why this happens:** The n8n container runs as user `node` (UID 1000) and postgres runs as user `postgres` (UID 999). If the host directories are owned by root or another user, the containers cannot write to them.

### n8n Not Accessible

1. **Check DNS propagation**:
   ```bash
   dig your-domain.com
   nslookup your-domain.com
   ```

2. **Check Traefik logs**:
   ```bash
   docker compose logs traefik
   ```

3. **Verify ACME certificate**:
   ```bash
   ls -la traefik/acme.json
   # Should exist and have 600 permissions
   ```

4. **Check firewall**:
   ```bash
   sudo ufw status
   ```

### Database Connection Issues

1. **Check Postgres logs**:
   ```bash
   docker compose logs postgres
   ```

2. **Verify database is running**:
   ```bash
   docker compose ps postgres
   ```

3. **Test connection**:
   ```bash
   docker compose exec postgres psql -U n8n_user -d n8n -c "SELECT 1;"
   ```

### Certificate Issues

1. **Check Let's Encrypt rate limits**: [https://letsencrypt.org/docs/rate-limits/](https://letsencrypt.org/docs/rate-limits/)

2. **View Traefik dashboard** (if enabled):
   - Access via: `https://traefik.your-domain.com` (if configured)

3. **Regenerate certificate**:
   ```bash
   # Stop Traefik
   docker compose stop traefik
   
   # Delete old certificate
   rm traefik/acme.json
   touch traefik/acme.json
   chmod 600 traefik/acme.json
   
   # Restart Traefik
   docker compose start traefik
   ```

### Backup Issues

1. **Check rclone configuration**:
   ```bash
   rclone listremotes
   rclone lsd wasabi:n8n-prod/
   ```

2. **Test backup manually**:
   ```bash
   ./backups/backup.sh
   ```

3. **Check disk space**:
   ```bash
   df -h
   ```

## 🔐 Security Hardening Checklist

- [ ] Changed all default passwords in `.env`
- [ ] Generated strong `N8N_ENCRYPTION_KEY` (32+ characters)
- [ ] Configured firewall (UFW) with only necessary ports
- [ ] Set up DNS A record pointing to droplet IP
- [ ] Enabled HTTPS (automatic via Let's Encrypt)
- [ ] Configured basic auth (optional but recommended)
- [ ] Set up automated backups to Wasabi
- [ ] Configured Wasabi lifecycle rules for old backups
- [ ] Restricted SSH access (key-based authentication recommended)
- [ ] Regularly update system packages: `sudo apt update && sudo apt upgrade`
- [ ] Monitor logs regularly for suspicious activity
- [ ] Keep Docker and Docker Compose updated
- [ ] Review n8n execution data retention settings
- [ ] Enable n8n user management if multiple users will access

## 📁 Project Structure

```
n8n-production-deploy/
├── docker-compose.yml      # Main orchestration file
├── .env.example            # Environment variables template
├── README.md               # This file
├── LICENSE                 # MIT License
├── traefik/
│   ├── acme.json           # Let's Encrypt certificates (created on first run)
│   └── traefik.yml         # Traefik static config (if needed)
├── backups/
│   └── backup.sh           # Automated backup script
├── scripts/
│   └── restore.sh          # Database restore script
├── data/                   # n8n data (created automatically)
└── postgres/               # PostgreSQL data (created automatically)
```

## 📝 Environment Variables Reference

See `.env.example` for all available configuration options with descriptions.

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🆘 Support

For issues and questions:

- **n8n Documentation**: [https://docs.n8n.io](https://docs.n8n.io)
- **Traefik Documentation**: [https://doc.traefik.io/traefik/](https://doc.traefik.io/traefik/)
- **GitHub Issues**: Open an issue in this repository

## 🙏 Acknowledgments

- [n8n](https://n8n.io) - Workflow automation platform
- [Traefik](https://traefik.io) - Reverse proxy and load balancer
- [Watchtower](https://containrrr.dev/watchtower/) - Automatic container updates
- [Wasabi](https://wasabi.com) - Cloud storage

