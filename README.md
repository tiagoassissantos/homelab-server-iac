# Homelab Server Infrastructure as Code

This Ansible playbook configures an Alpine Linux server (e.g., v3.22) running on ARM64 with a complete k3s Kubernetes cluster. It establishes a GitOps-ready platform with Argo CD, Argo Workflows, a private Docker Registry, and other core services.

## Features

- ✅ **Shell Setup**: Installs and configures zsh with oh-my-zsh
- ✅ **k3s Kubernetes**: Single-node k3s cluster with Traefik ingress
- ✅ **MetalLB**: Load balancer for bare metal Kubernetes
- ✅ **Argo CD**: Declarative, GitOps continuous delivery tool.
- ✅ **Argo Workflows**: Workflow orchestration for CI and other tasks.
- ✅ **Pi-hole**: Network-wide ad blocking and DNS server
- ✅ **Docker Registry**: Private container registry for project images
- ✅ **Argo Workflows**: Workflow orchestration with HTTPS access
- ✅ **cert-manager**: Automatic TLS certificate management
- ✅ **Firewall**: Properly configured iptables for k3s

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Alpine Linux Server                      │
│  ┌────────────────────────────────────────────────────────┐ │
│  │                   k3s GitOps Platform                  │ │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐ │ │
│  │  │   Pi-hole   │  │   Argo CD   │  │   cert-manager  │ │ │
│  │  │ (DNS Server)│  │ (GitOps CD) │  │  (TLS Certs)    │ │ │
│  │  └─────────────┘  └─────────────┘  └─────────────────┘ │ │
│  │  ┌─────────────┐  ┌─────────────┐                     │ │
│  │  │ Docker      │  │    Argo     │                     │ │
│  │  │ Registry    │  │ Workflows   │                     │ │
│  │  └─────────────┘  └─────────────┘                     │ │
│  │  └─────────────┘  └─────────────┘  └─────────────────┘ │ │
│  │  ┌─────────────┐                                       │ │
│  │  │ Docker      │                                       │ │
│  │  │ Registry    │                                       │ │
│  │  └─────────────┘                                       │ │
│  │  ┌───────────────────────────────────────────────────┐ │ │
│  │  │              MetalLB Load Balancer                │ │ │
│  │  └───────────────────────────────────────────────────┘ │ │
│  │  ┌───────────────────────────────────────────────────┐ │ │
│  │  │                Traefik Ingress                    │ │ │
│  │  └───────────────────────────────────────────────────┘ │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

### Local Machine
- Ansible 2.9+ installed
- Python 3.6+ with pip
- SSH key-based access to the Alpine server

### Target Server
- Alpine Linux (e.g., v3.22) (ARM64)
- SSH access configured
- Internet connectivity
- Static IP address (recommended)

## Configuration

The main configuration is in `group_vars/all.yaml`. Key settings:

### Network Configuration
```yaml
# MetalLB IP range (adjust for your network)
metallb_address_pool: 10.0.0.101-10.0.0.250

# Pi-hole will get this specific IP (matches `group_vars/all.yaml`)
pihole_lb_ip: "10.0.0.250"

# Docker Registry will get this specific IP
registry_lb_ip: "10.0.0.248"

# Your domain (adjust as needed) — default in the repo
base_domain: "contdiscovery.lab"
```

### DNS Configuration
```yaml
# Pi-hole upstream DNS servers
pihole_dns1: "8.8.8.8"  # Google DNS
pihole_dns2: "1.1.1.1"  # Cloudflare DNS

# Pi-hole DNS port (using 5353 to avoid conflicts with host DNS)
pihole_dns_port: "5353"
```

### Docker Registry Configuration
```yaml
# Registry settings
registry_namespace: "registry"
registry_lb_ip: "10.0.0.248"
registry_host: "registry.contdiscovery.lab"
registry_storage_size: "20Gi"
```

### Security
```yaml
# Pi-hole admin password
# By default this repository generates a random password at playbook runtime
# (see `group_vars/all.yaml`: `pihole_password: "{{ lookup('password', '/dev/null length=16') }}").`
# To use a fixed password, override `pihole_password` in `group_vars` or store
# it securely with Ansible Vault.
# Example (NOT recommended to commit):
# pihole_password: "strong_password"

# TLS configuration
tls_mode: "selfsigned"  # or "letsencrypt"
tls_email: "your-email@example.com"
```

## Deployment

# Step 1: Setup Environment

```bash
# Clone or navigate to the project directory
cd homelab_server_iac

# Install required Ansible collections/roles listed in requirements.yml
ansible-galaxy collection install -r requirements.yml
# If roles are listed in the requirements file as roles:
ansible-galaxy role install -r requirements.yml

# (Optional) You can create a simple `setup.sh` wrapper if you prefer a single command.
```

### Step 2: Verify Connectivity

```bash
# Test SSH connection to your server
ansible -i inventory/hosts.ini masters -m ping

# Should return:
# k3s-1 | SUCCESS => {
#     "changed": false,
#     "ping": "pong"
# }
```

### Step 3: Deploy

```bash
# Run the complete deployment
ansible-playbook -i inventory/hosts.ini playbook.yaml

# Or run with verbose output for troubleshooting
ansible-playbook -i inventory/hosts.ini playbook.yaml -v

# To install only Docker Registry (after initial setup)
ansible-playbook -i inventory/hosts.ini playbook-registry.yaml
```

The deployment will take approximately 15-30 minutes depending on your internet connection.

## Post-Deployment

### Verify k3s Cluster

```bash
# SSH to your server
ssh <your_user>@<your_server_ip>

# Check cluster status
kubectl get nodes
kubectl get pods --all-namespaces

# Check services
kubectl get services --all-namespaces
```

### Access Services

#### Pi-hole Admin Interface
- **URL**: `http://10.0.0.250/admin` (or whatever `pihole_lb_ip` you set in `group_vars/all.yaml`)
- **Password**: As configured in `pihole_password` (by default a random password is generated at runtime)

#### Argo Workflows
- **URL**: `https://argo.contdiscovery.lab` (or `argo.{{ base_domain }}` depending on your configuration)
- **Note**: Add this domain to your local hosts file or configure DNS

#### Docker Registry
- **Internal URL**: `http://10.0.0.248:5000` (or whatever `registry_lb_ip` you set)
- **External URL**: `https://registry.contdiscovery.lab` (or `registry.{{ base_domain }}`)
- **Authentication**: Disabled (open access for simplicity)
- **Usage**:
  ```bash
  # Tag and push an image (no login required)
  docker tag my-app:latest 10.0.0.248:5000/my-app:latest
  docker push 10.0.0.248:5000/my-app:latest

  # Pull an image
  docker pull 10.0.0.248:5000/my-app:latest
  ```

> 📖 **For detailed Docker Registry usage, CI/CD integration, troubleshooting, and advanced configuration, see [REGISTRY_GUIDE.md](REGISTRY_GUIDE.md)**

### Configure DNS

To use Pi-hole as your network DNS (note: Pi-hole runs on port 5353):

1. **Router Configuration**: Set your router's DNS to `10.0.0.250` (or the `pihole_lb_ip` you've configured)
2. **Local Machine**: Update `/etc/resolv.conf` or network settings
3. **Test**: `nslookup google.com 10.0.0.250`

### Kubernetes Dashboard (Optional)

```bash
# Install Kubernetes dashboard
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml

# Create admin user
kubectl create serviceaccount dashboard-admin-sa
kubectl create clusterrolebinding dashboard-admin-sa --clusterrole=cluster-admin --serviceaccount=default:dashboard-admin-sa

# Get access token
kubectl get secret $(kubectl get serviceaccount dashboard-admin-sa -o jsonpath="{.secrets[0].name}") -o jsonpath="{.data.token}" | base64 --decode
```

## Troubleshooting

### Common Issues

#### 1. Connection Issues
```bash
# Check if SSH key is correctly configured
ssh -i ~/.ssh/id_ed25519 <your_user>@<your_server_ip>

# Verify inventory file
cat inventory/hosts.ini
```

#### 2. k3s Installation Fails
```bash
# Check if required ports are available
sudo netstat -tulpn | grep -E ':(6443|10250|2379|2380)'

# Check system resources
free -h
df -h
```

#### 3. Pi-hole Not Accessible
```bash
# Check MetalLB status
kubectl get pods -n metallb-system
kubectl get services -n pihole

# Check if IP is assigned
kubectl get service pihole-service -n pihole
```

#### 4. DNS Resolution Issues
```bash
# Test Pi-hole directly (note: Pi-hole DNS runs on port 5353)
dig @10.0.0.250 -p 5353 google.com

# Check coredns configuration
kubectl get configmap coredns -n kube-system -o yaml
```

#### 5. Pi-hole Port Conflict Issues

If you see errors like `didn't have free ports for the requested pod ports`, this means port 53 is already in use:

```bash
# Check what's using port 53
sudo netstat -tulnp | grep :53
sudo lsof -i :53

# Check if systemd-resolved is running
sudo systemctl status systemd-resolved

# If systemd-resolved is using port 53, you can:
# Option 1: Stop systemd-resolved (may affect system DNS)
sudo systemctl stop systemd-resolved
sudo systemctl disable systemd-resolved

# Option 2: Configure systemd-resolved to use different port
sudo sed -i 's/#DNS=/DNS=127.0.0.1/' /etc/systemd/resolved.conf
sudo sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf
sudo systemctl restart systemd-resolved

# Check Pi-hole service status
kubectl get pods -n pihole
kubectl describe pod -n pihole -l app=pihole

# Force delete stuck pods if needed
kubectl delete pod -n pihole --force --grace-period=0 -l app=pihole
```

**Note**: Pi-hole now runs on port 5353 externally to avoid conflicts with system DNS services.

#### 6. Docker Registry Issues

```bash
# Check registry pod status
kubectl get pods -n registry
kubectl logs -n registry deployment/registry

# Check registry service
kubectl get service -n registry registry-service

# Test registry connectivity
curl -k https://registry.contdiscovery.lab/v2/
# Should return: {}

# Check authentication
docker login 10.0.0.248:5000
# Use the credentials from deployment output
```

### Reset Cluster

If you need to start over:

```bash
# On the Alpine server
sudo /usr/local/bin/k3s-uninstall.sh

# Clean up any remaining files
sudo rm -rf /etc/rancher/k3s/
sudo rm -rf /var/lib/rancher/k3s/

# Re-run the playbook
ansible-playbook -i inventory/hosts.ini playbook.yaml
```

### Logs and Debugging

```bash
# k3s server logs
sudo journalctl -u k3s -f

# Pod logs
kubectl logs -n pihole deployment/pihole
kubectl logs -n argo deployment/argo-workflows-server

# Cluster events
kubectl get events --all-namespaces --sort-by=.metadata.creationTimestamp
```

## Customization

### Adding More Services

To add more services, create new tasks in the playbook:

```yaml
- name: Install new service
  kubernetes.core.helm:
    name: my-service
    chart_ref: repo/chart
    release_namespace: my-namespace
    create_namespace: true
    kubeconfig: "/home/{{ ansible_user }}/.kube/config"
```

### Using Docker Registry in Your Projects

1. **Build and push your project images**:
```bash
# Build your application
docker build -t my-app:v1.0.0 .

# Tag for your registry
docker tag my-app:v1.0.0 10.0.0.248:5000/my-app:v1.0.0

# Push (no login required)
docker push 10.0.0.248:5000/my-app:v1.0.0
```

2. **Use images in Kubernetes manifests**:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      containers:
      - name: my-app
        image: 10.0.0.248:5000/my-app:v1.0.0
        ports:
        - containerPort: 8080
```

3. **No authentication required**:
```bash
# Registry runs with open access - no secrets needed
# Images can be pulled directly without authentication
```

### Scaling to Multiple Nodes

To add worker nodes:

1. Update `inventory/hosts.ini`:
```ini
[k3s_master]
k3s-master-1 ansible_host=10.0.0.10 ansible_user=<your_user> ansible_ssh_private_key_file=~/.ssh/id_ed25519

[k3s_worker]
k3s-worker-1 ansible_host=10.0.0.11 ansible_user=<your_user> ansible_ssh_private_key_file=~/.ssh/id_ed25519
k3s-worker-2 ansible_host=10.0.0.12 ansible_user=<your_user> ansible_ssh_private_key_file=~/.ssh/id_ed25519
```

2. Add worker node tasks to the playbook

## Security Considerations

- Change default passwords in `group_vars/all.yaml`
- Consider using Ansible Vault for sensitive data:
  ```bash
  ansible-vault create group_vars/vault.yaml
  ```
- Regularly update k3s and container images
- Configure network policies for pod-to-pod communication
- Use RBAC for service accounts

## Maintenance

### Updates

```bash
# Update k3s
# Edit group_vars/all.yaml with new version
# Re-run playbook
ansible-playbook -i inventory/hosts.ini playbook.yaml --tags k3s

# Update Helm charts
helm repo update
```

### Backups

```bash
# Backup k3s cluster state
sudo cp /var/lib/rancher/k3s/server/db/state.db ~/k3s-backup-$(date +%Y%m%d).db

# Backup Pi-hole configuration
kubectl get configmap -n pihole -o yaml > pihole-config-backup.yaml
```

## License

This project is licensed under the MIT License.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Test your changes
4. Submit a pull request

## Support

For issues and questions:
- Check the troubleshooting section above
- Review Ansible and k3s documentation
- Open an issue in the project repository
