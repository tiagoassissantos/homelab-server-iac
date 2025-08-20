#!/bin/bash

# fix-k3s-nftables.sh
# Script to diagnose and fix Kubernetes networking issues with nftables

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Check if nftables is installed and running
check_nftables() {
    log_info "Checking nftables status..."

    if ! command -v nft &> /dev/null; then
        log_error "nftables is not installed"
        return 1
    fi

    if ! rc-service nftables status &> /dev/null; then
        log_warning "nftables service is not running"
        log_info "Starting nftables service..."
        rc-service nftables start
    fi

    log_success "nftables is running"
    return 0
}

# Backup current nftables rules
backup_rules() {
    local backup_file="/tmp/nftables-backup-$(date +%Y%m%d-%H%M%S).nft"
    log_info "Backing up current nftables rules to $backup_file"
    nft list ruleset > "$backup_file"
    log_success "Rules backed up to $backup_file"
    echo "$backup_file"
}

# Check for essential Kubernetes ports in nftables rules
check_k8s_ports() {
    log_info "Checking for essential Kubernetes ports in nftables rules..."

    local missing_ports=()
    local required_ports=(6443 10250 8472 2379 2380)

    for port in "${required_ports[@]}"; do
        if ! nft list ruleset | grep -q "dport $port\|dport.*$port\|@.*$port"; then
            missing_ports+=("$port")
        fi
    done

    if [[ ${#missing_ports[@]} -gt 0 ]]; then
        log_warning "Missing ports in nftables rules: ${missing_ports[*]}"
        return 1
    else
        log_success "All essential Kubernetes ports found in rules"
        return 0
    fi
}

# Apply fixed nftables rules for K3s
apply_fixed_rules() {
    log_info "Applying fixed nftables rules for K3s..."

    cat > /etc/nftables.d/k3s.nft << 'EOF'
table inet k3s {
  # Define sets for better rule organization
  set cluster_cidrs {
    type ipv4_addr
    flags interval
    elements = {
      10.42.0.0/16,    # K3s pod CIDR
      10.43.0.0/16,    # K3s service CIDR
      10.0.0.0/24      # Local network
    }
  }

  set k8s_api_ports {
    type inet_service
    elements = {
      6443,     # Kubernetes API server
      2379,     # etcd client requests
      2380,     # etcd peer communication
      10250,    # Kubelet API (CRITICAL for metrics-server)
      10251,    # kube-scheduler
      10252,    # kube-controller-manager
      10256     # kube-proxy health check
    }
  }

  chain input {
    type filter hook input priority 0;
    policy drop;

    # Allow loopback
    iif lo accept

    # Allow established and related connections
    ct state established,related accept

    # Allow SSH
    tcp dport 22 accept

    # Allow ICMP/ICMPv6 (ping, path MTU discovery, etc.)
    meta l4proto { icmp, ipv6-icmp } accept

    # Allow Kubernetes API ports
    tcp dport @k8s_api_ports accept

    # Allow MetalLB controller metrics/webhook
    tcp dport { 7472, 9443 } accept

    # Allow DNS queries
    tcp dport { 53, 5353 } accept
    udp dport { 53, 5353 } accept

    # Allow HTTP/HTTPS for web services
    tcp dport { 80, 443 } accept

    # Allow Flannel VXLAN (K3s default CNI)
    udp dport 8472 accept

    # Allow NodePort range
    tcp dport 30000-32767 accept
    udp dport 30000-32767 accept

    # Allow traffic from cluster networks
    ip saddr @cluster_cidrs accept
    ip daddr @cluster_cidrs accept
  }

  chain forward {
    type filter hook forward priority 0;
    policy drop;

    # Allow established and related connections
    ct state established,related accept

    # Allow all forwarding for cluster networks (pods, services)
    ip saddr @cluster_cidrs accept
    ip daddr @cluster_cidrs accept

    # Allow container interface forwarding
    iifname { "cni*", "flannel*", "veth*", "docker*" } accept
    oifname { "cni*", "flannel*", "veth*", "docker*" } accept

    # Allow bridge forwarding (for container networking)
    iifname "br-*" accept
    oifname "br-*" accept

    # Allow Flannel VXLAN forwarding
    udp dport 8472 accept
  }

  chain output {
    type filter hook output priority 0;
    policy accept;
  }

  # NAT rules for container networking
  chain nat_postrouting {
    type nat hook postrouting priority srcnat; policy accept;

    # Masquerade traffic from pods going to external networks
    ip saddr { 10.42.0.0/16, 10.43.0.0/16 } oifname != { "cni*", "flannel*", "veth*" } masquerade
  }

  chain nat_prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    accept
  }
}
EOF

    log_success "Fixed nftables rules written to /etc/nftables.d/k3s.nft"
}

# Reload nftables rules
reload_nftables() {
    log_info "Reloading nftables rules..."

    if rc-service nftables restart; then
        log_success "nftables rules reloaded successfully"
        return 0
    else
        log_error "Failed to reload nftables rules"
        return 1
    fi
}

# Test connectivity to key services
test_connectivity() {
    log_info "Testing connectivity to key Kubernetes services..."

    # Test kubelet API (port 10250)
    if timeout 5 nc -z localhost 10250; then
        log_success "Kubelet API (port 10250) is accessible"
    else
        log_warning "Kubelet API (port 10250) is not accessible"
    fi

    # Test Kubernetes API (port 6443)
    if timeout 5 nc -z localhost 6443; then
        log_success "Kubernetes API (port 6443) is accessible"
    else
        log_warning "Kubernetes API (port 6443) is not accessible"
    fi

    # Test if we can reach pod networks
    local pod_ip=$(kubectl get pods -A -o wide | grep -E "(coredns|metrics-server)" | head -1 | awk '{print $7}')
    if [[ -n "$pod_ip" ]]; then
        if timeout 5 ping -c 1 "$pod_ip" > /dev/null 2>&1; then
            log_success "Pod network ($pod_ip) is reachable"
        else
            log_warning "Pod network ($pod_ip) is not reachable"
        fi
    fi
}

# Check pod status after fixes
check_pod_status() {
    log_info "Checking pod status..."

    # Wait a bit for pods to recover
    sleep 10

    local failed_pods=$(kubectl get pods -A --no-headers | grep -E "(CrashLoopBackOff|Error|Init:0/)" | wc -l)

    if [[ $failed_pods -eq 0 ]]; then
        log_success "All pods are running successfully"
    else
        log_warning "$failed_pods pods are still in failed state"
        log_info "Pod status:"
        kubectl get pods -A | grep -E "(READY|CrashLoopBackOff|Error|Init:0/)"
    fi
}

# Display current nftables rules for debugging
show_current_rules() {
    log_info "Current nftables rules:"
    echo "==================="
    nft list ruleset
    echo "==================="
}

# Main function
main() {
    echo "=================================================="
    echo "    K3s nftables Networking Fix Script"
    echo "=================================================="
    echo

    check_root

    # Show current status
    log_info "Current pod status:"
    kubectl get pods -A | head -10
    echo

    # Backup current rules
    backup_file=$(backup_rules)
    echo

    # Check nftables
    if ! check_nftables; then
        log_error "nftables is not properly set up"
        exit 1
    fi
    echo

    # Check for missing ports
    if ! check_k8s_ports; then
        log_warning "Some essential Kubernetes ports are missing from nftables rules"
    fi
    echo

    # Apply fixes
    log_info "Applying nftables fixes..."
    apply_fixed_rules
    echo

    # Reload rules
    if ! reload_nftables; then
        log_error "Failed to reload nftables. Rolling back..."
        nft flush ruleset
        nft -f "$backup_file"
        exit 1
    fi
    echo

    # Test connectivity
    test_connectivity
    echo

    # Wait and check pod status
    log_info "Waiting for pods to recover..."
    sleep 30
    check_pod_status
    echo

    log_success "nftables fix complete!"
    log_info "If pods are still failing, try restarting the k3s service:"
    log_info "  sudo rc-service k3s restart"
    log_info ""
    log_info "To monitor pod recovery:"
    log_info "  watch kubectl get pods -A"
    log_info ""
    log_info "Backup of original rules saved to: $backup_file"
}

# Handle script arguments
case "${1:-}" in
    --show-rules)
        show_current_rules
        exit 0
        ;;
    --test-only)
        check_root
        test_connectivity
        check_pod_status
        exit 0
        ;;
    --backup-only)
        check_root
        backup_rules
        exit 0
        ;;
    --help|-h)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --show-rules     Display current nftables rules"
        echo "  --test-only      Only test connectivity, don't apply changes"
        echo "  --backup-only    Only backup current rules"
        echo "  --help, -h       Show this help message"
        echo ""
        echo "Run without arguments to perform full diagnosis and fix."
        exit 0
        ;;
    "")
        main
        ;;
    *)
        log_error "Unknown option: $1"
        log_info "Use --help for usage information"
        exit 1
        ;;
esac
