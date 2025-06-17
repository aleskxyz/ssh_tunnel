#!/bin/bash
set -euo pipefail

# Configuration from environment variables with fallback values
REMOTE_USER="root"
REMOTE_HOST="${REMOTE_HOST}"
LOCAL_TUN_IP="${LOCAL_TUN_IP}"
REMOTE_TUN_IP="${REMOTE_TUN_IP}"
NETMASK="${NETMASK:-/30}"
MAX_RETRIES="${MAX_RETRIES:-10}"
SLEEP_SEC="${SLEEP_SEC:-0.5}"
SSH_KEY="${SSH_KEY}"
TUNNEL_SERVICE=ssh-tunnel.service
SSH_PORT="${SSH_PORT:-22}"

# Helper functions for consistent messaging
log_info() {
    echo "[INFO] $1"
}

log_success() {
    echo "[SUCCESS] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
}

log_step() {
    echo -e "\n[STEP $1] $2"
}

# Function to construct SSH command
run_ssh() {
    local cmd="$1"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_KEY" "${REMOTE_USER}@${REMOTE_HOST}" "$cmd"
}

# Wait and get PID of the ssh tunnel from systemd
log_step "1" "Waiting for SSH tunnel service to start..."
for ((i=1; i<=MAX_RETRIES; i++)); do
    TUN_PID=$(systemctl show --property=MainPID --value "$TUNNEL_SERVICE")
    if [[ "$TUN_PID" != "0" && -n "$TUN_PID" ]]; then
        log_success "Found SSH tunnel PID: $TUN_PID"
        break
    fi
    sleep "$SLEEP_SEC"
done

if [[ "$TUN_PID" == "0" || -z "$TUN_PID" ]]; then
    log_error "Could not get SSH tunnel PID from systemd after $MAX_RETRIES attempts"
    exit 1
fi

# Find local tun interface
log_step "2" "Locating local tun interface..."
for ((i=1; i<=MAX_RETRIES; i++)); do
    LOCAL_TUN=$(grep '^iff:' /proc/"$TUN_PID"/fdinfo/* 2>/dev/null | head -n1 | awk '{print $2}' || true)
    if [[ -n "$LOCAL_TUN" ]]; then
        log_success "Found local tun interface: $LOCAL_TUN"
        break
    fi
    sleep "$SLEEP_SEC"
done

if [[ -z "$LOCAL_TUN" ]]; then
    log_error "Could not find local tun interface after $MAX_RETRIES attempts"
    exit 1
fi

# Find local SSH connection details
log_step "3" "Finding local SSH connection details..."
read LOCAL_IP LOCAL_PORT < <(lsof -iTCP -sTCP:ESTABLISHED -nP | grep ssh | grep "$TUN_PID" | grep "$REMOTE_HOST:$SSH_PORT" | awk '{split($9,a,":"); split(a[2],b,"->"); print a[1], b[1]}')

if [[ -z "$LOCAL_PORT" ]] || [[ -z "$LOCAL_IP" ]]; then
    log_error "Failed to find local SSH source IP or port"
    exit 1
fi

log_success "Local SSH connection: $LOCAL_IP:$LOCAL_PORT -> $REMOTE_HOST:$SSH_PORT"

# Find remote sshd PID
log_step "4" "Finding remote SSH daemon process..."
REMOTE_SSHD_PID=$(run_ssh "lsof -iTCP -sTCP:ESTABLISHED -nP | grep sshd | grep '$REMOTE_HOST:$SSH_PORT->$LOCAL_IP:$LOCAL_PORT' | awk '{print \$2}'")

if [[ -z "$REMOTE_SSHD_PID" ]]; then
    log_error "Failed to find remote SSH daemon process"
    exit 1
fi

log_success "Remote SSH daemon PID: $REMOTE_SSHD_PID"

# Find remote tun interface
log_step "5" "Locating remote tun interface..."
REMOTE_TUN=$(run_ssh "grep ^iff: /proc/$REMOTE_SSHD_PID/fdinfo/* 2>/dev/null | head -n1 | awk '{print \$2}'")

if [[ -z "$REMOTE_TUN" ]]; then
    log_error "Failed to detect remote tun interface"
    exit 1
fi

log_success "Remote tun interface: $REMOTE_TUN"

# Configure tun interfaces
log_step "6" "Configuring tunnel interfaces..."
sudo ip link set "$LOCAL_TUN" up
sudo ip addr add "$LOCAL_TUN_IP$NETMASK" peer "$REMOTE_TUN_IP" dev "$LOCAL_TUN"

run_ssh "sudo ip link set $REMOTE_TUN up && sudo ip addr add $REMOTE_TUN_IP$NETMASK peer $LOCAL_TUN_IP dev $REMOTE_TUN"

log_success "Tunnel configuration completed"
echo -e "\nTunnel Summary:"
echo "├─ Local Interface:  $LOCAL_TUN ($LOCAL_TUN_IP)"
echo "└─ Remote Interface: $REMOTE_TUN ($REMOTE_TUN_IP)"
echo -e "\nYou can now ping between the tunnel IPs to verify connectivity."
