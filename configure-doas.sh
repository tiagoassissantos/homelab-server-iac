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

echo -e "${BLUE}=== Configure doas for Ansible ===${NC}"
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

print_status "INFO" "This script will configure doas for passwordless access"
print_status "WARN" "You will need to enter your password when prompted"
echo ""

# Test current SSH connection
print_status "INFO" "Testing SSH connection..."
if ssh -o ConnectTimeout=5 ${SERVER_USER}@${SERVER_IP} "echo 'SSH OK'" > /dev/null 2>&1; then
    print_status "OK" "SSH connection successful"
else
    print_status "FAIL" "SSH connection failed"
    exit 1
fi

# Check current doas configuration
print_status "INFO" "Checking current doas configuration..."
CURRENT_CONFIG=$(ssh ${SERVER_USER}@${SERVER_IP} "doas cat /etc/doas.conf 2>/dev/null || echo 'No config found'")
echo "Current doas.conf:"
echo "$CURRENT_CONFIG"
echo ""

# Create doas configuration script
print_status "INFO" "Creating doas configuration script..."

DOAS_SCRIPT=$(cat << 'EOF'
#!/bin/sh
set -e

echo "=== Configuring doas on Alpine Linux ==="

USER_NAME=$(whoami)
echo "Configuring doas for user: $USER_NAME"

# Backup existing doas.conf if it exists
if [ -f /etc/doas.conf ]; then
    echo "Backing up existing doas.conf..."
    doas cp /etc/doas.conf /etc/doas.conf.backup.$(date +%Y%m%d-%H%M%S)
fi

# Create new doas.conf
echo "Creating new doas.conf..."
doas tee /etc/doas.conf > /dev/null << DOAS_EOF
# doas configuration for Ansible automation

# Allow user to run commands as root without password
permit nopass $USER_NAME as root

# Allow user to run commands as any user without password
permit nopass $USER_NAME

# Keep environment variables (needed for some operations)
permit nopass keepenv $USER_NAME as root

# Allow user to run specific commands that might be needed
permit nopass $USER_NAME as root cmd /bin/sh
permit nopass $USER_NAME as root cmd /usr/bin/python3
permit nopass $USER_NAME as root cmd /sbin/apk
permit nopass $USER_NAME as root cmd /bin/mkdir
permit nopass $USER_NAME as root cmd /bin/chown
permit nopass $USER_NAME as root cmd /bin/chmod
permit nopass $USER_NAME as root cmd /usr/bin/tee
permit nopass $USER_NAME as root cmd /sbin/modprobe
permit nopass $USER_NAME as root cmd /sbin/sysctl
permit nopass $USER_NAME as root cmd /usr/sbin/iptables
permit nopass $USER_NAME as root cmd /usr/sbin/ip6tables
permit nopass $USER_NAME as root cmd /bin/systemctl
permit nopass $USER_NAME as root cmd /sbin/service
DOAS_EOF

# Set proper permissions on doas.conf
doas chmod 600 /etc/doas.conf
doas chown root:root /etc/doas.conf

echo ""
echo "New doas.conf content:"
doas cat /etc/doas.conf

echo ""
echo "Testing doas functionality..."

# Test basic doas functionality
if doas whoami > /dev/null 2>&1; then
    echo "✅ Basic doas test successful"
else
    echo "❌ Basic doas test failed"
    exit 1
fi

# Test specific commands
if doas /bin/sh -c "echo 'Shell test successful'" > /dev/null 2>&1; then
    echo "✅ doas shell test successful"
else
    echo "❌ doas shell test failed"
    exit 1
fi

# Test Python execution (needed for Ansible)
if doas /usr/bin/python3 -c "print('Python test successful')" > /dev/null 2>&1; then
    echo "✅ doas Python test successful"
else
    echo "❌ doas Python test failed"
    exit 1
fi

echo ""
echo "✅ doas configuration completed successfully!"
echo "The user '$USER_NAME' can now use doas without password prompts."
EOF
)

# Copy and execute the script
echo "$DOAS_SCRIPT" | ssh ${SERVER_USER}@${SERVER_IP} "cat > /tmp/configure-doas.sh && chmod +x /tmp/configure-doas.sh"

print_status "INFO" "Running doas configuration on server..."
print_status "WARN" "You will be prompted for your password to configure doas"
echo ""

# Execute the configuration script
if ssh -t ${SERVER_USER}@${SERVER_IP} "/tmp/configure-doas.sh 2>&1"; then
    print_status "OK" "doas configuration completed successfully"
else
    print_status "FAIL" "doas configuration failed"
    exit 1
fi

# Clean up temporary script
ssh ${SERVER_USER}@${SERVER_IP} "rm -f /tmp/configure-doas.sh" || true

print_status "INFO" "Testing doas functionality..."

# Test doas without password
if ssh ${SERVER_USER}@${SERVER_IP} "doas whoami" > /dev/null 2>&1; then
    print_status "OK" "Passwordless doas is working"
else
    print_status "WARN" "doas may still require password, but configuration is complete"
fi

# Test Python execution through doas (what Ansible needs)
if ssh ${SERVER_USER}@${SERVER_IP} "doas python3 -c 'import sys; print(sys.version)'" > /dev/null 2>&1; then
    print_status "OK" "Python execution through doas is working"
else
    print_status "WARN" "Python execution through doas may have issues"
fi

echo ""
print_status "OK" "doas configuration completed!"
echo ""
echo "You can now test Ansible connectivity:"
echo "  ansible masters -m ping"
echo ""
echo "If there are still issues, you can run the playbook with:"
echo "  ansible-playbook -i inventory/hosts.ini playbook.yaml --ask-become-pass"
echo ""
echo "To verify doas configuration manually:"
echo "  ssh ${SERVER_USER}@${SERVER_IP} 'doas cat /etc/doas.conf'"
echo ""
