#!/bin/bash
set -e
set -u

# Configuration from environment variables
PUBLIC_KEY="${PUBLIC_KEY}"
SSHD_CONFIG_DIR="${SSHD_CONFIG_DIR}"
SSH_CONFIG="${SSH_CONFIG}"
TARGET_IP="${TARGET_IP}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

# Function to print status messages
print_status() {
    local status="$1"
    local message="$2"
    case "$status" in
        "info")    echo -e "${BLUE}ℹ ${message}${NC}" ;;
        "success") echo -e "${GREEN}✓ ${message}${NC}" ;;
        "warning") echo -e "${YELLOW}⚠ ${message}${NC}" ;;
        "error")   echo -e "${RED}✗ ${message}${NC}" ;;
    esac
}

NEEDS_RESTART=false

# Check if sudo access is available
if ! sudo -n true > /dev/null 2>&1; then
    print_status "error" "Passwordless sudo access required on remote host."
    exit 1
fi

# Check and install required packages
install_package() {
    local package="$1"
    if ! command -v "$package" >/dev/null 2>&1; then
        print_status "info" "Installing $package package"
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update
            sudo apt-get install -y "$package"
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y "$package"
        elif command -v dnf >/dev/null 2>&1; then
            sudo dnf install -y "$package"
        else
            print_status "error" "Could not install $package: package manager not found"
            exit 1
        fi
        print_status "success" "$package installed successfully"
    fi
}

# Install required packages
install_package "socat"
install_package "lsof"

# Create config directory if it doesn't exist
sudo mkdir -p "$SSHD_CONFIG_DIR"


# Add Include directive if it doesn't exist
if ! sudo grep -q "^Include.*sshd_config.d/\*.conf" "/etc/ssh/sshd_config"; then
    print_status "info" "Adding Include directive to main SSH config"
    echo -e "\n# Include additional configuration files\nInclude $SSHD_CONFIG_DIR/*.conf" | sudo tee -a "/etc/ssh/sshd_config" > /dev/null
    NEEDS_RESTART=true
fi

# Define the expected configuration
expected_config="PermitTunnel yes
PermitRootLogin yes"

# Check if configuration file exists and has correct content
if [ -f "$SSH_CONFIG" ]; then
    current_config=$(sudo cat "$SSH_CONFIG")
    if [ "$current_config" != "$expected_config" ]; then
        print_status "info" "Creating SSH configuration"
        echo "$expected_config" | sudo tee "$SSH_CONFIG" > /dev/null
        sudo chmod 644 "$SSH_CONFIG"
        NEEDS_RESTART=true
    fi
else
    print_status "info" "Creating SSH configuration"
    echo "$expected_config" | sudo tee "$SSH_CONFIG" > /dev/null
    sudo chmod 644 "$SSH_CONFIG"
    NEEDS_RESTART=true
fi

# Configure authorized_keys
print_status "info" "Configuring authorized_keys"
sudo mkdir -p /root/.ssh
sudo chmod 700 /root/.ssh

# Check if key is already in authorized_keys
if ! sudo grep -q "$PUBLIC_KEY" /root/.ssh/authorized_keys 2>/dev/null; then
    echo "$PUBLIC_KEY" | sudo tee -a /root/.ssh/authorized_keys > /dev/null
    sudo chmod 600 /root/.ssh/authorized_keys
    sudo chown root:root /root/.ssh/authorized_keys
    print_status "success" "Public key added to authorized_keys"
else
    print_status "info" "Public key already exists in authorized_keys"
fi

# Restart SSH service only if needed
if [ "$NEEDS_RESTART" = true ]; then
    print_status "info" "Restarting SSH service due to configuration changes"
    sudo systemctl restart sshd
else
    print_status "info" "No configuration changes needed, skipping SSH service restart"
fi

# Configure TCP and UDP forwarding services
print_status "info" "Configuring TCP and UDP forwarding services"

# TCP Forwarding Service
TCP_SERVICE="/etc/systemd/system/ssh-tunnel-tcp-forwarder@.service"
TCP_SERVICE_CONTENT="[Unit]
Description=TCP Port Forwarding Service for port %I
After=network.target
Wants=network-online.target

[Service]
Type=simple

ExecStart=/usr/bin/socat TCP-LISTEN:%i,reuseaddr,fork TCP:${TARGET_IP}:%i

# Restart configuration
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target"

if [ ! -f "$TCP_SERVICE" ] || ! diff -q "$TCP_SERVICE" <(echo "$TCP_SERVICE_CONTENT") > /dev/null 2>&1; then
    print_status "info" "Creating TCP forwarding service"
    echo "$TCP_SERVICE_CONTENT" | sudo tee "$TCP_SERVICE" > /dev/null
    sudo systemctl daemon-reload
    print_status "info" "Restarting running instances of TCP forwarding service"
    for service in $(systemctl list-units --no-legend --no-pager 'ssh-tunnel-tcp-forwarder@*.service' | awk '{print $1}'); do
        sudo systemctl restart "$service"
    done
fi

# UDP Forwarding Service
UDP_SERVICE="/etc/systemd/system/ssh-tunnel-udp-forwarder@.service"
UDP_SERVICE_CONTENT="[Unit]
Description=UDP Port Forwarding Service for port %I
After=network.target
Wants=network-online.target

[Service]
Type=simple

ExecStart=/usr/bin/socat UDP4-RECVFROM:%i,reuseaddr,fork UDP4-SENDTO:${TARGET_IP}:%i

# Restart configuration
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target"

if [ ! -f "$UDP_SERVICE" ] || ! diff -q "$UDP_SERVICE" <(echo "$UDP_SERVICE_CONTENT") > /dev/null 2>&1; then
    print_status "info" "Creating UDP forwarding service"
    echo "$UDP_SERVICE_CONTENT" | sudo tee "$UDP_SERVICE" > /dev/null
    sudo systemctl daemon-reload
    print_status "info" "Restarting running instances of UDP forwarding service"
    for service in $(systemctl list-units --no-legend --no-pager 'ssh-tunnel-udp-forwarder@*.service' | awk '{print $1}'); do
        sudo systemctl restart "$service"
    done
fi

print_status "success" "Remote server configuration completed successfully"
