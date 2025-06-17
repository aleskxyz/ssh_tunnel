#!/bin/bash
set -e
set -u
set -x

# Colors and formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'
DIM='\033[2m'

# Constants
KEY_PATH="/etc/ssh/ssh_tunnel"
SSHD_CONFIG_DIR="/etc/ssh/sshd_config.d"
SSH_CONFIG="${SSHD_CONFIG_DIR}/zzz_ssh_tunnel.conf"
SERVICE_NAME="ssh-tunnel"
HEALTHCHECK_NAME="${SERVICE_NAME}-healthcheck"
HEALTHCHECK_TIMER_NAME="${HEALTHCHECK_NAME}.timer"
SYSTEMD_DIR="/etc/systemd/system"
SERVICE_UNIT_FILE="${SYSTEMD_DIR}/${SERVICE_NAME}@.service"
HEALTHCHECK_UNIT_FILE="${SYSTEMD_DIR}/${HEALTHCHECK_NAME}@.service"
HEALTHCHECK_TIMER_UNIT_FILE="${SYSTEMD_DIR}/${HEALTHCHECK_NAME}@.timer"
LOCAL_TUN_IP="10.1.1.1"
REMOTE_TUN_IP="10.1.1.2"
NETMASK="/30"

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

# Function to print section headers
print_section() {
    echo -e "\n${BOLD}${BLUE}==>${NC} ${BOLD}$1${NC}"
}

# Function to show help
show_help() {
    cat << EOF
SSH Tunnel Setup Script

Usage: setup.sh USER@HOST[:PORT] -s SERVICE_PORT[/PROTOCOL] [-i SSH_KEY]

Arguments:
  USER@HOST[:PORT]            Connection string (e.g., root@192.168.1.100:22)
  -s SERVICE_PORT[/PROTOCOL]  Port of the service to forward (e.g., 443/tcp)
  -i SSH_KEY                  Path to SSH key for authentication (optional)
  -h, --help                  Show this help message

Example:
  setup.sh root@192.168.1.100:22 -s 443/tcp -i ~/.ssh/id_rsa
EOF
    exit 0
}

# Function to handle errors
handle_error() {
    print_status "error" "$1"
    exit 1
}

# Function to check sudo access
check_sudo_access() {
    print_section "Checking sudo access"
    if ! sudo -v; then
        handle_error "Sudo access required. Please ensure you have sudo privileges."
    fi
    print_status "success" "Sudo access verified"
}

# Function to check and install required packages
check_required_packages() {
    print_section "Checking required packages"
    
    local packages=("lsof")
    local missing_packages=()
    
    # Check which packages are missing
    for package in "${packages[@]}"; do
        if ! command -v "$package" >/dev/null 2>&1; then
            missing_packages+=("$package")
        fi
    done
    
    # Install missing packages if any
    if [ ${#missing_packages[@]} -gt 0 ]; then
        print_status "info" "Installing missing packages: ${missing_packages[*]}"
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update
            sudo apt-get install -y "${missing_packages[@]}"
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y "${missing_packages[@]}"
        elif command -v dnf >/dev/null 2>&1; then
            sudo dnf install -y "${missing_packages[@]}"
        else
            handle_error "Could not install required packages: package manager not found"
        fi
        print_status "success" "Required packages installed successfully"
    else
        print_status "success" "All required packages are installed"
    fi
}

# Function to generate SSH keypair
generate_ssh_key() {
    print_section "Generating SSH keypair"
    
    # Check if key already exists and is valid
    if sudo test -f "$KEY_PATH" && sudo test -f "$KEY_PATH.pub"; then
        # Verify the key is readable and has correct permissions
        if sudo test -r "$KEY_PATH" && [ "$(sudo stat -c %a "$KEY_PATH")" = "600" ]; then
            print_status "info" "SSH keypair already exists and has correct permissions"
            return 0
        else
            print_status "warning" "Fixing permissions on existing SSH keypair"
            sudo chmod 600 "$KEY_PATH"
            sudo chmod 644 "$KEY_PATH.pub"
            return 0
        fi
    fi
    
    print_status "info" "Generating new SSH keypair"
    sudo ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "" -q
    
    if [ $? -eq 0 ]; then
        print_status "success" "SSH keypair generated successfully"
        sudo chmod 600 "$KEY_PATH"
        sudo chmod 644 "$KEY_PATH.pub"
    else
        handle_error "Failed to generate SSH keypair"
    fi
}

# Function to configure SSH server
configure_remote_server() {
    print_section "Configuring remote server"

    # Build SSH command with optional key
    local ssh_cmd=(ssh)
    if [ -n "$SSH_KEY" ]; then
        ssh_cmd+=(-i "$SSH_KEY")
    fi
    ssh_cmd+=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_HOST}")

    # Build environment variables string
    local env_vars="PUBLIC_KEY='$PUBLIC_KEY' "
    env_vars+="SSHD_CONFIG_DIR='$SSHD_CONFIG_DIR' "
    env_vars+="SSH_CONFIG='$SSH_CONFIG' "
    env_vars+="TARGET_IP='$LOCAL_TUN_IP' "
    env_vars+="SERVICE_PORT='$SERVICE_PORT' "
    env_vars+="SERVICE_PROTOCOL='$SERVICE_PROTOCOL' "

    # Execute the command with environment variables
    ssh_cmd+=("$env_vars bash -s")
    cat "$(dirname "$0")/configure_remote_server.sh" | "${ssh_cmd[@]}"

    if [ $? -eq 0 ]; then
        print_status "success" "Remote server configured successfully"
    else
        handle_error "Failed to configure remote server"
    fi
}

# Function to setup SSH tunnel
setup_ssh_tunnel() {
    print_section "Setting up SSH tunnel"

    # Get the directory containing the script
    local script_dir="$(dirname "$0")"

    # Generate temporary files with envsubst
    local temp_tunnel=$(mktemp)
    local temp_healthcheck=$(mktemp)
    local temp_timer=$(mktemp)

    # Process templates into temporary files
    envsubst < "$script_dir/ssh-tunnel.service" > "$temp_tunnel"
    envsubst < "$script_dir/ssh-tunnel-healthcheck.service" > "$temp_healthcheck"
    envsubst < "$script_dir/ssh-tunnel-healthcheck.timer" > "$temp_timer"

    # Function to check if files need updating
    needs_update() {
        local source="$1"
        local target="$2"
        if ! sudo test -f "$target" || ! sudo cmp -s "$source" "$target"; then
            return 0  # Files differ or target doesn't exist
        fi
        return 1  # Files are identical
    }

    # Check if any files need updating
    local needs_restart=false

    if needs_update "$temp_tunnel" "$SERVICE_UNIT_FILE"; then
        print_status "info" "Updating tunnel service file"
        sudo cp "$temp_tunnel" "$SERVICE_UNIT_FILE"
        needs_restart=true
    else
        print_status "info" "Tunnel service file is up to date"
    fi

    if needs_update "$temp_healthcheck" "$HEALTHCHECK_UNIT_FILE"; then
        print_status "info" "Updating healthcheck service file"
        sudo cp "$temp_healthcheck" "$HEALTHCHECK_UNIT_FILE"
        needs_restart=true
    else
        print_status "info" "Healthcheck service file is up to date"
    fi

    if needs_update "$temp_timer" "$HEALTHCHECK_TIMER_UNIT_FILE"; then
        print_status "info" "Updating healthcheck timer file"
        sudo cp "$temp_timer" "$HEALTHCHECK_TIMER_UNIT_FILE"
        needs_restart=true
    else
        print_status "info" "Healthcheck timer file is up to date"
    fi

    # Clean up temporary files
    rm -f "$temp_tunnel" "$temp_healthcheck" "$temp_timer"

    # Reload systemd only if needed
    if [ "$needs_restart" = true ]; then
        print_status "info" "Reloading systemd"
        sudo systemctl daemon-reload
        sudo systemctl restart "$SERVICE_NAME"
        sudo systemctl restart "$HEALTHCHECK_TIMER_NAME"
    else
        print_status "info" "No systemd reload needed"
    fi
    
    print_status "info" "Enabling and starting services"
    sudo systemctl enable --now "$SERVICE_NAME"
    sudo systemctl enable --now "$HEALTHCHECK_TIMER_NAME"

    print_status "success" "SSH tunnel setup completed successfully"
}

# Function to install config_interfaces.sh
install_config_interfaces() {
    print_section "Installing config_interfaces.sh"
    
    local source_file="$(dirname "$0")/config_interfaces.sh"
    local target_file="/usr/local/bin/config_interfaces.sh"
    
    # Check if target exists and is identical to source
    if sudo test -f "$target_file" && sudo cmp -s "$source_file" "$target_file"; then
        print_status "info" "config_interfaces.sh is already up to date"
        return 0
    fi
    
    print_status "info" "Installing config_interfaces.sh to /usr/local/bin..."
    sudo cp "$source_file" "$target_file"
    sudo chmod +x "$target_file"
    
    if [ $? -eq 0 ]; then
        print_status "success" "config_interfaces.sh installed successfully"
    else
        handle_error "Failed to install config_interfaces.sh"
    fi
}

# Main script
if [ $# -eq 0 ]; then
    show_help
fi

# Check sudo access
check_sudo_access

# Check and install required packages
check_required_packages

# Install config_interfaces.sh
install_config_interfaces

# Parse arguments
CONNECTION_STRING=""
SERVICE_PORT=""
SERVICE_PROTOCOL="tcp"  # Default protocol
SSH_KEY=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--service)
            # Parse port/protocol format
            if [[ "$2" =~ ^([0-9]+)(/([a-zA-Z]+))?$ ]]; then
                SERVICE_PORT="${BASH_REMATCH[1]}"
                if [ -n "${BASH_REMATCH[3]}" ]; then
                    SERVICE_PROTOCOL="${BASH_REMATCH[3]}"
                fi
            else
                handle_error "Invalid service port format. Expected format: PORT[/PROTOCOL] (e.g., 443/tcp)"
            fi
            shift 2
            ;;
        -i|--identity)
            SSH_KEY="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            ;;
        *)
            if [ -z "$CONNECTION_STRING" ]; then
                CONNECTION_STRING="$1"
            else
                handle_error "Unexpected argument: $1"
            fi
            shift
            ;;
    esac
done

# Validate required arguments
if [ -z "$CONNECTION_STRING" ]; then
    handle_error "Connection string is required"
fi

if [ -z "$SERVICE_PORT" ]; then
    handle_error "Service port is required"
fi

# Validate protocol
if [[ ! "$SERVICE_PROTOCOL" =~ ^(tcp|udp)$ ]]; then
    handle_error "Invalid protocol. Only 'tcp' or 'udp' are supported"
fi

# Parse connection string
if [[ $CONNECTION_STRING =~ ^([^@]+)@([^:]+)(:([0-9]+))?$ ]]; then
    REMOTE_USER="${BASH_REMATCH[1]}"
    REMOTE_HOST="${BASH_REMATCH[2]}"
    REMOTE_PORT="${BASH_REMATCH[4]:-22}"
else
    handle_error "Invalid connection string format. Expected format: user@host[:port]"
fi

# Generate SSH keypair
generate_ssh_key

# Get the public key
PUBLIC_KEY=$(sudo cat ${KEY_PATH}.pub | tr -d '\n' | sed 's/[[:space:]]*$//')

# Configure SSH server on remote host and inject public key
configure_remote_server

# Setup tunnel
setup_ssh_tunnel

print_section "Setup Summary"
print_status "success" "Setup completed successfully"
echo -e "${BOLD}Connection Information:${NC}"
echo -e "  ${DIM}Remote Host:${NC} ${GREEN}${REMOTE_HOST}${NC}"
echo -e "  ${DIM}Service Port:${NC} ${GREEN}${SERVICE_PORT}/${SERVICE_PROTOCOL}${NC}"
echo -e "  ${DIM}SSH Port:${NC} ${GREEN}${REMOTE_PORT}${NC}"
echo -e "\n${BOLD}You can now connect to the service on:${NC} ${GREEN}${REMOTE_HOST}:${SERVICE_PORT}${NC}"
