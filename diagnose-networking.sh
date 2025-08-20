#!/bin/bash

# diagnose-networking.sh
# Comprehensive diagnostic script for K3s networking issues

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_section() { echo -e "${CYAN}[SECTION]${NC} $1"; echo "=========================================="; }

# Function to run command and show output
run_cmd() {
    local desc="$1"
    local cmd="$2"
    log_info "$desc"
    echo "Command: $cmd"
    echo "---"
    eval "$cmd" || echo "Command failed or not available"
    echo
}

# Check if running as root
check_privileges() {
    log_section "PRIVILEGE CHECK"
    if [[ $EUID -eq 0 ]]; then
        log_success "Running as root - full diagnostic available"
    else
        log_warning "Not running as root - some checks may be limited"
    fi
    echo
}

# System information
system_info() {
    log_section "SYSTEM INFORMATION"
    run_cmd "OS Information" "cat /etc/os-release"
    run_cmd "Kernel Version" "uname -a"
    run_cmd "Uptime" "uptime"
    run_cmd "Memory Usage" "free -h"
}

# Check all firewall systems
check_firewalls() {
    log_section "FIREWALL STATUS"

    # Check nftables
    log_info "Checking nftables..."
    if command -v nft >/dev/null 2>&1; then
        log_success "nftables is installed"

        if rc-service nftables status >/dev/null 2>&1; then
            log_success "nftables service is running"
        else
            log_warning "nftables service is not running"
        fi

        # Show current nftables rules
        run_cmd "Current nftables ruleset" "nft list ruleset"
    else
        log_error "nftables is not installed"
    fi

    # Check iptables
    log_info "Checking iptables..."
    if command -v iptables >/dev/null 2>&1; then
        log_success "iptables is available"
        run_cmd "iptables INPUT rules" "iptables -L INPUT -v -n"
        run_cmd "iptables FORWARD rules" "iptables -L FORWARD -v -n"
        run_cmd "iptables NAT rules" "iptables -t nat -L -v -n"
        run_cmd "iptables MANGLE rules" "iptables -t mangle -L -v -n"
    else
        log_warning "iptables not available"
    fi

    # Check Alpine firewall
    log_info "Checking Alpine awall..."
    if command -v awall >/dev/null 2>&1; then
        log_warning "awall (Alpine firewall) is installed - might conflict"
        run_cmd "awall status" "awall list"
    else
        log_success "awall not found - good"
    fi

    # Check UFW
    if command -v ufw >/dev/null 2>&1; then
        log_warning "UFW detected"
        run_cmd "UFW status" "ufw status verbose"
    fi
}

# Network configuration
check_network() {
    log_section "NETWORK CONFIGURATION"

    run_cmd "Network Interfaces" "ip addr show"
    run_cmd "Routing Table" "ip route show"
    run_cmd "Network Namespaces" "ip netns list"

    # Check if CNI interfaces exist
    log_info "Checking for CNI interfaces..."
    ip link show | grep -E "(cni|flannel|veth)" || log_warning "No CNI interfaces found"

    # Bridge information
    if command -v brctl >/dev/null 2>&1; then
        run_cmd "Bridge Information" "brctl show"
    fi
}

# Process and port information
check_processes() {
    log_section "PROCESS AND PORT STATUS"

    run_cmd "Processes listening on ports" "netstat -tlnp || ss -tlnp"
    run_cmd "Kubernetes processes" "ps aux | grep -E '(k3s|kube|containerd)'"

    # Check specific important ports
    local important_ports=(22 53 80 443 2379 2380 5353 6443 7472 8472 9443 10250 10256)
    log_info "Checking important ports..."
    for port in "${important_ports[@]}"; do
        if netstat -tln | grep -q ":$port "; then
            log_success "Port $port is listening"
        else
            log_warning "Port $port is not listening"
        fi
    done
    echo
}

# Kubernetes cluster status
check_kubernetes() {
    log_section "KUBERNETES STATUS"

    if command -v kubectl >/dev/null 2>&1; then
        run_cmd "Cluster Info" "kubectl cluster-info"
        run_cmd "Node Status" "kubectl get nodes -o wide"
        run_cmd "Pod Status (all namespaces)" "kubectl get pods -A -o wide"
        run_cmd "Service Status" "kubectl get services -A -o wide"
        run_cmd "Endpoints" "kubectl get endpoints -A"

        # Check kube-proxy configuration
        run_cmd "Kube-proxy ConfigMap" "kubectl get configmap kube-proxy-config -n kube-system -o yaml"

        # Check if kube-proxy is running
        run_cmd "Kube-proxy status" "kubectl get pods -n kube-system -l k8s-app=kube-proxy"

    else
        log_error "kubectl not available"
    fi
}

# Kernel modules and system settings
check_kernel() {
    log_section "KERNEL CONFIGURATION"

    # Check loaded modules
    log_info "Checking required kernel modules..."
    local required_modules=(br_netfilter nf_conntrack nf_nat nf_tables overlay xt_REDIRECT xt_owner)
    for module in "${required_modules[@]}"; do
        if lsmod | grep -q "^$module"; then
            log_success "Module $module is loaded"
        else
            log_warning "Module $module is not loaded"
        fi
    done

    # Check sysctl settings
    log_info "Checking sysctl settings..."
    local sysctl_settings=(
        "net.bridge.bridge-nf-call-iptables"
        "net.bridge.bridge-nf-call-ip6tables"
        "net.ipv4.ip_forward"
        "net.ipv6.conf.all.forwarding"
    )

    for setting in "${sysctl_settings[@]}"; do
        local value=$(sysctl -n "$setting" 2>/dev/null || echo "not found")
        if [[ "$value" == "1" ]]; then
            log_success "$setting = $value"
        else
            log_warning "$setting = $value (should be 1)"
        fi
    done
}

# Test connectivity
test_connectivity() {
    log_section "CONNECTIVITY TESTS"

    # Test local connectivity
    run_cmd "Ping localhost" "ping -c 2 127.0.0.1"
    run_cmd "Ping gateway" "ping -c 2 \$(ip route | grep default | awk '{print \$3}')"

    # Test Kubernetes API connectivity
    log_info "Testing Kubernetes API connectivity..."
    if kubectl get --raw=/healthz >/dev/null 2>&1; then
        log_success "Kubernetes API is reachable"
    else
        log_error "Cannot reach Kubernetes API"
    fi

    # Test service connectivity from inside cluster
    if command -v kubectl >/dev/null 2>&1; then
        log_info "Testing service connectivity from within cluster..."
        kubectl run test-connectivity --image=alpine:latest --rm -it --restart=Never -- /bin/sh -c "
            apk add --no-cache curl >/dev/null 2>&1
            echo 'Testing connectivity to kubernetes.default.svc.cluster.local...'
            curl -k -m 5 https://kubernetes.default.svc.cluster.local/healthz || echo 'Failed to reach kubernetes service'
            echo 'Testing DNS resolution...'
            nslookup kubernetes.default.svc.cluster.local || echo 'DNS resolution failed'
        " 2>/dev/null || log_error "Could not create test pod"
    fi
}

# Analyze logs
check_logs() {
    log_section "LOG ANALYSIS"

    if command -v journalctl >/dev/null 2>&1; then
        run_cmd "K3s service logs (last 50 lines)" "journalctl -u k3s --no-pager -n 50"
        run_cmd "Recent firewall-related logs" "journalctl --no-pager -n 100 | grep -i -E '(nft|iptables|firewall|drop|reject)' || echo 'No firewall logs found'"
    else
        log_warning "journalctl not available, checking alternative log locations"
        run_cmd "System logs" "tail -n 50 /var/log/messages || tail -n 50 /var/log/syslog || echo 'No system logs found'"
    fi
}

# Check nftables configuration files
check_nftables_config() {
    log_section "NFTABLES CONFIGURATION FILES"

    run_cmd "Main nftables config" "cat /etc/nftables.conf"

    if [[ -d "/etc/nftables.d" ]]; then
        run_cmd "nftables.d directory contents" "ls -la /etc/nftables.d/"
        for file in /etc/nftables.d/*.nft; do
            if [[ -f "$file" ]]; then
                run_cmd "Content of $file" "cat '$file'"
            fi
        done
    else
        log_warning "/etc/nftables.d directory does not exist"
    fi
}

# Summary and recommendations
generate_summary() {
    log_section "DIAGNOSTIC SUMMARY AND RECOMMENDATIONS"

    echo "Based on the diagnostic results above, here are the key findings:"
    echo

    # Check if pods can't reach services
    if kubectl get pods -A 2>/dev/null | grep -q "CrashLoopBackOff\|Error\|Init:0/"; then
        log_error "ISSUE: Pods are failing to start or are in error states"
        echo "  This suggests networking problems preventing pod-to-service communication"
    fi

    # Check if nftables is blocking traffic
    if nft list ruleset 2>/dev/null | grep -q "policy drop"; then
        log_warning "POTENTIAL ISSUE: nftables has drop policies that may be too restrictive"
        echo "  The forward chain policy might be blocking kube-proxy's service routing"
    fi

    # Check for iptables conflicts
    if iptables -L 2>/dev/null | grep -q "Chain"; then
        log_warning "POTENTIAL CONFLICT: iptables rules detected alongside nftables"
        echo "  This can cause conflicts in packet processing"
    fi

    echo
    echo "RECOMMENDED ACTIONS:"
    echo "1. Ensure nftables forward chain has policy accept or priority < 0"
    echo "2. Verify that service CIDR (10.43.0.0/16) traffic is allowed"
    echo "3. Check if kube-proxy is functioning correctly"
    echo "4. Ensure no conflicting firewall systems are active"
    echo "5. Verify kernel modules and sysctl settings are correct"
}

# Main execution
main() {
    echo "============================================================"
    echo "    K3s Networking Diagnostic Tool"
    echo "============================================================"
    echo "This script will analyze the current networking and firewall"
    echo "configuration to identify issues with Kubernetes connectivity"
    echo "============================================================"
    echo

    check_privileges
    system_info
    check_firewalls
    check_network
    check_processes
    check_kubernetes
    check_kernel
    check_nftables_config
    test_connectivity
    check_logs
    generate_summary

    echo
    log_success "Diagnostic complete!"
    log_info "Save this output and review the DIAGNOSTIC SUMMARY section for next steps"
}

# Run main function
main "$@"
