#!/bin/bash

# Port conflict checking script for Pi-hole deployment
# This script helps diagnose port conflicts that prevent Pi-hole from starting

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

echo "============================================="
echo "  Pi-hole Port Conflict Diagnostic Script"
echo "============================================="
echo ""

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    print_status "WARN" "Running as root. Some checks may not work properly for user services."
fi

# Function to run commands on remote server if SSH config exists
run_remote() {
    local cmd="$1"
    if [ -f "ssh_config" ] && grep -q "Host homelab-server" ssh_config 2>/dev/null; then
        ssh -F ssh_config homelab-server "$cmd" 2>/dev/null || echo "SSH command failed"
    else
        eval "$cmd" 2>/dev/null || echo "Local command failed"
    fi
}

echo "1. CHECKING PORT 53 USAGE"
echo "=========================="

# Check what's using port 53
port53_tcp=$(run_remote "netstat -tulnp 2>/dev/null | grep ':53 ' | grep tcp" || echo "")
port53_udp=$(run_remote "netstat -tulnp 2>/dev/null | grep ':53 ' | grep udp" || echo "")

if [ -n "$port53_tcp" ] || [ -n "$port53_udp" ]; then
    print_status "ERROR" "Port 53 is in use:"
    if [ -n "$port53_tcp" ]; then
        echo "  TCP: $port53_tcp"
    fi
    if [ -n "$port53_udp" ]; then
        echo "  UDP: $port53_udp"
    fi
else
    print_status "OK" "Port 53 is available"
fi

echo ""
echo "2. CHECKING SYSTEM DNS SERVICES"
echo "================================"

# Check systemd-resolved
resolved_status=$(run_remote "systemctl is-active systemd-resolved 2>/dev/null" || echo "inactive")
if [ "$resolved_status" = "active" ]; then
    print_status "WARN" "systemd-resolved is active (may conflict with Pi-hole)"
    resolved_config=$(run_remote "grep -E '^DNS=|^DNSStubListener=' /etc/systemd/resolved.conf 2>/dev/null" || echo "")
    if [ -n "$resolved_config" ]; then
        echo "  Current config: $resolved_config"
    fi
else
    print_status "OK" "systemd-resolved is not active"
fi

# Check dnsmasq
dnsmasq_status=$(run_remote "systemctl is-active dnsmasq 2>/dev/null" || echo "inactive")
if [ "$dnsmasq_status" = "active" ]; then
    print_status "WARN" "dnsmasq is active (may conflict with Pi-hole)"
else
    print_status "OK" "dnsmasq is not active"
fi

echo ""
echo "3. CHECKING K3S AND KUBERNETES SERVICES"
echo "========================================"

# Check k3s status
k3s_status=$(run_remote "systemctl is-active k3s 2>/dev/null" || echo "inactive")
if [ "$k3s_status" = "active" ]; then
    print_status "OK" "k3s is active"

    # Check CoreDNS
    coredns_pods=$(run_remote "kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null" || echo "")
    if [ -n "$coredns_pods" ]; then
        print_status "INFO" "CoreDNS pods found:"
        echo "$coredns_pods" | sed 's/^/  /'
    fi

    # Check Pi-hole namespace
    pihole_ns=$(run_remote "kubectl get namespace pihole --no-headers 2>/dev/null" || echo "")
    if [ -n "$pihole_ns" ]; then
        print_status "OK" "Pi-hole namespace exists"

        # Check Pi-hole pods
        pihole_pods=$(run_remote "kubectl get pods -n pihole --no-headers 2>/dev/null" || echo "")
        if [ -n "$pihole_pods" ]; then
            print_status "INFO" "Pi-hole pods:"
            echo "$pihole_pods" | sed 's/^/  /'
        else
            print_status "WARN" "No Pi-hole pods found"
        fi

        # Check Pi-hole service
        pihole_svc=$(run_remote "kubectl get service pihole-service -n pihole --no-headers 2>/dev/null" || echo "")
        if [ -n "$pihole_svc" ]; then
            print_status "INFO" "Pi-hole service:"
            echo "$pihole_svc" | sed 's/^/  /'
        else
            print_status "WARN" "Pi-hole service not found"
        fi
    else
        print_status "WARN" "Pi-hole namespace not found"
    fi

else
    print_status "ERROR" "k3s is not active"
fi

echo ""
echo "4. CHECKING METALLB STATUS"
echo "=========================="

metallb_pods=$(run_remote "kubectl get pods -n metallb-system --no-headers 2>/dev/null" || echo "")
if [ -n "$metallb_pods" ]; then
    print_status "OK" "MetalLB pods found:"
    echo "$metallb_pods" | sed 's/^/  /'
else
    print_status "WARN" "MetalLB pods not found"
fi

echo ""
echo "5. CHECKING SPECIFIC Pi-hole PORTS"
echo "==================================="

# Check Pi-hole specific ports
pihole_web=$(run_remote "netstat -tulnp 2>/dev/null | grep ':80 '" || echo "")
if [ -n "$pihole_web" ]; then
    print_status "INFO" "Port 80 usage: $pihole_web"
fi

pihole_dns=$(run_remote "netstat -tulnp 2>/dev/null | grep ':5353 '" || echo "")
if [ -n "$pihole_dns" ]; then
    print_status "OK" "Pi-hole DNS port 5353 is in use: $pihole_dns"
else
    print_status "INFO" "Port 5353 is available"
fi

echo ""
echo "6. RECOMMENDATIONS"
echo "=================="

if [ -n "$port53_tcp" ] || [ -n "$port53_udp" ]; then
    print_status "INFO" "Port 53 conflicts detected. Solutions:"
    echo "  1. Pi-hole is configured to use port 5353 externally (recommended)"
    echo "  2. Stop conflicting services:"
    echo "     sudo systemctl stop systemd-resolved"
    echo "     sudo systemctl disable systemd-resolved"
    echo "  3. Configure systemd-resolved to not use port 53:"
    echo "     sudo sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf"
    echo "     sudo systemctl restart systemd-resolved"
fi

if [ "$k3s_status" != "active" ]; then
    print_status "INFO" "Start k3s service:"
    echo "  sudo systemctl start k3s"
    echo "  sudo systemctl enable k3s"
fi

if [ -z "$pihole_ns" ]; then
    print_status "INFO" "Deploy Pi-hole using the Ansible playbook:"
    echo "  ansible-playbook -i inventory/hosts.ini playbook.yaml"
fi

echo ""
print_status "INFO" "To test Pi-hole DNS (once running):"
echo "  dig @10.0.0.101 -p 5353 google.com"
echo "  nslookup google.com 10.0.0.101  # (if using standard port 53)"

echo ""
echo "============================================="
echo "  Port conflict check complete!"
echo "============================================="
