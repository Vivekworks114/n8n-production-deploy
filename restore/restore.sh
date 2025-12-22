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
N8N_CONTAINER="n8n-app"
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
        info "Looking for backups on date: ${target_date}" >&2
        
        # Pattern: n8n_backup_YYYY-MM-DD_*.sql or n8n_backup_YYYY-MM-DD_*.sql.gz
        local pattern="n8n_backup_${target_date}_*.sql*"
        
        # Find all matching files and sort by modification time (newest first)
        backup_file=$(find "${RESTORE_DIR}" -maxdepth 1 -type f -name "${pattern}" -print0 2>/dev/null | \
            xargs -0 ls -t 2>/dev/null | head -n1)
    else
        # Find latest backup overall
        info "Looking for latest backup in ${RESTORE_DIR}" >&2
        
        # Find all backup files matching the pattern and sort by modification time
        backup_file=$(find "${RESTORE_DIR}" -maxdepth 1 -type f \( -name "n8n_backup_*.sql" -o -name "n8n_backup_*.sql.gz" \) -print0 2>/dev/null | \
            xargs -0 ls -t 2>/dev/null | head -n1)
    fi
    
    if [ -z "$backup_file" ] || [ ! -f "$backup_file" ]; then
        return 1
    fi
    
    # Return absolute path
    if [[ ! "$backup_file" = /* ]]; then
        backup_file="$(cd "$(dirname "$backup_file")" && pwd)/$(basename "$backup_file")"
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
# Verify database state (for debugging)
###############################################################################
verify_database_state() {
    log "Verifying database state..."
    
    # Check if database exists
    local db_exists=$(docker exec "${POSTGRES_CONTAINER}" psql -U "${DB_USER}" -d postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}';" 2>&1)
    
    if [ "$db_exists" = "1" ]; then
        info "Database ${DB_NAME} exists"
        
        # Check active connections
        local connections=$(docker exec "${POSTGRES_CONTAINER}" psql -U "${DB_USER}" -d postgres -tAc \
            "SELECT COUNT(*) FROM pg_stat_activity WHERE datname = '${DB_NAME}';" 2>&1)
        info "Active connections to ${DB_NAME}: ${connections}"
        
        # Show connection details
        if [ "$connections" != "0" ]; then
            warn "Active connections found:"
            docker exec "${POSTGRES_CONTAINER}" psql -U "${DB_USER}" -d postgres -c \
                "SELECT pid, usename, application_name, state, query FROM pg_stat_activity WHERE datname = '${DB_NAME}';" 2>&1 | sed 's/^/  /'
        fi
        
        # Check database size
        local db_size=$(docker exec "${POSTGRES_CONTAINER}" psql -U "${DB_USER}" -d postgres -tAc \
            "SELECT pg_size_pretty(pg_database_size('${DB_NAME}'));" 2>&1)
        info "Database size: ${db_size}"
    else
        info "Database ${DB_NAME} does not exist"
    fi
}

###############################################################################
# Stop the n8n container
###############################################################################
stop_n8n_container() {
    if docker ps --format '{{.Names}}' | grep -q "^${N8N_CONTAINER}$"; then
        log "Stopping n8n container (${N8N_CONTAINER})..."
        if ! docker stop "${N8N_CONTAINER}" >/dev/null 2>&1; then
            error "Failed to stop n8n container ${N8N_CONTAINER}"
            exit 1
        fi
        
        # Wait for container to fully stop
        log "Waiting for container to fully stop..."
        local wait_count=0
        while docker ps --format '{{.Names}}' | grep -q "^${N8N_CONTAINER}$" && [ $wait_count -lt 10 ]; do
            sleep 1
            wait_count=$((wait_count + 1))
        done
        
        if docker ps --format '{{.Names}}' | grep -q "^${N8N_CONTAINER}$"; then
            warn "Container ${N8N_CONTAINER} is still running after stop attempt"
        else
            log "n8n container stopped successfully"
        fi
        
        # Wait a bit more for database connections to close
        sleep 2
    else
        log "n8n container (${N8N_CONTAINER}) is already stopped"
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
    
    # Resolve absolute path if relative
    if [[ ! "$backup_file" = /* ]]; then
        backup_file="${RESTORE_DIR}/${backup_file}"
    fi
    
    if [[ "$backup_file" == *.gz ]]; then
        log "Backup file is compressed (.sql.gz), extracting..." >&2
        sql_file="${backup_file%.gz}"
        
        if gunzip -c "$backup_file" > "$sql_file"; then
            log "Backup extracted to: ${sql_file}" >&2
            echo "$sql_file"
        else
            error "Failed to extract backup file"
            rm -f "$sql_file"
            exit 1
        fi
    else
        log "Backup file is already uncompressed (.sql)" >&2
        echo "$backup_file"
    fi
}

###############################################################################
# Terminate active connections to a database
#
# Arguments:
#   $1 - Database name
###############################################################################
terminate_connections() {
    local db_name="$1"
    local max_attempts=5
    local attempt=1
    
    log "Terminating active connections to database ${db_name}..."
    
    while [ $attempt -le $max_attempts ]; do
        # Get list of PIDs to terminate (excluding our own connection)
        local pids=$(docker exec "${POSTGRES_CONTAINER}" psql -U "${DB_USER}" -d postgres -tAc \
            "SELECT pid FROM pg_stat_activity WHERE datname = '${db_name}' AND pid <> pg_backend_pid();" 2>&1)
        
        # Remove empty lines and whitespace
        pids=$(echo "$pids" | grep -v '^$' | tr -d ' ' | grep -v '^$')
        
        if [ -z "$pids" ]; then
            log "No active connections found"
            return 0
        fi
        
        info "Attempt $attempt/$max_attempts: Terminating $(echo "$pids" | wc -l | tr -d ' ') connection(s)..."
        
        # Terminate each connection
        for pid in $pids; do
            if [ -n "$pid" ] && [ "$pid" != "" ]; then
                docker exec "${POSTGRES_CONTAINER}" psql -U "${DB_USER}" -d postgres -c \
                    "SELECT pg_terminate_backend($pid);" >/dev/null 2>&1 || true
            fi
        done
        
        # Wait for connections to close
        sleep 2
        
        # Verify connections are gone
        local remaining=$(docker exec "${POSTGRES_CONTAINER}" psql -U "${DB_USER}" -d postgres -tAc \
            "SELECT COUNT(*) FROM pg_stat_activity WHERE datname = '${db_name}' AND pid <> pg_backend_pid();" 2>&1)
        remaining=$(echo "$remaining" | tr -d ' ')
        
        if [ "$remaining" = "0" ] || [ -z "$remaining" ]; then
            log "All connections terminated successfully"
            return 0
        fi
        
        attempt=$((attempt + 1))
    done
    
    # If we get here, we couldn't terminate all connections
    warn "Could not terminate all connections after $max_attempts attempts"
    warn "Remaining connections:"
    docker exec "${POSTGRES_CONTAINER}" psql -U "${DB_USER}" -d postgres -c \
        "SELECT pid, usename, application_name, state, query FROM pg_stat_activity WHERE datname = '${db_name}' AND pid <> pg_backend_pid();" 2>&1 | sed 's/^/  /'
    
    return 1
}

###############################################################################
# Drop and recreate the database
###############################################################################
recreate_database() {
    # Check if database exists
    local db_exists=$(docker exec "${POSTGRES_CONTAINER}" psql -U "${DB_USER}" -d postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}';" 2>&1)
    
    if [ "$db_exists" = "1" ]; then
        log "Database ${DB_NAME} exists, terminating active connections..."
        if ! terminate_connections "${DB_NAME}"; then
            warn "Some connections may still be active, attempting force drop..."
        fi
        
        log "Dropping database ${DB_NAME}..."
        local drop_output
        drop_output=$(docker exec "${POSTGRES_CONTAINER}" psql -U "${DB_USER}" -d postgres -c "DROP DATABASE ${DB_NAME};" 2>&1)
        local drop_exit=$?
        
        if [ $drop_exit -ne 0 ]; then
            # Try with FORCE option (PostgreSQL 13+)
            warn "Standard DROP failed, trying DROP DATABASE ... WITH (FORCE)..."
            drop_output=$(docker exec "${POSTGRES_CONTAINER}" psql -U "${DB_USER}" -d postgres -c "DROP DATABASE ${DB_NAME} WITH (FORCE);" 2>&1)
            drop_exit=$?
        fi
        
        if [ $drop_exit -ne 0 ]; then
            error "Failed to drop database ${DB_NAME}"
            error "PostgreSQL error output:"
            echo "$drop_output" | sed 's/^/  /' >&2
            error ""
            error "This usually means there are still active connections."
            error "You can manually terminate connections with:"
            error "  docker exec ${POSTGRES_CONTAINER} psql -U ${DB_USER} -d postgres -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${DB_NAME}' AND pid <> pg_backend_pid();\""
            exit 1
        fi
        log "Database ${DB_NAME} dropped successfully"
    else
        log "Database ${DB_NAME} does not exist (will be created)"
    fi
    
    log "Creating fresh database ${DB_NAME}..."
    local create_output
    create_output=$(docker exec "${POSTGRES_CONTAINER}" psql -U "${DB_USER}" -d postgres -c "CREATE DATABASE ${DB_NAME};" 2>&1)
    local create_exit=$?
    
    if [ $create_exit -ne 0 ]; then
        error "Failed to create database ${DB_NAME}"
        error "PostgreSQL error output:"
        echo "$create_output" | sed 's/^/  /' >&2
        exit 1
    fi
    
    log "Database ${DB_NAME} created successfully"
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
    
    local restore_output
    restore_output=$(docker exec -i "${POSTGRES_CONTAINER}" psql -U "${DB_USER}" -d "${DB_NAME}" < "$sql_file" 2>&1)
    local restore_exit=$?
    
    if [ $restore_exit -ne 0 ]; then
        error "Failed to restore database"
        error "PostgreSQL error output:"
        echo "$restore_output" | sed 's/^/  /' >&2
        exit 1
    fi
    
    log "Database restored successfully"
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
    
    # Verify current database state (for debugging)
    verify_database_state
    
    # Restore procedure (strict order)
    stop_n8n_container
    
    # Prepare backup (extract if needed)
    sql_file=$(prepare_backup_file "$backup_file")
    
    # Verify SQL file exists and is readable
    if [ ! -f "$sql_file" ]; then
        error "SQL file not found: ${sql_file}"
        error "Backup file was: ${backup_file}"
        exit 1
    fi
    
    log "Using SQL file: ${sql_file}"
    
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

