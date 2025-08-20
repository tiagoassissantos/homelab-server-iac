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

echo -e "${BLUE}=== Kubernetes API Server Connectivity Diagnostic ===${NC}"
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

# Function to run remote command
run_remote() {
    ssh -o StrictHostKeyChecking=no ${SERVER_USER}@${SERVER_IP} "$1" 2>/dev/null
}

# Function to run remote kubectl command
run_kubectl() {
    run_remote "kubectl $*"
}

print_status "INFO" "Diagnosing the cert-manager API connectivity issue..."
echo ""

# Test 1: Basic connectivity
print_status "INFO" "Testing basic SSH connectivity..."
if run_remote "echo 'SSH OK'" >/dev/null; then
    print_status "OK" "SSH connection successful"
else
    print_status "FAIL" "SSH connection failed"
    exit 1
fi

# Test 2: Check k3s service status
print_status "INFO" "Checking k3s service status..."
k3s_status=$(run_remote "sudo systemctl is-active k3s" || echo "unknown")
if [ "$k3s_status" = "active" ]; then
    print_status "OK" "k3s service is running"
else
    print_status "FAIL" "k3s service is not active: $k3s_status"
    echo "   Checking k3s service logs:"
    run_remote "sudo journalctl -u k3s --lines=10 --no-pager" | sed 's/^/   /'
fi

# Test 3: Check API server endpoint
print_status "INFO" "Checking Kubernetes API server endpoint..."
api_endpoint=$(run_kubectl "config view --minify -o jsonpath='{.clusters[0].cluster.server}'" || echo "unknown")
echo "   API Server endpoint: $api_endpoint"

if [[ "$api_endpoint" == *"10.43.0.1"* ]]; then
    print_status "WARN" "API server is using service IP (10.43.0.1) - this might cause connectivity issues"
else
    print_status "OK" "API server endpoint looks normal"
fi

# Test 4: Check cluster nodes
print_status "INFO" "Checking cluster nodes..."
node_status=$(run_kubectl "get nodes --no-headers" 2>/dev/null || echo "failed")
if [ "$node_status" != "failed" ]; then
    print_status "OK" "Can query nodes from master"
    echo "   Nodes:"
    echo "$node_status" | sed 's/^/   /'
else
    print_status "FAIL" "Cannot query cluster nodes"
fi

# Test 5: Check service connectivity from within cluster
print_status "INFO" "Testing API connectivity from within a pod..."
connectivity_test=$(cat << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: connectivity-test
  namespace: default
spec:
  restartPolicy: Never
  containers:
  - name: test
    image: alpine:latest
    command: ["/bin/sh"]
    args: ["-c", "apk add --no-cache curl && curl -k https://kubernetes.default.svc.cluster.local:443/version --connect-timeout 10 || echo 'FAILED'"]
EOF
)

# Clean up any existing test pod
run_kubectl "delete pod connectivity-test --ignore-not-found" >/dev/null 2>&1

# Create and run test pod
echo "$connectivity_test" | run_remote "kubectl apply -f -" >/dev/null 2>&1
if run_remote "kubectl wait --for=condition=Ready pod/connectivity-test --timeout=60s" >/dev/null 2>&1; then
    test_result=$(run_kubectl "logs connectivity-test" 2>/dev/null | tail -1)
    if [[ "$test_result" == *"FAILED"* ]] || [[ "$test_result" == *"timeout"* ]]; then
        print_status "FAIL" "Pod cannot connect to API server"
        echo "   Test result: $test_result"
    else
        print_status "OK" "Pod can connect to API server"
    fi
else
    print_status "WARN" "Test pod did not become ready"
fi

# Clean up test pod
run_kubectl "delete pod connectivity-test --ignore-not-found" >/dev/null 2>&1

# Test 6: Check cert-manager specific issues
print_status "INFO" "Checking cert-manager specific issues..."

# Check if cert-manager namespace exists
if run_kubectl "get namespace cert-manager" >/dev/null 2>&1; then
    print_status "OK" "cert-manager namespace exists"

    # Check cert-manager pods
    cm_pods=$(run_kubectl "get pods -n cert-manager --no-headers" 2>/dev/null || echo "failed")
    if [ "$cm_pods" != "failed" ]; then
        echo "   cert-manager pods:"
        echo "$cm_pods" | sed 's/^/   /'

        # Check for the specific secret
        if run_kubectl "get secret cert-manager-webhook-ca -n cert-manager" >/dev/null 2>&1; then
            print_status "OK" "cert-manager-webhook-ca secret exists"
        else
            print_status "FAIL" "cert-manager-webhook-ca secret is missing"
        fi

        # Show recent webhook logs
        print_status "INFO" "Recent cert-manager-webhook logs:"
        webhook_logs=$(run_kubectl "logs -n cert-manager deployment/cert-manager-webhook --tail=5" 2>/dev/null || echo "No logs available")
        echo "$webhook_logs" | sed 's/^/   /'
    else
        print_status "FAIL" "Cannot get cert-manager pods"
    fi
else
    print_status "WARN" "cert-manager namespace does not exist"
fi

# Test 7: Check network policies and firewall
print_status "INFO" "Checking network configuration..."

# Check if there are network policies blocking traffic
netpol_count=$(run_kubectl "get networkpolicies --all-namespaces --no-headers" 2>/dev/null | wc -l || echo "0")
if [ "$netpol_count" -gt 0 ]; then
    print_status "WARN" "Network policies found ($netpol_count) - they might block traffic"
    run_kubectl "get networkpolicies --all-namespaces" | sed 's/^/   /'
else
    print_status "OK" "No network policies blocking traffic"
fi

# Test 8: Check if API server is responsive
print_status "INFO" "Testing API server responsiveness..."
api_response=$(run_remote "timeout 10 kubectl version --short" 2>/dev/null || echo "timeout")
if [[ "$api_response" == *"timeout"* ]] || [ -z "$api_response" ]; then
    print_status "FAIL" "API server is not responding or very slow"
else
    print_status "OK" "API server is responsive"
    echo "   Version info:"
    echo "$api_response" | sed 's/^/   /'
fi

# Test 9: Check k3s configuration
print_status "INFO" "Checking k3s configuration..."
k3s_config=$(run_remote "sudo cat /etc/systemd/system/k3s.service.d/override.conf" 2>/dev/null || echo "no override")
if [ "$k3s_config" != "no override" ]; then
    print_status "INFO" "k3s has custom configuration"
    echo "$k3s_config" | sed 's/^/   /'
fi

# Check k3s server arguments
k3s_args=$(run_remote "ps aux | grep '[k]3s server'" || echo "not found")
if [ "$k3s_args" != "not found" ]; then
    print_status "INFO" "k3s server process arguments:"
    echo "$k3s_args" | sed 's/^/   /'
fi

echo ""
echo -e "${BLUE}=== DIAGNOSIS SUMMARY ===${NC}"
echo ""

# Provide recommendations based on the cert-manager logs
print_status "INFO" "Based on your cert-manager logs, the issue is:"
echo "   - cert-manager webhook cannot connect to API server at 10.43.0.1:443"
echo "   - Getting 'dial tcp 10.43.0.1:443: i/o timeout' errors"
echo ""

print_status "INFO" "Recommended fixes:"
echo ""
echo "1. RESTART K3S SERVICE (most likely fix):"
echo "   ssh ${SERVER_USER}@${SERVER_IP} 'sudo systemctl restart k3s'"
echo "   # Wait 30 seconds then test: kubectl get nodes"
echo ""
echo "2. DELETE AND REINSTALL CERT-MANAGER:"
echo "   ssh ${SERVER_USER}@${SERVER_IP} 'kubectl delete namespace cert-manager'"
echo "   # Wait for cleanup, then re-run your playbook"
echo ""
echo "3. CHECK SYSTEM RESOURCES:"
echo "   ssh ${SERVER_USER}@${SERVER_IP} 'free -h && df -h'"
echo "   # Low memory/disk can cause API timeouts"
echo ""
echo "4. RESTART THE SERVER (if above don't work):"
echo "   ssh ${SERVER_USER}@${SERVER_IP} 'sudo reboot'"
echo ""

print_status "WARN" "The 10.43.0.1 IP is the Kubernetes service network IP for the API server."
print_status "INFO" "Timeout connecting to it usually indicates k3s internal networking issues."
echo ""

# Provide automatic fix options
echo "Do you want me to try automatic fixes?"
echo "1) Restart k3s service"
echo "2) Delete cert-manager namespace (you'll need to re-run playbook)"
echo "3) Show detailed diagnostics only"
echo "4) Exit"

read -p "Enter your choice (1-4): " -n 1 -r
echo ""

case $REPLY in
    1)
        print_status "INFO" "Restarting k3s service..."
        if run_remote "sudo systemctl restart k3s"; then
            print_status "OK" "k3s service restarted"
            print_status "INFO" "Waiting 30 seconds for k3s to stabilize..."
            sleep 30

            if run_kubectl "get nodes" >/dev/null 2>&1; then
                print_status "OK" "k3s is working after restart"
                print_status "INFO" "You can now re-run your Ansible playbook"
            else
                print_status "WARN" "k3s might still be starting up, wait a bit longer"
            fi
        else
            print_status "FAIL" "Failed to restart k3s service"
        fi
        ;;
    2)
        print_status "INFO" "Deleting cert-manager namespace..."
        if run_kubectl "delete namespace cert-manager --timeout=300s"; then
            print_status "OK" "cert-manager namespace deleted"
            print_status "INFO" "You can now re-run your Ansible playbook"
        else
            print_status "WARN" "cert-manager deletion may have timed out"
            print_status "INFO" "Try: kubectl delete namespace cert-manager --force --grace-period=0"
        fi
        ;;
    3)
        print_status "INFO" "Showing k3s service status:"
        run_remote "sudo systemctl status k3s --no-pager" | sed 's/^/   /'
        echo ""
        print_status "INFO" "Showing recent k3s logs:"
        run_remote "sudo journalctl -u k3s --lines=20 --no-pager" | sed 's/^/   /'
        ;;
    4)
        print_status "INFO" "Exiting"
        exit 0
        ;;
    *)
        print_status "WARN" "Invalid choice"
        ;;
esac

echo ""
print_status "INFO" "Diagnostic complete. Check the recommendations above if issues persist."
