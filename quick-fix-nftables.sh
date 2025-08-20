#!/bin/bash

# quick-fix-nftables.sh
# Simple script to quickly fix K3s nftables networking issues

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (use sudo)"
    exit 1
fi

log "Quick-fixing K3s nftables networking issues..."

# Backup current rules
backup_file="/tmp/nftables-backup-$(date +%Y%m%d-%H%M%S).nft"
log "Backing up current rules to $backup_file"
nft list ruleset > "$backup_file"

# Create the fixed nftables rules
log "Creating fixed nftables rules..."
cat > /etc/nftables.d/k3s.nft << 'EOF'
table inet k3s {
  set cluster_cidrs {
    type ipv4_addr
    flags interval
    elements = {
      10.42.0.0/16,    # K3s pod CIDR
      10.43.0.0/16,    # K3s service CIDR
      10.0.0.0/24      # Local network
    }
  }

  set k8s_ports {
    type inet_service
    elements = {
      6443,     # Kubernetes API
      10250,    # Kubelet API (CRITICAL!)
      2379,     # etcd
      2380,     # etcd peer
      7472,     # MetalLB
      9443      # MetalLB webhook
    }
  }

  chain input {
    type filter hook input priority 0;
    policy drop;

    iif lo accept
    ct state established,related accept

    tcp dport 22 accept
    meta l4proto { icmp, ipv6-icmp } accept

    # Essential K8s ports
    tcp dport @k8s_ports accept

    # DNS
    tcp dport { 53, 5353 } accept
    udp dport { 53, 5353 } accept

    # Web services
    tcp dport { 80, 443 } accept

    # Flannel VXLAN
    udp dport 8472 accept

    # NodePort range
    tcp dport 30000-32767 accept
    udp dport 30000-32767 accept

    # Allow cluster traffic
    ip saddr @cluster_cidrs accept
    ip daddr @cluster_cidrs accept
  }

  chain forward {
    type filter hook forward priority 0;
    policy drop;

    ct state established,related accept

    # Allow cluster forwarding
    ip saddr @cluster_cidrs accept
    ip daddr @cluster_cidrs accept

    # Container interfaces
    iifname { "cni*", "flannel*", "veth*", "docker*", "br-*" } accept
    oifname { "cni*", "flannel*", "veth*", "docker*", "br-*" } accept

    udp dport 8472 accept
  }

  chain output {
    type filter hook output priority 0;
    policy accept;
  }

  chain nat_postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr { 10.42.0.0/16, 10.43.0.0/16 } oifname != { "cni*", "flannel*", "veth*" } masquerade
  }

  chain nat_prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    accept
  }
}
EOF

# Restart nftables
log "Restarting nftables service..."
if rc-service nftables restart; then
    success "nftables restarted successfully"
else
    error "Failed to restart nftables"
    exit 1
fi

# Restart k3s to ensure clean state
log "Restarting k3s service..."
if rc-service k3s restart; then
    success "k3s restarted successfully"
else
    error "Failed to restart k3s"
    exit 1
fi

# Wait for services to come up
log "Waiting for services to stabilize..."
sleep 15

# Quick status check
log "Current pod status:"
kubectl get pods -A | head -10

success "Quick fix applied!"
echo ""
echo "Monitor pod recovery with: watch kubectl get pods -A"
echo "Backup saved to: $backup_file"
echo ""
echo "If issues persist, check logs with:"
echo "  kubectl logs -n kube-system <pod-name>"
echo "  journalctl -u k3s -f"
