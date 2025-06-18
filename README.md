# SSH Tunnel

A robust and secure solution for establishing SSH tunnels with automatic health checks and systemd service management.

## Overview

This project provides a set of scripts and systemd services to create and maintain secure SSH tunnels. It's designed to be easy to set up and maintain, with features like:

- Automatic SSH key generation and management
- Systemd service integration for reliable operation
- Health check monitoring
- Support for multiple protocols (TCP/UDP)
- Automatic reconnection on failure
- Secure configuration management

## Technical Details

The solution uses the following technologies:
- SSH TUN interface for creating a virtual network interface
- socat for TCP port forwarding
- glider for UDP port forwarding
- No iptables modifications required

## Prerequisites

- Linux-based operating system
- SSH server running on the remote machine
- Sudo privileges
- Basic networking tools (lsof)
- socat (for TCP forwarding)
- glider (for UDP forwarding)

## Installation

The installation process is straightforward using the provided setup script:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/aleskxyz/ssh_tunnel/main/setup.sh) USER@HOST[:PORT] -s SERVICE_PORT[/PROTOCOL] [-i SSH_KEY]
```

### Parameters

- `USER@HOST[:PORT]`: Connection string (e.g., root@192.168.1.100:22)
- `-s SERVICE_PORT[/PROTOCOL]`: Port of the service to forward (e.g., 443/tcp)
- `-i SSH_KEY`: (Optional) Path to SSH key for authentication

### Example

```bash
bash <(curl -sSL https://raw.githubusercontent.com/aleskxyz/ssh_tunnel/main/setup.sh) root@192.168.1.100:22 -s 443/tcp -i ~/.ssh/id_rsa
```

## Components

The project consists of several key components:

1. **Setup Scripts**
   - `setup.sh`: Main installation script
   - `setup_ssh_tunnel.sh`: Core setup script for the SSH tunnel
   - `configure_remote_server.sh`: Remote server configuration script
   - `config_interfaces.sh`: Network interface configuration

2. **Systemd Services**
   - `ssh-tunnel.service`: Main tunnel service
   - `ssh-tunnel-healthcheck.service`: Health check service
   - `ssh-tunnel-healthcheck.timer`: Health check timer
   - `ssh-tunnel-tcp-forwarder@.service`: TCP forwarder service on remote host
   - `ssh-tunnel-udp-forwarder@.service`: UDP forwarder service on remote host

## Features

- **Automatic Key Management**: Generates and manages SSH keys securely
- **Health Monitoring**: Regular health checks to ensure tunnel stability
- **Automatic Recovery**: Automatic reconnection on connection loss
- **Secure Configuration**: Proper file permissions and secure defaults
- **Systemd Integration**: Reliable service management and automatic startup

## Security

- SSH keys are generated with ED25519 algorithm
- Proper file permissions are enforced
- Secure default configurations
- No password authentication (key-based only)

## License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.
