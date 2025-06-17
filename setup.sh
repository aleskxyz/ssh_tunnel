#!/bin/bash

# Exit on any error
set -e
set -x

# Create temporary installation directory
TEMP_DIR=$(mktemp -d)

echo "Creating temporary installation directory at $TEMP_DIR..."

# Download files from GitHub
echo "Downloading files from GitHub..."
curl -L https://github.com/aleskxyz/ssh_tunnel/archive/refs/heads/main.tar.gz | tar xz -C /tmp

# Copy files to temporary directory
echo "Installing files..."
cp -r /tmp/ssh_tunnel-main/ssh_tunnel/* "$TEMP_DIR/"

# Set proper permissions
echo "Setting permissions..."
chmod +x "$TEMP_DIR"/*.sh

# Clean up temporary download files
rm -rf /tmp/ssh_tunnel-main

# Run the setup script with all arguments passed to this script
echo "Running setup script with arguments: $@"
bash "$TEMP_DIR/setup_ssh_tunnel.sh" "$@"

# Clean up our temporary directory
rm -rf "$TEMP_DIR"

echo "Setup completed successfully!"