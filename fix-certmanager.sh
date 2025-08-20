#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SERVER_IP="10.0.0.10"
SERVER_USER="tiago"
CERT_MANAGER_VERSION="v1.13.3"

echo -e "${BLUE}=== cert-manager Troubleshooting Script ===${NC}"
echo ""

# Function to print status
print_status() {
    local status=$1
    local message=$2
    if [ "$status" = "OK" ]; then
        echo -e "✅ ${GREEN}$message${NC}"
    elif [ "$status" = "WARN" ]; then
        echo -e "⚠️  ${YELLOW}$message${NC}"
    elif [ "$status" = "INFO" ]; then
        echo -e "ℹ️  ${BLUE}$message${NC}"
    else
        echo -e "❌ ${RED}$message${NC}"
    fi
}

# Function to run remote kubectl command
run_kubectl() {
    ssh -o StrictHostKeyChecking=no ${SERVER_USER}@${SERVER_IP} "kubectl $*" 2>/dev/null
}

# Function to check if cert-manager namespace exists
check_namespace() {
    print_status "INFO" "Checking cert-manager namespace..."
    if run_kubectl get namespace cert-manager > /dev/null 2>&1; then
        print_status "OK" "cert-manager namespace exists"
        return 0
    else
        print_status "WARN" "cert-manager namespace does not exist"
        return 1
    fi
}

# Function to check cert-manager CRDs
check_crds() {
    print_status "INFO" "Checking cert-manager CRDs..."
    local crds=(
        "certificates.cert-manager.io"
        "certificaterequests.cert-manager.io"
        "issuers.cert-manager.io"
        "clusterissuers.cert-manager.io"
    )

    local missing_crds=()
    for crd in "${crds[@]}"; do
        if ! run_kubectl get crd "$crd" > /dev/null 2>&1; then
            missing_crds+=("$crd")
        fi
    done

    if [ ${#missing_crds[@]} -eq 0 ]; then
        print_status "OK" "All cert-manager CRDs are present"
        return 0
    else
        print_status "FAIL" "Missing CRDs: ${missing_crds[*]}"
        return 1
    fi
}

# Function to check cert-manager pods
check_pods() {
    print_status "INFO" "Checking cert-manager pods..."
    if ! run_kubectl get pods -n cert-manager > /dev/null 2>&1; then
        print_status "FAIL" "Cannot get cert-manager pods"
        return 1
    fi

    local pod_status=$(run_kubectl get pods -n cert-manager --no-headers 2>/dev/null)
    if [ -z "$pod_status" ]; then
        print_status "FAIL" "No cert-manager pods found"
        return 1
    fi

    echo "   Pod status:"
    echo "$pod_status" | sed 's/^/   /'

    # Check if all pods are running
    local not_running=$(echo "$pod_status" | grep -v "Running" | grep -v "Completed" | wc -l)
    if [ "$not_running" -eq 0 ]; then
        print_status "OK" "All cert-manager pods are running"
        return 0
    else
        print_status "WARN" "$not_running pods are not in Running state"
        return 1
    fi
}

# Function to check cert-manager helm release
check_helm_release() {
    print_status "INFO" "Checking cert-manager Helm release..."
    if run_kubectl get secret -n cert-manager | grep -q "sh.helm.release.v1.cert-manager"; then
        print_status "OK" "cert-manager Helm release found"
        local release_info=$(ssh ${SERVER_USER}@${SERVER_IP} "helm list -n cert-manager" 2>/dev/null || echo "No helm info")
        echo "   Release info:"
        echo "$release_info" | sed 's/^/   /'
        return 0
    else
        print_status "WARN" "cert-manager Helm release not found"
        return 1
    fi
}

# Function to remove cert-manager completely
remove_certmanager() {
    print_status "INFO" "Removing cert-manager completely..."

    # Remove Helm release
    ssh ${SERVER_USER}@${SERVER_IP} "helm uninstall cert-manager -n cert-manager" 2>/dev/null || true

    # Wait a bit
    sleep 10

    # Remove CRDs
    local crds=(
        "certificates.cert-manager.io"
        "certificaterequests.cert-manager.io"
        "issuers.cert-manager.io"
        "clusterissuers.cert-manager.io"
        "challenges.acme.cert-manager.io"
        "orders.acme.cert-manager.io"
    )

    for crd in "${crds[@]}"; do
        run_kubectl delete crd "$crd" 2>/dev/null || true
    done

    # Remove namespace
    run_kubectl delete namespace cert-manager 2>/dev/null || true

    # Wait for cleanup
    print_status "INFO" "Waiting for cleanup to complete..."
    sleep 30

    print_status "OK" "cert-manager removal completed"
}

# Function to install cert-manager CRDs
install_crds() {
    print_status "INFO" "Installing cert-manager CRDs..."

    # Download and apply CRDs
    if ssh ${SERVER_USER}@${SERVER_IP} "curl -sL https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.crds.yaml | kubectl apply -f -" > /dev/null 2>&1; then
        print_status "OK" "CRDs installed successfully"

        # Wait for CRDs to be established
        print_status "INFO" "Waiting for CRDs to be established..."
        local crds=(
            "certificates.cert-manager.io"
            "certificaterequests.cert-manager.io"
            "issuers.cert-manager.io"
            "clusterissuers.cert-manager.io"
        )

        for crd in "${crds[@]}"; do
            local timeout=60
            local count=0
            while [ $count -lt $timeout ]; do
                if run_kubectl get crd "$crd" -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null | grep -q "True"; then
                    break
                fi
                sleep 2
                count=$((count + 2))
            done

            if [ $count -ge $timeout ]; then
                print_status "WARN" "CRD $crd may not be fully established"
            fi
        done

        return 0
    else
        print_status "FAIL" "Failed to install CRDs"
        return 1
    fi
}

# Function to install cert-manager
install_certmanager() {
    print_status "INFO" "Installing cert-manager..."

    # Create namespace
    run_kubectl create namespace cert-manager 2>/dev/null || true

    # Add Helm repository
    ssh ${SERVER_USER}@${SERVER_IP} "helm repo add jetstack https://charts.jetstack.io && helm repo update" > /dev/null 2>&1

    # Install cert-manager
    if ssh ${SERVER_USER}@${SERVER_IP} "helm install cert-manager jetstack/cert-manager --namespace cert-manager --set installCRDs=false --wait --timeout=10m" > /dev/null 2>&1; then
        print_status "OK" "cert-manager installed successfully"
        return 0
    else
        print_status "FAIL" "Failed to install cert-manager"
        return 1
    fi
}

# Function to wait for cert-manager to be ready
wait_for_ready() {
    print_status "INFO" "Waiting for cert-manager to be ready..."

    local deployments=("cert-manager" "cert-manager-cainjector" "cert-manager-webhook")

    for deployment in "${deployments[@]}"; do
        print_status "INFO" "Waiting for $deployment to be ready..."
        local timeout=300
        local count=0

        while [ $count -lt $timeout ]; do
            if run_kubectl get deployment "$deployment" -n cert-manager -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -q "True"; then
                print_status "OK" "$deployment is ready"
                break
            fi
            sleep 5
            count=$((count + 5))

            if [ $((count % 30)) -eq 0 ]; then
                print_status "INFO" "Still waiting for $deployment... ($count/${timeout}s)"
            fi
        done

        if [ $count -ge $timeout ]; then
            print_status "FAIL" "$deployment did not become ready within timeout"
            return 1
        fi
    done

    return 0
}

# Function to create test ClusterIssuer
create_test_issuer() {
    print_status "INFO" "Creating test self-signed ClusterIssuer..."

    local issuer_yaml=$(cat << 'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer-test
spec:
  selfSigned: {}
EOF
)

    if echo "$issuer_yaml" | ssh ${SERVER_USER}@${SERVER_IP} "kubectl apply -f -" > /dev/null 2>&1; then
        print_status "OK" "Test ClusterIssuer created successfully"

        # Check if issuer is ready
        sleep 5
        if run_kubectl get clusterissuer selfsigned-issuer-test -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q "True"; then
            print_status "OK" "Test ClusterIssuer is ready"
            run_kubectl delete clusterissuer selfsigned-issuer-test > /dev/null 2>&1 || true
            return 0
        else
            print_status "WARN" "Test ClusterIssuer may not be ready yet"
            run_kubectl delete clusterissuer selfsigned-issuer-test > /dev/null 2>&1 || true
            return 1
        fi
    else
        print_status "FAIL" "Failed to create test ClusterIssuer"
        return 1
    fi
}

# Function to show cert-manager logs
show_logs() {
    print_status "INFO" "Showing cert-manager controller logs..."
    echo ""
    echo "Last 20 lines of cert-manager controller logs:"
    run_kubectl logs -n cert-manager deployment/cert-manager --tail=20 2>/dev/null | sed 's/^/   /' || print_status "WARN" "Could not get controller logs"

    echo ""
    echo "Last 10 lines of cert-manager webhook logs:"
    run_kubectl logs -n cert-manager deployment/cert-manager-webhook --tail=10 2>/dev/null | sed 's/^/   /' || print_status "WARN" "Could not get webhook logs"
}

# Main diagnostic function
diagnose() {
    print_status "INFO" "Running cert-manager diagnostics..."
    echo ""

    local issues=()

    if ! check_namespace; then
        issues+=("namespace")
    fi

    if ! check_crds; then
        issues+=("crds")
    fi

    if ! check_pods; then
        issues+=("pods")
    fi

    check_helm_release

    if [ ${#issues[@]} -eq 0 ]; then
        print_status "OK" "cert-manager appears to be healthy"
        create_test_issuer
    else
        print_status "WARN" "Found issues: ${issues[*]}"
        show_logs
    fi
}

# Main fix function
fix_certmanager() {
    print_status "INFO" "Attempting to fix cert-manager installation..."
    echo ""

    # Remove existing installation
    remove_certmanager

    # Install CRDs first
    if install_crds; then
        # Install cert-manager
        if install_certmanager; then
            # Wait for it to be ready
            if wait_for_ready; then
                # Test functionality
                if create_test_issuer; then
                    print_status "OK" "cert-manager installation completed successfully!"
                    return 0
                else
                    print_status "WARN" "cert-manager installed but test failed"
                    show_logs
                    return 1
                fi
            else
                print_status "FAIL" "cert-manager pods did not become ready"
                show_logs
                return 1
            fi
        else
            print_status "FAIL" "Failed to install cert-manager"
            return 1
        fi
    else
        print_status "FAIL" "Failed to install CRDs"
        return 1
    fi
}

# Main function
main() {
    echo "This script will diagnose and optionally fix cert-manager issues."
    echo ""

    # Test SSH connectivity
    if ! ssh -o ConnectTimeout=5 ${SERVER_USER}@${SERVER_IP} "echo 'SSH OK'" > /dev/null 2>&1; then
        print_status "FAIL" "Cannot connect to k3s server via SSH"
        exit 1
    fi
    print_status "OK" "SSH connection successful"

    # Test kubectl
    if ! run_kubectl version --client > /dev/null 2>&1; then
        print_status "FAIL" "kubectl not available on remote server"
        exit 1
    fi
    print_status "OK" "kubectl is available"

    # Run diagnostics
    diagnose

    echo ""
    echo "What would you like to do?"
    echo "1) Run diagnostics only (already done above)"
    echo "2) Fix cert-manager (remove and reinstall)"
    echo "3) Show detailed logs"
    echo "4) Exit"

    read -p "Enter your choice (1-4): " -n 1 -r
    echo ""

    case $REPLY in
        1)
            print_status "INFO" "Diagnostics completed above"
            ;;
        2)
            fix_certmanager
            ;;
        3)
            show_logs
            ;;
        4)
            print_status "INFO" "Exiting"
            exit 0
            ;;
        *)
            print_status "WARN" "Invalid choice"
            ;;
    esac
}

# Handle script interruption
trap 'echo -e "\n${RED}Script interrupted${NC}"; exit 1' INT TERM

# Run main function
main "$@"
