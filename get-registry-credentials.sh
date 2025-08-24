#!/bin/bash

# Script to retrieve Docker Registry credentials
# Usage: ./get-registry-credentials.sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}===============================================${NC}"
echo -e "${BLUE}        Docker Registry Information${NC}"
echo -e "${BLUE}===============================================${NC}"
echo

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl is not installed or not in PATH${NC}"
    exit 1
fi

# Check if we can connect to the cluster
if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}Error: Cannot connect to Kubernetes cluster${NC}"
    echo -e "${YELLOW}Make sure you have proper kubeconfig and the cluster is running${NC}"
    exit 1
fi

# Check if registry namespace exists
if ! kubectl get namespace registry &> /dev/null; then
    echo -e "${RED}Error: Registry namespace not found${NC}"
    echo -e "${YELLOW}Make sure the registry is installed first${NC}"
    exit 1
fi

# Get registry service info
REGISTRY_SERVICE=$(kubectl get service registry-service -n registry -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
if [ -z "$REGISTRY_SERVICE" ]; then
    REGISTRY_SERVICE=$(kubectl get service registry-service -n registry -o jsonpath='{.spec.loadBalancerIP}' 2>/dev/null || echo "10.0.0.248")
fi

echo -e "${GREEN}Registry Connection Information:${NC}"
echo -e "  Registry URL (internal): ${YELLOW}$REGISTRY_SERVICE:5000${NC}"
echo -e "  Registry URL (external): ${YELLOW}https://registry.contdiscovery.lab${NC}"
echo -e "  Authentication: ${GREEN}Disabled (open access)${NC}"
echo

echo -e "${BLUE}Usage Examples:${NC}"
echo -e "${YELLOW}  # Tag and push an image:${NC}"
echo -e "  docker tag my-app:latest $REGISTRY_SERVICE:5000/my-app:latest"
echo -e "  docker push $REGISTRY_SERVICE:5000/my-app:latest"
echo
echo -e "${YELLOW}  # Pull an image:${NC}"
echo -e "  docker pull $REGISTRY_SERVICE:5000/my-app:latest"
echo

echo -e "${BLUE}Registry Status:${NC}"
kubectl get pods -n registry -o wide
echo
kubectl get service -n registry

echo
echo -e "${YELLOW}Note: This registry runs without authentication for simplicity.${NC}"
echo -e "${YELLOW}Consider adding authentication if you need secure access.${NC}"
echo
echo -e "${BLUE}===============================================${NC}"
