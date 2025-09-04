# Docker Registry Usage Guide

This guide explains how to use the Docker Registry deployed in your k3s homelab cluster.

## Overview

The Docker Registry is a private container registry that allows you to store and manage Docker images for your projects. It's deployed with:

- **Open Access**: No authentication required (simplified setup)
- **Persistent Storage**: 20GB of persistent storage for images
- **Load Balancer**: Accessible via MetalLB at `10.0.0.248:5000`
- **TLS/HTTPS**: External access with automatic TLS certificates
- **High Availability**: Kubernetes-managed deployment with health checks

## Quick Start

### 1. Installation

To install only the Docker Registry (assuming k3s is already configured):

```bash
# Install registry only
ansible-playbook -i inventories/prod/hosts.ini playbooks/platform.yml --tags registry

# Or install as part of the full stack
ansible-playbook -i inventories/prod/hosts.ini playbooks/platform.yml
```

### 2. Get Registry Information

```bash
# Use the helper script to get connection info
./get-registry-credentials.sh
```

### 3. Start Using Registry

```bash
# No login required - registry has open access
# You can directly push/pull images
```

## Configuration

### Registry Settings

The registry configuration is defined in `group_vars/all.yaml`:

```yaml
# Docker Registry Configuration
registry_namespace: "registry"           # Kubernetes namespace
registry_lb_ip: "10.0.0.248"            # LoadBalancer IP
registry_host: "registry.contdiscovery.lab"  # External domain
registry_storage_size: "20Gi"           # Persistent storage size
```

### Network Configuration

The registry is accessible via:
- **Internal**: `http://10.0.0.248:5000` (within k8s cluster or local network)
- **External**: `https://registry.contdiscovery.lab` (with TLS certificate)

## Usage Examples

### Basic Image Operations

```bash
# 1. Build your application
docker build -t my-app:v1.0.0 .

# 2. Tag for your registry
docker tag my-app:v1.0.0 10.0.0.248:5000/my-app:v1.0.0

# 3. Push (no login required)
docker push 10.0.0.248:5000/my-app:v1.0.0

# 4. Pull the image (from anywhere with access)
docker pull 10.0.0.248:5000/my-app:v1.0.0
```

### Multi-tag Strategy

```bash
# Tag with multiple versions
docker tag my-app:v1.0.0 10.0.0.248:5000/my-app:v1.0.0
docker tag my-app:v1.0.0 10.0.0.248:5000/my-app:latest

# Push all tags
docker push 10.0.0.248:5000/my-app:v1.0.0
docker push 10.0.0.248:5000/my-app:latest
```

### Project Organization

```bash
# Organize images by project/namespace
docker tag frontend:latest 10.0.0.248:5000/myproject/frontend:latest
docker tag backend:latest 10.0.0.248:5000/myproject/backend:latest
docker tag database:latest 10.0.0.248:5000/myproject/database:latest

# Push all project images
docker push 10.0.0.248:5000/myproject/frontend:latest
docker push 10.0.0.248:5000/myproject/backend:latest
docker push 10.0.0.248:5000/myproject/database:latest
```

## Kubernetes Integration

### Using Images in Deployments

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: default
spec:
  replicas: 2
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
        env:
        - name: ENV
          value: "production"
```

### No Authentication Required

Since the registry runs without authentication, no image pull secrets are needed:


```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  template:
    spec:
      containers:
      - name: my-app
        image: 10.0.0.248:5000/my-app:latest
```

## CI/CD Integration

### GitHub Actions Example

```yaml
name: Build and Push to Registry
on:
  push:
    branches: [ main ]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v3

    - name: Build Docker image
      run: docker build -t my-app:${{ github.sha }} .

    - name: Tag and Push
      run: |
        docker tag my-app:${{ github.sha }} 10.0.0.248:5000/my-app:${{ github.sha }}
        docker tag my-app:${{ github.sha }} 10.0.0.248:5000/my-app:latest
        docker push 10.0.0.248:5000/my-app:${{ github.sha }}
        docker push 10.0.0.248:5000/my-app:latest
```

### GitLab CI Example

```yaml
stages:
  - build
  - push

variables:
  REGISTRY: "10.0.0.248:5000"
  IMAGE_NAME: "my-app"

build:
  stage: build
  script:
    - docker build -t $IMAGE_NAME:$CI_COMMIT_SHA .

push:
  stage: push
  script:
    - docker tag $IMAGE_NAME:$CI_COMMIT_SHA $REGISTRY/$IMAGE_NAME:$CI_COMMIT_SHA
    - docker tag $IMAGE_NAME:$CI_COMMIT_SHA $REGISTRY/$IMAGE_NAME:latest
    - docker push $REGISTRY/$IMAGE_NAME:$CI_COMMIT_SHA
    - docker push $REGISTRY/$IMAGE_NAME:latest
```

## Registry Management

### List Images

```bash
# List all repositories
curl -X GET http://10.0.0.248:5000/v2/_catalog

# List tags for a specific image
curl -X GET http://10.0.0.248:5000/v2/my-app/tags/list
```

### Registry API Examples

```bash
# Check registry health
curl -X GET http://10.0.0.248:5000/v2/

# Get image manifest
curl -X GET http://10.0.0.248:5000/v2/my-app/manifests/latest
```

### Storage Management

```bash
# Check registry storage usage (from k8s master node)
kubectl exec -n registry deployment/registry -- du -sh /var/lib/registry

# Registry logs
kubectl logs -n registry deployment/registry -f
```

## Troubleshooting

### Common Issues

#### 1. Login Fails
```bash
# Check if registry is running
kubectl get pods -n registry

# Check service status
kubectl get service -n registry registry-service

#### 2. Push/Pull Issues
```bash
# Check connectivity
curl -k https://registry.contdiscovery.lab/v2/
# Should return: {}

# Test direct push/pull (no login required)
docker push 10.0.0.248:5000/test:latest

# Verify network access to registry IP
ping 10.0.0.248
```

#### 3. Certificate Issues
```bash
# For insecure registry, add to Docker daemon config
# /etc/docker/daemon.json
{
  "insecure-registries": ["10.0.0.248:5000"]
}

# Restart Docker daemon
sudo systemctl restart docker
```

#### 4. Storage Issues
```bash
# Check available storage
kubectl get pv registry-pv

# Check PVC status
kubectl get pvc -n registry registry-pvc

# Registry pod events
kubectl describe pod -n registry -l app=registry
```

### Logs and Debugging

```bash
# Registry application logs
kubectl logs -n registry deployment/registry

# Registry pod describe
kubectl describe pod -n registry -l app=registry

# Registry service status
kubectl describe service -n registry registry-service

# Check ingress configuration
kubectl describe ingress -n registry registry-ingress
```

## Security Best Practices

### 1. Access Control
- Registry runs with open access for simplicity
- Limit network access to registry IP range using firewall rules
- Consider adding authentication for production use

### 2. Image Security
```bash
# Scan images before pushing
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  -v $(pwd):/path \
  aquasec/trivy image my-app:latest

# Sign images (optional)
docker trust key generate my-key
docker trust signer add --key my-key.pub my-username 10.0.0.248:5000/my-app
```

### 3. Network Security
- Registry is behind MetalLB load balancer
- TLS termination at ingress level
- Internal communication over HTTP (cluster network)

## Backup and Recovery

### Backup Registry Data

```bash
# Create backup of registry persistent volume
kubectl exec -n registry deployment/registry -- tar czf /tmp/registry-backup.tar.gz -C /var/lib/registry .

# Copy backup from pod
kubectl cp registry/$(kubectl get pod -n registry -l app=registry -o jsonpath='{.items[0].metadata.name}'):/tmp/registry-backup.tar.gz ./registry-backup-$(date +%Y%m%d).tar.gz
```

### Restore Registry Data

```bash
# Copy backup to pod
kubectl cp ./registry-backup.tar.gz registry/$(kubectl get pod -n registry -l app=registry -o jsonpath='{.items[0].metadata.name}'):/tmp/

# Extract backup
kubectl exec -n registry deployment/registry -- tar xzf /tmp/registry-backup.tar.gz -C /var/lib/registry/
```

## Advanced Configuration

### Custom Registry Configuration

If you need to customize the registry configuration, you can modify the deployment:

```yaml
# Custom registry config
apiVersion: v1
kind: ConfigMap
metadata:
  name: registry-config
  namespace: registry
data:
  config.yml: |
    version: 0.1
    log:
      fields:
        service: registry
    storage:
      filesystem:
        rootdirectory: /var/lib/registry
    http:
      addr: :5000
      headers:
        X-Content-Type-Options: [nosniff]
    auth:
      htpasswd:
        realm: basic-realm
        path: /auth/htpasswd
```

### Performance Tuning

For high-traffic scenarios, consider:
- Increasing resource limits
- Using SSD storage for the persistent volume
- Implementing registry caching
- Setting up registry mirrors

## Support

For issues related to the registry deployment:

1. Check the troubleshooting section above
2. Review Ansible playbook logs
3. Check Kubernetes cluster status
4. Consult Docker Registry documentation: https://docs.docker.com/registry/

## References

- [Docker Registry API](https://docs.docker.com/registry/spec/api/)
- [Docker Registry Configuration](https://docs.docker.com/registry/configuration/)
- [Kubernetes Persistent Volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
- [MetalLB Configuration](https://metallb.universe.tf/configuration/)
