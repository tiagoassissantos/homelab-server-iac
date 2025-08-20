#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SERVER_IP="10.0.0.10"
SERVER_USER="tiago"

echo -e "${BLUE}=== Alpine Linux sudo Fix Script ===${NC}"
echo ""

# Function to print status
print_status() {
    local status=$1
    local message=$2
    if [ "$status" = "OK" ]; then
        echo -e "✅ ${GREEN}$message${NC}"
    elif [ "$status" = "WARN" ]; then
        echo -e "⚠️  ${YELLOW}$message${NC}"
    elif [ "$status" = "INFO" ]; then
        echo -e "ℹ️  ${BLUE}$message${NC}"
    else
        echo -e "❌ ${RED}$message${NC}"
    fi
}

print_status "INFO" "This script will replace doas-sudo-shim with real sudo on your Alpine server"
print_status "WARN" "You will need to enter your user password when prompted"
echo ""

# Create temporary script on the server
print_status "INFO" "Creating temporary fix script on server..."

TEMP_SCRIPT=$(cat << 'EOF'
#!/bin/sh
set -e

echo "=== Fixing sudo on Alpine Linux ==="

# Check current sudo implementation
echo "Current sudo implementation:"
which sudo || echo "sudo not found"
sudo --version 2>&1 | head -1 || echo "Cannot get sudo version"

echo ""
echo "Installing real sudo..."

# Update package cache
doas apk update

# Install real sudo and remove doas-sudo-shim
doas apk add sudo !doas-sudo-shim

# Configure sudo for the user
USER_NAME=$(whoami)
echo "Configuring sudo for user: $USER_NAME"

# Add user to wheel group if not already
doas addgroup $USER_NAME wheel 2>/dev/null || true

# Configure sudoers
echo "Configuring sudoers..."
doas tee /etc/sudoers.d/wheel > /dev/null << SUDOERS_EOF
# Allow wheel group to run all commands
%wheel ALL=(ALL:ALL) ALL

# Allow wheel group to run all commands without password (for Ansible)
%wheel ALL=(ALL:ALL) NOPASSWD: ALL
SUDOERS_EOF

# Set proper permissions
doas chmod 440 /etc/sudoers.d/wheel

# Test sudo
echo ""
echo "Testing sudo functionality..."
sudo -n whoami && echo "✅ Passwordless sudo works!" || echo "⚠️  Passwordless sudo failed, but sudo is installed"

echo ""
echo "✅ sudo installation complete!"
echo "You can now run Ansible playbooks with sudo privilege escalation."
EOF
)

# Copy script to server and execute it
echo "$TEMP_SCRIPT" | ssh -T ${SERVER_USER}@${SERVER_IP} "cat > /tmp/fix-sudo.sh && chmod +x /tmp/fix-sudo.sh"

print_status "INFO" "Running fix script on server..."
echo -e "${YELLOW}You may be prompted for your password multiple times${NC}"
echo ""

# Execute the script
if ssh -t ${SERVER_USER}@${SERVER_IP} "/tmp/fix-sudo.sh"; then
    print_status "OK" "sudo fix script completed successfully"
else
    print_status "FAIL" "sudo fix script failed"
    exit 1
fi

# Clean up temporary script
ssh ${SERVER_USER}@${SERVER_IP} "rm -f /tmp/fix-sudo.sh" || true

print_status "INFO" "Testing sudo functionality..."

# Test sudo functionality
if ssh ${SERVER_USER}@${SERVER_IP} "sudo -n whoami" > /dev/null 2>&1; then
    print_status "OK" "Passwordless sudo is working correctly"
else
    print_status "WARN" "Passwordless sudo not working, but sudo is installed"
    echo "This is normal - Ansible can still work with password prompts"
fi

print_status "INFO" "Verifying sudo installation..."
echo "Sudo version on server:"
ssh ${SERVER_USER}@${SERVER_IP} "sudo --version 2>/dev/null | head -1" || echo "Could not get version"

echo ""
print_status "OK" "Alpine Linux sudo fix completed!"
echo ""
echo "You can now run your Ansible playbook:"
echo "  ansible-playbook -i inventory/hosts.ini playbook.yaml"
echo ""
echo "If you still encounter issues, you may need to use:"
echo "  ansible-playbook -i inventory/hosts.ini playbook.yaml --ask-become-pass"
echo ""
