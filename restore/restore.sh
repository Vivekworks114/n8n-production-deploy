#!/bin/bash

###############################################################################
# n8n PostgreSQL Restore Script
#
# This script restores a n8n PostgreSQL database from a backup file.
# It supports automatic backup selection based on date or latest available.
#
# Usage:
#   ./restore.sh [YYYY-MM-DD]
#
# Examples:
#   ./restore.sh                    # Restore from latest backup
#   ./restore.sh 2025-12-21         # Restore from latest backup on 2025-12-21
#
# Backup format:
#   n8n_backup_YYYY-MM-DD_HH-MM-SS.sql.gz
#   n8n_backup_YYYY-MM-DD_HH-MM-SS.sql
###############################################################################

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESTORE_DIR="${SCRIPT_DIR}"
POSTGRES_CONTAINER="n8n-postgres"
N8N_CONTAINER="n8n"
DB_NAME="n8n"
DB_USER="n8n_user"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO:${NC} $1"
}

###############################################################################
# Find the latest backup file
#
# Arguments:
#   $1 - Optional date in YYYY-MM-DD format
#
# Returns:
#   Path to the backup file (or empty if not found)
###############################################################################
find_backup_file() {
    local target_date="$1"
    local backup_file=""
    
    if [ -n "$target_date" ]; then
        # Find latest backup for specific date
        info "Looking for backups on date: ${target_date}"
        
        # Pattern: n8n_backup_YYYY-MM-DD_*.sql or n8n_backup_YYYY-MM-DD_*.sql.gz
        local pattern="n8n_backup_${target_date}_*.sql*"
        
        # Find all matching files and sort by modification time (newest first)
        backup_file=$(find "${RESTORE_DIR}" -maxdepth 1 -type f -name "${pattern}" -print0 2>/dev/null | \
            xargs -0 ls -t 2>/dev/null | head -n1)
    else
        # Find latest backup overall
        info "Looking for latest backup in ${RESTORE_DIR}"
        
        # Find all backup files matching the pattern and sort by modification time
        backup_file=$(find "${RESTORE_DIR}" -maxdepth 1 -type f \( -name "n8n_backup_*.sql" -o -name "n8n_backup_*.sql.gz" \) -print0 2>/dev/null | \
            xargs -0 ls -t 2>/dev/null | head -n1)
    fi
    
    if [ -z "$backup_file" ] || [ ! -f "$backup_file" ]; then
        return 1
    fi
    
    echo "$backup_file"
}

###############################################################################
# Check if PostgreSQL container is running
###############################################################################
check_postgres_container() {
    if ! docker ps --format '{{.Names}}' | grep -q "^${POSTGRES_CONTAINER}$"; then
        error "PostgreSQL container '${POSTGRES_CONTAINER}' is not running!"
        exit 1
    fi
    log "PostgreSQL container is running"
}

###############################################################################
# Stop the n8n container
###############################################################################
stop_n8n_container() {
    if docker ps --format '{{.Names}}' | grep -q "^${N8N_CONTAINER}$"; then
        log "Stopping n8n container..."
        docker stop "${N8N_CONTAINER}" || {
            error "Failed to stop n8n container"
            exit 1
        }
        log "n8n container stopped"
    else
        log "n8n container is already stopped"
    fi
}

###############################################################################
# Prepare backup file (extract if compressed)
#
# Arguments:
#   $1 - Backup file path
#
# Returns:
#   Path to SQL file (extracted if needed)
###############################################################################
prepare_backup_file() {
    local backup_file="$1"
    local sql_file=""
    
    if [[ "$backup_file" == *.gz ]]; then
        log "Backup file is compressed (.sql.gz), extracting..."
        sql_file="${backup_file%.gz}"
        
        if gunzip -c "$backup_file" > "$sql_file"; then
            log "Backup extracted to: ${sql_file}"
            echo "$sql_file"
        else
            error "Failed to extract backup file"
            rm -f "$sql_file"
            exit 1
        fi
    else
        log "Backup file is already uncompressed (.sql)"
        echo "$backup_file"
    fi
}

###############################################################################
# Drop and recreate the database
###############################################################################
recreate_database() {
    log "Dropping database ${DB_NAME} if it exists..."
    docker exec "${POSTGRES_CONTAINER}" psql -U "${DB_USER}" -d postgres -c "DROP DATABASE IF EXISTS ${DB_NAME};" >/dev/null 2>&1 || true
    
    log "Creating fresh database ${DB_NAME}..."
    if ! docker exec "${POSTGRES_CONTAINER}" psql -U "${DB_USER}" -d postgres -c "CREATE DATABASE ${DB_NAME};" >/dev/null 2>&1; then
        error "Failed to create database ${DB_NAME}"
        exit 1
    fi
    
    log "Database ${DB_NAME} recreated successfully"
}

###############################################################################
# Restore database from SQL file
#
# Arguments:
#   $1 - Path to SQL file
###############################################################################
restore_database() {
    local sql_file="$1"
    
    log "Restoring database from backup..."
    log "This may take several minutes depending on database size..."
    
    if docker exec -i "${POSTGRES_CONTAINER}" psql -U "${DB_USER}" -d "${DB_NAME}" < "$sql_file" >/dev/null 2>&1; then
        log "Database restored successfully"
    else
        error "Failed to restore database"
        exit 1
    fi
}

###############################################################################
# Start the n8n container
###############################################################################
start_n8n_container() {
    log "Starting n8n container..."
    if docker start "${N8N_CONTAINER}" >/dev/null 2>&1; then
        log "n8n container started"
    else
        warn "Failed to start n8n container (it may not exist or already be running)"
        info "You may need to start it manually: docker start ${N8N_CONTAINER}"
    fi
}

###############################################################################
# Cleanup temporary extracted files
#
# Arguments:
#   $1 - SQL file path (to check if it was extracted)
#   $2 - Original backup file path
###############################################################################
cleanup() {
    local sql_file="$1"
    local backup_file="$2"
    
    # Only remove if it was extracted (not the original backup)
    if [ -f "$sql_file" ] && [ "$sql_file" != "$backup_file" ] && [[ "$backup_file" == *.gz ]]; then
        log "Cleaning up extracted temporary file..."
        rm -f "$sql_file"
    fi
}

###############################################################################
# Main execution
###############################################################################
main() {
    local target_date="${1:-}"
    local backup_file=""
    local sql_file=""
    
    log "Starting n8n database restore process..."
    
    # Find backup file
    if ! backup_file=$(find_backup_file "$target_date"); then
        error "No backup file found"
        if [ -n "$target_date" ]; then
            error "No backup found for date: ${target_date}"
        else
            error "No backup files found in ${RESTORE_DIR}"
        fi
        error "Expected format: n8n_backup_YYYY-MM-DD_HH-MM-SS.sql[.gz]"
        exit 1
    fi
    
    log "Selected backup file: $(basename "${backup_file}")"
    info "Full path: ${backup_file}"
    
    # Safety confirmation
    echo ""
    warn "⚠️  DESTRUCTIVE ACTION WARNING ⚠️"
    echo ""
    echo "This will DROP and RECREATE the database ${DB_NAME}."
    echo "All current data in ${DB_NAME} will be permanently lost!"
    echo ""
    echo "Backup file: $(basename "${backup_file}")"
    echo ""
    read -p "Type YES to continue: " -r
    if [[ ! "$REPLY" == "YES" ]]; then
        log "Restore cancelled by user"
        exit 0
    fi
    
    # Pre-flight checks
    check_postgres_container
    
    # Restore procedure (strict order)
    stop_n8n_container
    
    # Prepare backup (extract if needed)
    sql_file=$(prepare_backup_file "$backup_file")
    
    # Drop and recreate database
    recreate_database
    
    # Restore database
    restore_database "$sql_file"
    
    # Start n8n container
    start_n8n_container
    
    # Cleanup
    cleanup "$sql_file" "$backup_file"
    
    echo ""
    log "✅ Restore completed successfully"
    echo ""
    info "Database ${DB_NAME} has been restored from: $(basename "${backup_file}")"
    info "n8n container has been started"
}

# Trap to cleanup on exit
trap 'if [ -n "${sql_file:-}" ] && [ -n "${backup_file:-}" ]; then cleanup "${sql_file}" "${backup_file}"; fi' EXIT

# Run main function
main "$@"

