#!/bin/bash

# Quick fix script to resolve k3s ServiceLB conflicts with MetalLB
# This script disables k3s built-in ServiceLB and lets MetalLB handle LoadBalancer services

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    local status=$1
    local message=$2
    case $status in
        "OK")
            echo -e "${GREEN}✓${NC} $message"
            ;;
        "WARN")
            echo -e "${YELLOW}⚠${NC} $message"
            ;;
        "ERROR")
            echo -e "${RED}✗${NC} $message"
            ;;
        "INFO")
            echo -e "${BLUE}ℹ${NC} $message"
            ;;
    esac
}

# Configuration
SERVER_IP="10.0.0.10"
SERVER_USER="tiago"

echo "=========================================="
echo "  k3s ServiceLB Conflict Fix Script"
echo "=========================================="
echo ""

print_status "INFO" "This script will:"
echo "  1. Stop k3s service"
echo "  2. Remove stuck ServiceLB daemonsets"
echo "  3. Restart k3s with ServiceLB disabled"
echo "  4. Let MetalLB handle LoadBalancer services"
echo ""

# Check SSH connectivity
print_status "INFO" "Testing SSH connection to $SERVER_USER@$SERVER_IP..."
if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no $SERVER_USER@$SERVER_IP "echo 'SSH OK'" > /dev/null 2>&1; then
    print_status "ERROR" "Cannot connect to k3s server via SSH"
    echo "Make sure you can SSH to $SERVER_USER@$SERVER_IP"
    exit 1
fi
print_status "OK" "SSH connection successful"

# Function to run remote commands
run_remote() {
    ssh -o StrictHostKeyChecking=no $SERVER_USER@$SERVER_IP "$1"
}

echo ""
print_status "INFO" "Step 1: Stopping k3s service..."
if run_remote "sudo systemctl stop k3s" 2>/dev/null; then
    print_status "OK" "k3s service stopped"
else
    print_status "WARN" "k3s service may already be stopped"
fi

echo ""
print_status "INFO" "Step 2: Cleaning up stuck ServiceLB resources..."

# Remove ServiceLB daemonsets
print_status "INFO" "Removing ServiceLB daemonsets..."
run_remote "sudo k3s kubectl delete daemonset -n kube-system -l app=svclb --ignore-not-found=true" 2>/dev/null || true
run_remote "sudo k3s kubectl delete pods -n kube-system -l app=svclb --force --grace-period=0 --ignore-not-found=true" 2>/dev/null || true

print_status "OK" "ServiceLB resources cleaned up"

echo ""
print_status "INFO" "Step 3: Updating k3s configuration..."

# Check if k3s config exists and backup
run_remote "sudo mkdir -p /etc/rancher/k3s" 2>/dev/null || true

# Create or update k3s config
print_status "INFO" "Adding --disable servicelb to k3s configuration..."
run_remote "echo 'write-kubeconfig-mode: \"644\"' | sudo tee /etc/rancher/k3s/config.yaml > /dev/null"
run_remote "echo 'disable:' | sudo tee -a /etc/rancher/k3s/config.yaml > /dev/null"
run_remote "echo '  - servicelb' | sudo tee -a /etc/rancher/k3s/config.yaml > /dev/null"

print_status "OK" "k3s configuration updated"

echo ""
print_status "INFO" "Step 4: Starting k3s service..."
if run_remote "sudo systemctl start k3s"; then
    print_status "OK" "k3s service started"
else
    print_status "ERROR" "Failed to start k3s service"
    exit 1
fi

# Wait for k3s to be ready
print_status "INFO" "Waiting for k3s to be ready..."
sleep 10

# Check if k3s is running
for i in {1..30}; do
    if run_remote "sudo systemctl is-active k3s" | grep -q "active"; then
        print_status "OK" "k3s is running"
        break
    fi
    if [ $i -eq 30 ]; then
        print_status "ERROR" "k3s failed to start properly"
        exit 1
    fi
    sleep 2
done

echo ""
print_status "INFO" "Step 5: Verifying cluster status..."

# Wait for nodes to be ready
print_status "INFO" "Waiting for nodes to be ready..."
sleep 15

# Check node status
node_status=$(run_remote "sudo k3s kubectl get nodes --no-headers" 2>/dev/null || echo "")
if echo "$node_status" | grep -q "Ready"; then
    print_status "OK" "Node is ready"
else
    print_status "WARN" "Node may still be starting up"
fi

echo ""
print_status "INFO" "Step 6: Checking service status..."

# Check if MetalLB is running
metallb_status=$(run_remote "sudo k3s kubectl get pods -n metallb-system --no-headers" 2>/dev/null || echo "")
if echo "$metallb_status" | grep -q "Running"; then
    print_status "OK" "MetalLB is running"
else
    print_status "WARN" "MetalLB may still be starting up"
fi

# Check LoadBalancer services
print_status "INFO" "Checking LoadBalancer services..."
lb_services=$(run_remote "sudo k3s kubectl get services --all-namespaces -o wide | grep LoadBalancer" 2>/dev/null || echo "")
if [ -n "$lb_services" ]; then
    print_status "INFO" "LoadBalancer services found:"
    echo "$lb_services" | sed 's/^/  /'
else
    print_status "WARN" "No LoadBalancer services found"
fi

echo ""
print_status "INFO" "Step 7: Verification complete!"
echo ""
print_status "INFO" "Next steps:"
echo "  1. Wait 2-3 minutes for all services to stabilize"
echo "  2. Run: kubectl get services --all-namespaces"
echo "  3. Check that services have EXTERNAL-IP assigned"
echo "  4. If needed, run the full playbook to recreate services:"
echo "     ansible-playbook -i inventory/hosts.ini playbook.yaml"

echo ""
print_status "INFO" "You can monitor the services with:"
echo "  kubectl get pods -n kube-system | grep -v svclb"
echo "  kubectl get services --all-namespaces"
echo "  kubectl get pods -n metallb-system"

echo ""
print_status "OK" "ServiceLB conflict fix completed!"
echo "=========================================="
