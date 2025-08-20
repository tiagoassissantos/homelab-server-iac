# Pi-hole Port Conflict Fix

## Problem Description

When deploying Pi-hole in the k3s cluster, you may encounter the following error:

```
0/1 nodes are available: 1 node(s) didn't have free ports for the requested pod ports. 
preemption: 0/1 nodes are available: 1 node(s) didn't have free ports for the requested pod ports.
```

This occurs because Pi-hole tries to bind to port 53 (DNS) on the host, but this port is already in use by:
- `systemd-resolved` (Alpine Linux system DNS resolver)
- CoreDNS (k3s internal DNS service)
- Other DNS services running on the host

## Solution Overview

The fix changes Pi-hole's external service port from `53` to `5353` while keeping the internal container port as `53`. This avoids conflicts with host services while maintaining full Pi-hole functionality.

### Changes Made:

1. **Service Configuration**: External DNS ports changed from `53` to `5353`
2. **CoreDNS Configuration**: Updated to forward DNS queries to Pi-hole on port `5353`
3. **Configuration Variables**: Added `pihole_dns_port: "5353"` to group variables
4. **Documentation**: Updated README and troubleshooting guides

## Quick Fix Deployment

### Step 1: Apply the Updated Configuration

If you haven't pulled the latest changes:

```bash
# Pull the updated playbooks (if using git)
git pull origin main

# Or verify the changes are in place
grep -n "pihole_dns_port" homelab_server_iac/group_vars/all.yaml
```

### Step 2: Clean Up Existing Pi-hole Resources (if needed)

```bash
# Delete existing Pi-hole resources that may be stuck
kubectl delete namespace pihole --force --grace-period=0

# Or just delete the specific resources
kubectl delete deployment pihole -n pihole --force --grace-period=0
kubectl delete service pihole-service -n pihole --force --grace-period=0
kubectl delete pods -n pihole --all --force --grace-period=0
```

### Step 3: Redeploy Pi-hole

```bash
# Run the full playbook or just the Pi-hole section
ansible-playbook -i inventory/hosts.ini playbook.yaml

# Or run with more verbose output if you encounter issues
ansible-playbook -i inventory/hosts.ini playbook.yaml -v
```

### Step 4: Verify the Fix

```bash
# Check that Pi-hole pods are running
kubectl get pods -n pihole

# Verify service configuration
kubectl get service pihole-service -n pihole -o yaml

# Check that the service is using port 5353
kubectl get service pihole-service -n pihole

# Test DNS resolution on the new port
dig @10.0.0.101 -p 5353 google.com
```

## Verification Steps

### 1. Check Port Usage

Run the provided diagnostic script:

```bash
./check-ports.sh
```

### 2. Manual Port Verification

```bash
# Check what's using port 53 on the host
sudo netstat -tulnp | grep :53

# Check what's using port 5353
sudo netstat -tulnp | grep :5353

# Verify Pi-hole service ports
kubectl describe service pihole-service -n pihole
```

### 3. Test DNS Functionality

```bash
# Test Pi-hole DNS on port 5353
dig @10.0.0.101 -p 5353 google.com
dig @10.0.0.101 -p 5353 facebook.com

# Check if Pi-hole is blocking ads (should return NXDOMAIN or 0.0.0.0)
dig @10.0.0.101 -p 5353 doubleclick.net
```

### 4. Verify CoreDNS Integration

```bash
# Check CoreDNS configuration
kubectl get configmap coredns -n kube-system -o yaml

# The forward line should show: forward . 10.0.0.101:5353

# Test cluster DNS resolution
kubectl run test-dns --image=busybox --rm -it -- nslookup google.com
```

## Configuration Details

### Updated Variables (group_vars/all.yaml)

```yaml
# === Pi-hole ===
pihole_namespace: "pihole"
pihole_lb_ip: "10.0.0.101"
pihole_dns_port: "5353"  # <-- New variable to avoid port conflicts
pihole_password: "5JdN&%2Gq7s"
pihole_dns1: "8.8.8.8"
pihole_dns2: "1.1.1.1"
```

### Service Port Mapping

- **External Port**: `5353` (accessible from outside the cluster)
- **Internal Port**: `53` (inside the Pi-hole container)
- **Web Interface**: `80` (unchanged)

## Troubleshooting

### Pi-hole Pods Still Won't Start

```bash
# Check node events
kubectl get events --all-namespaces --sort-by=.metadata.creationTimestamp

# Check systemd-resolved status
sudo systemctl status systemd-resolved

# Temporarily stop systemd-resolved if needed
sudo systemctl stop systemd-resolved
sudo systemctl disable systemd-resolved
```

### DNS Resolution Not Working

```bash
# Check if CoreDNS is forwarding correctly
kubectl logs -n kube-system deployment/coredns

# Restart CoreDNS if needed
kubectl rollout restart deployment/coredns -n kube-system

# Check Pi-hole logs
kubectl logs -n pihole deployment/pihole
```

### MetalLB Issues

```bash
# Check MetalLB status
kubectl get pods -n metallb-system

# Check if IP is assigned to service
kubectl get service pihole-service -n pihole

# Check MetalLB logs
kubectl logs -n metallb-system -l app=metallb
```

## Client Configuration

Since Pi-hole now runs on port `5353`, you have two options for client DNS configuration:

### Option 1: Use Standard Port 53 (Recommended)

Configure your clients to use `10.0.0.101` as DNS server. The CoreDNS service will automatically forward requests to Pi-hole on port `5353`.

### Option 2: Direct Port 5353 Access

If you want to bypass CoreDNS, configure clients to use:
- **DNS Server**: `10.0.0.101`
- **Port**: `5353`

Note: Most devices don't support custom DNS ports, so Option 1 is recommended.

## Rollback Instructions

If you need to revert to the original configuration:

```bash
# 1. Stop and disable conflicting services first
sudo systemctl stop systemd-resolved
sudo systemctl disable systemd-resolved

# 2. Update group_vars/all.yaml to use port 53
sed -i 's/pihole_dns_port: "5353"/pihole_dns_port: "53"/' group_vars/all.yaml

# 3. Redeploy
kubectl delete namespace pihole --force
ansible-playbook -i inventory/hosts.ini playbook.yaml
```

## Support

If you continue to experience issues after applying this fix:

1. Run `./check-ports.sh` and review the output
2. Check the troubleshooting section in `README.md`
3. Review k3s and Pi-hole logs for specific error messages
4. Consider using a different external port (e.g., `5054`) if `5353` conflicts with other services

The key advantage of this solution is that it maintains full Pi-hole functionality while avoiding system-level port conflicts that prevent deployment.