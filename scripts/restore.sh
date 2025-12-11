#!/bin/bash

###############################################################################
# n8n PostgreSQL Restore Script
#
# This script restores a n8n PostgreSQL database from a backup file.
#
# IMPORTANT: Stop n8n before running this script to prevent data corruption!
#
# Prerequisites:
# - Backup file (compressed .sql.gz or uncompressed .sql)
# - Docker and docker-compose installed
# - PostgreSQL container running
#
# Usage:
#   ./restore.sh <backup_file>
#
# Example:
#   ./restore.sh ../backups/n8n_backup_2024-01-15_02-00-00.sql.gz
#
# Steps:
# 1. Stop n8n service (prevents data corruption)
# 2. Drop existing database (optional, with confirmation)
# 3. Create fresh database
# 4. Restore from backup
# 5. Start n8n service
###############################################################################

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONTAINER_NAME="n8n-postgres"
DB_NAME="${POSTGRES_DB:-n8n}"
DB_USER="${POSTGRES_USER:-n8n_user}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" >&2
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"
}

# Check if backup file exists
check_backup_file() {
    local backup_file="$1"
    
    if [ ! -f "$backup_file" ]; then
        error "Backup file not found: ${backup_file}"
        exit 1
    fi
    
    log "Backup file found: ${backup_file}"
    
    # Check file size
    local file_size=$(du -h "$backup_file" | cut -f1)
    log "Backup file size: ${file_size}"
}

# Check if container is running
check_container() {
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        error "PostgreSQL container '${CONTAINER_NAME}' is not running!"
        echo "  Start it with: docker compose up -d postgres"
        exit 1
    fi
    log "PostgreSQL container is running"
}

# Check if n8n is stopped
check_n8n_stopped() {
    if docker ps --format '{{.Names}}' | grep -q "^n8n-app$"; then
        warn "n8n container is still running!"
        echo ""
        echo "  It is STRONGLY recommended to stop n8n before restoring:"
        echo "    docker compose stop n8n"
        echo ""
        read -p "  Continue anyway? (yes/no): " -r
        if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            log "Restore cancelled by user"
            exit 0
        fi
    else
        log "n8n container is stopped (good)"
    fi
}

# Decompress backup if needed
prepare_backup() {
    local backup_file="$1"
    local temp_file="${backup_file}.restore"
    
    # Check if file is compressed
    if [[ "$backup_file" == *.gz ]]; then
        log "Decompressing backup file..."
        if gunzip -c "$backup_file" > "$temp_file"; then
            log "Backup decompressed: ${temp_file}"
            echo "$temp_file"
        else
            error "Failed to decompress backup file"
            rm -f "$temp_file"
            exit 1
        fi
    else
        # Not compressed, use as-is
        echo "$backup_file"
    fi
}

# Drop and recreate database
recreate_database() {
    log "Recreating database..."
    
    # Drop existing database (ignore errors if it doesn't exist)
    docker exec "${CONTAINER_NAME}" psql -U "${DB_USER}" -d postgres -c "DROP DATABASE IF EXISTS ${DB_NAME};" 2>/dev/null || true
    
    # Create fresh database
    if docker exec "${CONTAINER_NAME}" psql -U "${DB_USER}" -d postgres -c "CREATE DATABASE ${DB_NAME};" 2>/dev/null; then
        log "Database recreated successfully"
    else
        error "Failed to recreate database"
        exit 1
    fi
}

# Restore database
restore_database() {
    local sql_file="$1"
    
    log "Restoring database from backup..."
    log "This may take several minutes depending on database size..."
    
    if docker exec -i "${CONTAINER_NAME}" psql -U "${DB_USER}" -d "${DB_NAME}" < "$sql_file" 2>/dev/null; then
        log "Database restored successfully"
    else
        error "Failed to restore database"
        exit 1
    fi
}

# Cleanup temporary files
cleanup() {
    local temp_file="$1"
    if [ -f "$temp_file" ] && [[ "$temp_file" == *.restore ]]; then
        log "Cleaning up temporary files..."
        rm -f "$temp_file"
    fi
}

# Main execution
main() {
    # Check arguments
    if [ $# -eq 0 ]; then
        error "No backup file specified"
        echo ""
        echo "Usage: $0 <backup_file>"
        echo ""
        echo "Example:"
        echo "  $0 ../backups/n8n_backup_2024-01-15_02-00-00.sql.gz"
        exit 1
    fi
    
    local backup_file="$1"
    
    # Resolve absolute path if relative
    if [[ ! "$backup_file" = /* ]]; then
        backup_file="${SCRIPT_DIR}/${backup_file}"
    fi
    
    log "Starting n8n database restore..."
    log "Backup file: ${backup_file}"
    
    # Change to project directory
    cd "${PROJECT_DIR}" || {
        error "Failed to change to project directory: ${PROJECT_DIR}"
        exit 1
    }
    
    # Pre-flight checks
    check_backup_file "$backup_file"
    check_container
    check_n8n_stopped
    
    # Confirm restore
    echo ""
    warn "This will DROP the existing database and restore from backup!"
    read -p "Are you sure you want to continue? (yes/no): " -r
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log "Restore cancelled by user"
        exit 0
    fi
    
    # Prepare backup (decompress if needed)
    local sql_file=$(prepare_backup "$backup_file")
    
    # Restore database
    recreate_database
    restore_database "$sql_file"
    
    # Cleanup
    cleanup "$sql_file"
    
    log "Database restore completed successfully!"
    echo ""
    log "Next steps:"
    echo "  1. Start n8n: docker compose start n8n"
    echo "  2. Check logs: docker compose logs -f n8n"
    echo "  3. Verify workflows in n8n web interface"
}

# Trap to cleanup on exit
trap 'cleanup "${sql_file:-}"' EXIT

# Run main function
main "$@"

