#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration (should match your all.yaml)
PIHOLE_IP="10.0.0.101"
ARGO_HOST="argo.homelab.contdiscovery.lan"
SERVER_IP="10.0.0.10"
ANSIBLE_USER="tiago"

echo -e "${BLUE}=== Homelab k3s Cluster Validation ===${NC}"
echo ""

# Function to print status
print_status() {
    local status=$1
    local message=$2
    if [ "$status" = "OK" ]; then
        echo -e "✅ ${GREEN}$message${NC}"
    elif [ "$status" = "WARN" ]; then
        echo -e "⚠️  ${YELLOW}$message${NC}"
    else
        echo -e "❌ ${RED}$message${NC}"
    fi
}

# Function to run remote command
run_remote() {
    ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 ${ANSIBLE_USER}@${SERVER_IP} "$1" 2>/dev/null
}

# Test 1: SSH connectivity
echo -e "${BLUE}1. Testing SSH connectivity...${NC}"
if run_remote "echo 'SSH connection successful'" >/dev/null; then
    print_status "OK" "SSH connection to $SERVER_IP successful"
else
    print_status "FAIL" "SSH connection to $SERVER_IP failed"
    exit 1
fi

# Test 2: k3s cluster status
echo -e "\n${BLUE}2. Checking k3s cluster status...${NC}"
if run_remote "kubectl get nodes --no-headers" | grep -q "Ready"; then
    print_status "OK" "k3s cluster is running"
    echo "   Nodes:"
    run_remote "kubectl get nodes" | sed 's/^/   /'
else
    print_status "FAIL" "k3s cluster is not ready"
fi

# Test 3: Core system pods
echo -e "\n${BLUE}3. Checking system pods...${NC}"
system_pods=$(run_remote "kubectl get pods -n kube-system --no-headers" | wc -l)
running_pods=$(run_remote "kubectl get pods -n kube-system --no-headers" | grep -c "Running" || true)

if [ "$system_pods" -gt 0 ] && [ "$running_pods" -eq "$system_pods" ]; then
    print_status "OK" "All system pods are running ($running_pods/$system_pods)"
else
    print_status "WARN" "Some system pods may not be ready ($running_pods/$system_pods)"
    echo "   Pod status:"
    run_remote "kubectl get pods -n kube-system" | sed 's/^/   /'
fi

# Test 4: MetalLB
echo -e "\n${BLUE}4. Checking MetalLB...${NC}"
if run_remote "kubectl get pods -n metallb-system --no-headers" | grep -q "Running"; then
    print_status "OK" "MetalLB is running"
else
    print_status "FAIL" "MetalLB is not running properly"
fi

# Test 5: Pi-hole deployment
echo -e "\n${BLUE}5. Checking Pi-hole deployment...${NC}"
if run_remote "kubectl get pods -n pihole --no-headers" | grep -q "Running"; then
    print_status "OK" "Pi-hole pod is running"

    # Check if service has external IP
    pihole_service_ip=$(run_remote "kubectl get service pihole-service -n pihole -o jsonpath='{.status.loadBalancer.ingress[0].ip}'" 2>/dev/null || echo "")
    if [ "$pihole_service_ip" = "$PIHOLE_IP" ]; then
        print_status "OK" "Pi-hole service has correct external IP: $PIHOLE_IP"
    else
        print_status "WARN" "Pi-hole service IP: expected $PIHOLE_IP, got '$pihole_service_ip'"
    fi
else
    print_status "FAIL" "Pi-hole pod is not running"
fi

# Test 6: Pi-hole web interface
echo -e "\n${BLUE}6. Testing Pi-hole web interface...${NC}"
if curl -s -m 10 "http://$PIHOLE_IP/admin" | grep -q "Pi-hole"; then
    print_status "OK" "Pi-hole web interface is accessible at http://$PIHOLE_IP/admin"
else
    print_status "FAIL" "Pi-hole web interface is not accessible"
fi

# Test 7: Pi-hole DNS service (port 5353)
echo -e "\n${BLUE}7. Testing Pi-hole DNS service on port 5353...${NC}"
if command -v dig >/dev/null 2>&1; then
    if dig @$PIHOLE_IP -p 5353 google.com +short +timeout=5 >/dev/null 2>&1; then
        print_status "OK" "Pi-hole DNS is responding on port 5353"
    else
        print_status "WARN" "Pi-hole DNS test failed on port 5353 (may still be starting up)"
    fi
else
    print_status "WARN" "dig command not available, skipping DNS test"
fi

# Test 8: DNS resolution via Pi-hole
echo -e "\n${BLUE}8. Testing DNS resolution via Pi-hole...${NC}"
if nslookup google.com $PIHOLE_IP >/dev/null 2>&1; then
    print_status "OK" "DNS resolution through Pi-hole is working"
else
    print_status "FAIL" "DNS resolution through Pi-hole failed"
fi

# Test 8: Argo Workflows
echo -e "\n${BLUE}8. Checking Argo Workflows...${NC}"
if run_remote "kubectl get pods -n argo --no-headers" | grep -q "Running"; then
    print_status "OK" "Argo Workflows is running"

    # Check if ingress is configured
    if run_remote "kubectl get ingress -n argo" | grep -q "$ARGO_HOST"; then
        print_status "OK" "Argo Workflows ingress is configured"
    else
        print_status "WARN" "Argo Workflows ingress may not be configured"
    fi
else
    print_status "FAIL" "Argo Workflows is not running"
fi

# Test 9: cert-manager
echo -e "\n${BLUE}9. Checking cert-manager...${NC}"
if run_remote "kubectl get pods -n cert-manager --no-headers" | grep -q "Running"; then
    cert_pods=$(run_remote "kubectl get pods -n cert-manager --no-headers" | grep -c "Running")
    print_status "OK" "cert-manager is running ($cert_pods pods)"
else
    print_status "FAIL" "cert-manager is not running properly"
fi

# Test 10: Cluster resource usage
echo -e "\n${BLUE}10. Checking cluster resources...${NC}"
node_info=$(run_remote "kubectl top node 2>/dev/null" || echo "Metrics not available")
if [ "$node_info" != "Metrics not available" ]; then
    echo "   Resource usage:"
    echo "$node_info" | sed 's/^/   /'
    print_status "OK" "Cluster metrics are available"
else
    print_status "WARN" "Cluster metrics not available (metrics-server may not be installed)"
fi

# Test 11: Storage classes
echo -e "\n${BLUE}11. Checking storage classes...${NC}"
if run_remote "kubectl get storageclass" | grep -q "local-path"; then
    print_status "OK" "Default storage class is available"
else
    print_status "WARN" "No storage class found"
fi

# Summary
echo -e "\n${BLUE}=== Validation Summary ===${NC}"
echo ""
echo "Services to test manually:"
echo "  • Pi-hole Admin: http://$PIHOLE_IP/admin"
echo "  • Argo Workflows: https://$ARGO_HOST (add to /etc/hosts if using self-signed certs)"
echo ""
echo "DNS Configuration:"
echo "  • Configure your router or device DNS to: $PIHOLE_IP"
echo "  • Test: nslookup example.com $PIHOLE_IP"
echo ""
echo "Kubernetes Access:"
echo "  • SSH: ssh ${ANSIBLE_USER}@${SERVER_IP}"
echo "  • kubectl: run from the server or copy ~/.kube/config"
echo ""

# Test if we can reach the services from current machine
echo -e "${BLUE}Additional connectivity tests from this machine:${NC}"

# Test Pi-hole from local machine
if ping -c 1 -W 3 "$PIHOLE_IP" >/dev/null 2>&1; then
    print_status "OK" "Can reach Pi-hole IP ($PIHOLE_IP) from this machine"
else
    print_status "WARN" "Cannot reach Pi-hole IP ($PIHOLE_IP) from this machine (check network routing)"
fi

# Test server connectivity
if ping -c 1 -W 3 "$SERVER_IP" >/dev/null 2>&1; then
    print_status "OK" "Can reach server IP ($SERVER_IP) from this machine"
else
    print_status "WARN" "Cannot reach server IP ($SERVER_IP) from this machine"
fi

echo ""
echo -e "${GREEN}Validation complete!${NC}"
echo ""
echo "If you see any failures above, check the logs with:"
echo "  • kubectl logs -n <namespace> <pod-name>"
echo "  • sudo journalctl -u k3s -f"
echo ""
