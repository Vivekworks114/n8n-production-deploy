#!/bin/bash

# Fix permissions for n8n data directory
# n8n runs as user 'node' (UID 1000) inside the container

set -e

echo "Fixing permissions for n8n data directory..."

# Get the directory where the script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Fix n8n data directory permissions
if [ -d "$PROJECT_DIR/data" ]; then
    echo "Setting ownership of ./data to UID 1000 (node user)..."
    sudo chown -R 1000:1000 "$PROJECT_DIR/data"
    sudo chmod -R 755 "$PROJECT_DIR/data"
    echo "✓ Fixed ./data permissions"
else
    echo "Creating ./data directory with correct permissions..."
    sudo mkdir -p "$PROJECT_DIR/data"
    sudo chown -R 1000:1000 "$PROJECT_DIR/data"
    sudo chmod -R 755 "$PROJECT_DIR/data"
    echo "✓ Created ./data directory with correct permissions"
fi

# Fix postgres data directory permissions (postgres runs as UID 999)
if [ -d "$PROJECT_DIR/postgres" ]; then
    echo "Setting ownership of ./postgres to UID 999 (postgres user)..."
    sudo chown -R 999:999 "$PROJECT_DIR/postgres"
    sudo chmod -R 755 "$PROJECT_DIR/postgres"
    echo "✓ Fixed ./postgres permissions"
fi

# Fix diun data directory permissions
if [ -d "$PROJECT_DIR/diun/data" ]; then
    echo "Setting ownership of ./diun/data..."
    sudo chown -R 1000:1000 "$PROJECT_DIR/diun/data"
    sudo chmod -R 755 "$PROJECT_DIR/diun/data"
    echo "✓ Fixed ./diun/data permissions"
fi

echo ""
echo "Permissions fixed! You can now restart the services:"
echo "  docker compose down"
echo "  docker compose up -d"
