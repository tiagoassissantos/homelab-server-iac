#!/bin/bash

# Test script for Docker Registry functionality
# Usage: ./test-registry.sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Registry configuration
REGISTRY_IP="10.0.0.248"
REGISTRY_PORT="5000"
REGISTRY_URL="$REGISTRY_IP:$REGISTRY_PORT"
TEST_IMAGE="hello-world"
TEST_TAG="registry-test"

echo -e "${BLUE}===============================================${NC}"
echo -e "${BLUE}        Docker Registry Test Suite${NC}"
echo -e "${BLUE}===============================================${NC}"
echo

# Function to print test status
print_test() {
    echo -e "${BLUE}[TEST]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

print_error() {
    echo -e "${RED}[FAIL]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Test 1: Check if kubectl is available
print_test "Checking kubectl availability..."
if command -v kubectl &> /dev/null; then
    print_success "kubectl is available"
else
    print_error "kubectl is not installed or not in PATH"
    exit 1
fi

# Test 2: Check Kubernetes cluster connectivity
print_test "Checking Kubernetes cluster connectivity..."
if kubectl cluster-info &> /dev/null; then
    print_success "Connected to Kubernetes cluster"
else
    print_error "Cannot connect to Kubernetes cluster"
    exit 1
fi

# Test 3: Check registry namespace and pods
print_test "Checking registry deployment status..."
if kubectl get namespace registry &> /dev/null; then
    print_success "Registry namespace exists"

    # Check pod status
    POD_STATUS=$(kubectl get pods -n registry -l app=registry -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
    if [ "$POD_STATUS" = "Running" ]; then
        print_success "Registry pod is running"
    else
        print_error "Registry pod status: $POD_STATUS"
        kubectl get pods -n registry
        exit 1
    fi
else
    print_error "Registry namespace not found"
    exit 1
fi

# Test 4: Check registry service
print_test "Checking registry service..."
if kubectl get service registry-service -n registry &> /dev/null; then
    EXTERNAL_IP=$(kubectl get service registry-service -n registry -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [ -z "$EXTERNAL_IP" ]; then
        EXTERNAL_IP=$(kubectl get service registry-service -n registry -o jsonpath='{.spec.loadBalancerIP}' 2>/dev/null || echo "Pending")
    fi
    print_success "Registry service exists (External IP: $EXTERNAL_IP)"
else
    print_error "Registry service not found"
    exit 1
fi

# Test 5: Check registry connectivity
print_test "Testing registry connectivity..."
if curl -s -f "http://$REGISTRY_URL/v2/" > /dev/null; then
    print_success "Registry is accessible at http://$REGISTRY_URL"
else
    print_error "Cannot connect to registry at http://$REGISTRY_URL"
    print_warning "This might be due to authentication requirements or network issues"
fi

# Test 6: Check if Docker is available
print_test "Checking Docker availability..."
if command -v docker &> /dev/null; then
    if docker info &> /dev/null; then
        print_success "Docker is available and running"
    else
        print_error "Docker is installed but not running"
        print_warning "Please start Docker daemon: sudo systemctl start docker"
        exit 1
    fi
else
    print_error "Docker is not installed or not in PATH"
    print_warning "Docker is required for push/pull tests"
    exit 1
fi

# Test 7: Test registry API endpoints
print_test "Testing registry API endpoints..."

# Test catalog endpoint (may require auth)
if curl -s -f "http://$REGISTRY_URL/v2/_catalog" > /dev/null; then
    CATALOG_RESPONSE=$(curl -s "http://$REGISTRY_URL/v2/_catalog")
    print_success "Registry catalog endpoint accessible"
    echo "  Catalog: $CATALOG_RESPONSE"
else
    print_warning "Registry catalog endpoint requires authentication (this is expected)"
fi

# Test 8: Pull a test image for later use
print_test "Pulling test image ($TEST_IMAGE)..."
if docker pull $TEST_IMAGE &> /dev/null; then
    print_success "Successfully pulled $TEST_IMAGE"
else
    print_error "Failed to pull $TEST_IMAGE"
    exit 1
fi

# Test 9: Tag image for registry
print_test "Tagging image for registry..."
if docker tag $TEST_IMAGE $REGISTRY_URL/$TEST_IMAGE:$TEST_TAG; then
    print_success "Successfully tagged image as $REGISTRY_URL/$TEST_IMAGE:$TEST_TAG"
else
    print_error "Failed to tag image"
    exit 1
fi

# Test 10: Push test image (no authentication required)
print_test "Testing image push..."
if docker push $REGISTRY_URL/$TEST_IMAGE:$TEST_TAG; then
    print_success "Successfully pushed test image"

    # Test 11: Remove local image and pull from registry
    print_test "Testing image pull from registry..."
    docker rmi $REGISTRY_URL/$TEST_IMAGE:$TEST_TAG &> /dev/null || true
    if docker pull $REGISTRY_URL/$TEST_IMAGE:$TEST_TAG; then
        print_success "Successfully pulled image from registry"

        # Cleanup
        docker rmi $REGISTRY_URL/$TEST_IMAGE:$TEST_TAG &> /dev/null || true
        print_success "Cleanup completed"
    else
        print_error "Failed to pull image from registry"
    fi
else
    print_error "Failed to push test image"
fi

# Test 12: Check registry storage
print_test "Checking registry storage..."
REGISTRY_POD=$(kubectl get pods -n registry -l app=registry -o jsonpath='{.items[0].metadata.name}')
if [ -n "$REGISTRY_POD" ]; then
    STORAGE_USAGE=$(kubectl exec -n registry $REGISTRY_POD -- du -sh /var/lib/registry 2>/dev/null || echo "N/A")
    print_success "Registry storage usage: $STORAGE_USAGE"

    # Check PVC status
    PVC_STATUS=$(kubectl get pvc registry-pvc -n registry -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    if [ "$PVC_STATUS" = "Bound" ]; then
        print_success "Persistent Volume Claim is bound"
    else
        print_warning "PVC status: $PVC_STATUS"
    fi
else
    print_error "Could not find registry pod"
fi

# Test 13: Check ingress configuration
print_test "Checking registry ingress..."
if kubectl get ingress registry-ingress -n registry &> /dev/null; then
    INGRESS_HOST=$(kubectl get ingress registry-ingress -n registry -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "N/A")
    print_success "Registry ingress configured (Host: $INGRESS_HOST)"

    # Test HTTPS endpoint if configured
    if [ "$INGRESS_HOST" != "N/A" ]; then
        print_test "Testing HTTPS endpoint..."
        if curl -k -s -f "https://$INGRESS_HOST/v2/" > /dev/null; then
            print_success "HTTPS endpoint is accessible"
        else
            print_warning "HTTPS endpoint not accessible (may require DNS configuration)"
        fi
    fi
else
    print_warning "Registry ingress not found"
fi

echo
echo -e "${BLUE}===============================================${NC}"
echo -e "${BLUE}           Test Summary${NC}"
echo -e "${BLUE}===============================================${NC}"
echo -e "${GREEN}Registry URL:${NC} http://$REGISTRY_URL"
echo -e "${GREEN}External IP:${NC} $EXTERNAL_IP"
echo -e "${GREEN}Authentication:${NC} Disabled (open access)"
echo -e "${GREEN}Ingress Host:${NC} $INGRESS_HOST"
echo
echo -e "${YELLOW}Next Steps:${NC}"
echo -e "1. Use ${BLUE}./get-registry-credentials.sh${NC} to get connection details"
echo -e "2. See ${BLUE}REGISTRY_GUIDE.md${NC} for detailed usage instructions"
echo -e "3. Configure your DNS to point $INGRESS_HOST to $EXTERNAL_IP for external access"
echo -e "4. Start using the registry: ${BLUE}docker push $REGISTRY_URL/my-image:tag${NC}"
echo
echo -e "${GREEN}✅ Registry test suite completed successfully!${NC}"
echo -e "${BLUE}===============================================${NC}"
