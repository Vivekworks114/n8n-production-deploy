#!/bin/bash

###############################################################################
# n8n PostgreSQL Backup Script
# 
# This script creates a compressed backup of the n8n PostgreSQL database and
# uploads it to Wasabi cloud storage via rclone.
#
# Features:
# - Creates timestamped PostgreSQL dump
# - Compresses backup with gzip
# - Uploads to Wasabi: n8n-prod/db-backups/YYYY-MM-DD/
# - Cleans local backups older than 14 days
# - Safe and idempotent (can be run multiple times)
#
# Prerequisites:
# - rclone installed and configured with Wasabi remote named "wasabi"
# - Docker and docker-compose installed
# - Sufficient disk space for temporary backup storage
#
# Usage:
#   ./backup.sh
#
# Cron example (daily at 2 AM):
#   0 2 * * * /path/to/backups/backup.sh >> /var/log/n8n-backup.log 2>&1
###############################################################################

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="${SCRIPT_DIR}"
CONTAINER_NAME="n8n-postgres"
DB_NAME="${POSTGRES_DB:-n8n}"
DB_USER="${POSTGRES_USER:-n8n_user}"
RCLONE_REMOTE="wasabi"
RCLONE_BUCKET="n8n-prod"
RCLONE_PATH="db-backups"
RETENTION_DAYS=14

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" >&2
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"
}

# Check if Docker container is running
check_container() {
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        error "PostgreSQL container '${CONTAINER_NAME}' is not running!"
        exit 1
    fi
    log "PostgreSQL container is running"
}

# Check if rclone is installed and configured
check_rclone() {
    if ! command -v rclone &> /dev/null; then
        error "rclone is not installed. Please install it first:"
        echo "  curl https://rclone.org/install.sh | sudo bash"
        exit 1
    fi
    
    if ! rclone listremotes | grep -q "^${RCLONE_REMOTE}:$"; then
        error "rclone remote '${RCLONE_REMOTE}' is not configured."
        echo "  Run: rclone config"
        exit 1
    fi
    
    log "rclone is configured correctly"
}

# Create backup
create_backup() {
    local timestamp=$(date +'%Y-%m-%d_%H-%M-%S')
    local date_dir=$(date +'%Y-%m-%d')
    local backup_file="n8n_backup_${timestamp}.sql"
    local backup_file_gz="${backup_file}.gz"
    local backup_path="${BACKUP_DIR}/${backup_file_gz}"
    
    log "Creating database backup..."
    
    # Create PostgreSQL dump
    if docker exec "${CONTAINER_NAME}" pg_dump -U "${DB_USER}" -d "${DB_NAME}" > "${BACKUP_DIR}/${backup_file}" 2>/dev/null; then
        log "Database dump created: ${backup_file}"
    else
        error "Failed to create database dump"
        rm -f "${BACKUP_DIR}/${backup_file}"
        exit 1
    fi
    
    # Compress backup
    log "Compressing backup..."
    if gzip -f "${BACKUP_DIR}/${backup_file}"; then
        log "Backup compressed: ${backup_file_gz}"
    else
        error "Failed to compress backup"
        rm -f "${BACKUP_DIR}/${backup_file}"
        exit 1
    fi
    
    # Get backup size
    local backup_size=$(du -h "${backup_path}" | cut -f1)
    log "Backup size: ${backup_size}"
    
    # Upload to Wasabi
    log "Uploading backup to Wasabi..."
    if rclone copy "${backup_path}" "${RCLONE_REMOTE}:${RCLONE_BUCKET}/${RCLONE_PATH}/${date_dir}/" --progress; then
        log "Backup uploaded successfully to: ${RCLONE_REMOTE}:${RCLONE_BUCKET}/${RCLONE_PATH}/${date_dir}/"
    else
        error "Failed to upload backup to Wasabi"
        warn "Backup file kept locally: ${backup_path}"
        exit 1
    fi
    
    # Verify upload
    log "Verifying upload..."
    if rclone ls "${RCLONE_REMOTE}:${RCLONE_BUCKET}/${RCLONE_PATH}/${date_dir}/${backup_file_gz}" &> /dev/null; then
        log "Upload verified successfully"
    else
        warn "Could not verify upload, but no error was reported"
    fi
    
    echo "${backup_path}"
}

# Clean old local backups
clean_old_backups() {
    log "Cleaning local backups older than ${RETENTION_DAYS} days..."
    
    local deleted_count=0
    while IFS= read -r -d '' file; do
        if rm -f "$file"; then
            ((deleted_count++))
        fi
    done < <(find "${BACKUP_DIR}" -name "n8n_backup_*.sql.gz" -type f -mtime +${RETENTION_DAYS} -print0 2>/dev/null)
    
    if [ ${deleted_count} -gt 0 ]; then
        log "Deleted ${deleted_count} old backup file(s)"
    else
        log "No old backups to clean"
    fi
}

# Main execution
main() {
    log "Starting n8n backup process..."
    
    # Change to project directory
    cd "${PROJECT_DIR}" || {
        error "Failed to change to project directory: ${PROJECT_DIR}"
        exit 1
    }
    
    # Pre-flight checks
    check_container
    check_rclone
    
    # Create backup
    backup_path=$(create_backup)
    
    # Clean old backups
    clean_old_backups
    
    log "Backup process completed successfully!"
    log "Backup location: ${backup_path}"
    log "Wasabi location: ${RCLONE_REMOTE}:${RCLONE_BUCKET}/${RCLONE_PATH}/$(date +'%Y-%m-%d')/"
}

# Run main function
main "$@"

