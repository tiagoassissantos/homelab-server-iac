#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}  Homelab k3s Deployment Script     ${NC}"
echo -e "${BLUE}======================================${NC}"
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

# Function to check prerequisites
check_prerequisites() {
    print_status "INFO" "Checking prerequisites..."

    # Check if ansible is installed
    if ! command -v ansible &> /dev/null; then
        print_status "FAIL" "Ansible is not installed"
        echo "Please install Ansible first:"
        echo "  pip install ansible"
        echo "  or"
        echo "  sudo pacman -S ansible (Arch Linux)"
        echo "  sudo apt install ansible (Ubuntu/Debian)"
        exit 1
    fi

    # Check if inventory exists
    if [ ! -f "inventory/hosts.ini" ]; then
        print_status "FAIL" "Inventory file not found: inventory/hosts.ini"
        exit 1
    fi

    # Check if playbook exists
    if [ ! -f "playbook.yaml" ]; then
        print_status "FAIL" "Playbook not found: playbook.yaml"
        exit 1
    fi

    # Check if SSH key exists
    if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
        print_status "FAIL" "SSH key not found: $HOME/.ssh/id_ed25519"
        echo "Please generate an SSH key first:"
        echo "  ssh-keygen -t ed25519 -C 'your-email@example.com'"
        exit 1
    fi

    print_status "OK" "All prerequisites met"
}

# Function to setup SSH agent
setup_ssh_agent() {
    print_status "INFO" "Setting up SSH agent..."

    # Setup SSH_ASKPASS
    if [ -z "$SSH_ASKPASS" ]; then
        local askpass_programs=(
            "/usr/lib/ssh/x11-ssh-askpass"
            "/usr/bin/ssh-askpass"
            "/usr/libexec/openssh/ssh-askpass"
            "/usr/lib/openssh/ssh-askpass"
        )

        for program in "${askpass_programs[@]}"; do
            if [ -x "$program" ]; then
                export SSH_ASKPASS="$program"
                break
            fi
        done
    fi

    # Start or load SSH agent
    if [ -f ~/.ssh-agent-env ]; then
        source ~/.ssh-agent-env
        if [ -n "$SSH_AGENT_PID" ] && kill -0 "$SSH_AGENT_PID" 2>/dev/null; then
            print_status "OK" "Using existing SSH agent"
        else
            eval "$(ssh-agent -s)" > /dev/null
            echo "export SSH_AUTH_SOCK=$SSH_AUTH_SOCK" > ~/.ssh-agent-env
            echo "export SSH_AGENT_PID=$SSH_AGENT_PID" >> ~/.ssh-agent-env
        fi
    else
        eval "$(ssh-agent -s)" > /dev/null
        echo "export SSH_AUTH_SOCK=$SSH_AUTH_SOCK" > ~/.ssh-agent-env
        echo "export SSH_AGENT_PID=$SSH_AGENT_PID" >> ~/.ssh-agent-env
    fi

    # Add SSH key if not already added
    if ! ssh-add -l 2>/dev/null | grep -q "$HOME/.ssh/id_ed25519"; then
        if ssh-add "$HOME/.ssh/id_ed25519" 2>/dev/null; then
            print_status "OK" "SSH key added to agent"
        else
            print_status "WARN" "Failed to add SSH key automatically"
            echo "Please add your SSH key manually:"
            echo "  ssh-add ~/.ssh/id_ed25519"
            echo "Then re-run this script."
            exit 1
        fi
    else
        print_status "OK" "SSH key already loaded in agent"
    fi
}

# Function to test connectivity
test_connectivity() {
    print_status "INFO" "Testing connectivity..."

    if ansible -i inventory/hosts.ini masters -m ping > /dev/null 2>&1; then
        print_status "OK" "Ansible connectivity successful"
    else
        print_status "FAIL" "Ansible connectivity failed"
        echo ""
        echo "Troubleshooting steps:"
        echo "1. Ensure your SSH key is added to the Alpine server:"
        echo "   ssh-copy-id tiago@10.0.0.10"
        echo "2. Test manual SSH connection:"
        echo "   ssh tiago@10.0.0.10"
        echo "3. Check if the server is reachable:"
        echo "   ping 10.0.0.10"
        exit 1
    fi
}

# Function to install Ansible requirements
install_requirements() {
    print_status "INFO" "Installing Ansible requirements..."

    if [ -f "requirements.yml" ]; then
        if ansible-galaxy collection install -r requirements.yml --force > /dev/null 2>&1; then
            print_status "OK" "Ansible collections installed"
        else
            print_status "WARN" "Failed to install some Ansible collections"
        fi
    fi

    # Install Python kubernetes library
    if pip install kubernetes PyYAML jsonpatch > /dev/null 2>&1; then
        print_status "OK" "Python dependencies installed"
    else
        print_status "WARN" "Failed to install Python dependencies"
        echo "You may need to install manually:"
        echo "  pip install kubernetes PyYAML jsonpatch"
    fi
}

# Function to run deployment
run_deployment() {
    print_status "INFO" "Starting deployment..."
    echo ""
    echo -e "${YELLOW}This will take 15-30 minutes depending on your internet connection.${NC}"
    echo -e "${YELLOW}You can monitor progress in the output below.${NC}"
    echo ""

    # Ask for confirmation
    read -p "Continue with deployment? [y/N]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_status "INFO" "Deployment cancelled by user"
        exit 0
    fi

    # Run the playbook
    echo -e "${BLUE}Running Ansible playbook...${NC}"
    if ansible-playbook -i inventory/hosts.ini playbook.yaml; then
        print_status "OK" "Deployment completed successfully!"
    else
        print_status "FAIL" "Deployment failed"
        echo ""
        echo "Check the error messages above and try:"
        echo "1. Re-running the deployment (some failures are temporary)"
        echo "2. Checking the server logs: ssh tiago@10.0.0.10 'sudo journalctl -u k3s'"
        echo "3. Running with verbose output: ansible-playbook -i inventory/hosts.ini playbook.yaml -v"
        exit 1
    fi
}

# Function to run validation
run_validation() {
    print_status "INFO" "Running post-deployment validation..."
    echo ""

    if [ -x "./validate.sh" ]; then
        ./validate.sh
    else
        print_status "WARN" "Validation script not found or not executable"
        echo "Manual validation steps:"
        echo "1. Check cluster: ssh tiago@10.0.0.10 'kubectl get nodes'"
        echo "2. Check services: ssh tiago@10.0.0.10 'kubectl get svc --all-namespaces'"
        echo "3. Access Pi-hole: http://10.0.0.101/admin"
        echo "4. Access Argo: https://argo.homelab.contdiscovery.lan"
    fi
}

# Function to show completion summary
show_completion() {
    echo ""
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}  Deployment Complete! 🎉            ${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo ""
    echo "Services available:"
    echo -e "  • Pi-hole Admin: ${BLUE}http://10.0.0.101/admin${NC}"
    echo -e "  • Argo Workflows: ${BLUE}https://argo.homelab.contdiscovery.lan${NC}"
    echo -e "  • k3s Server: ${BLUE}ssh tiago@10.0.0.10${NC}"
    echo ""
    echo "Next steps:"
    echo "1. Configure your devices to use Pi-hole DNS (10.0.0.101)"
    echo "   Note: Pi-hole DNS runs on port 5353, but clients use standard port 53"
    echo "2. Add argo.homelab.contdiscovery.lan to your hosts file or DNS"
    echo "3. Access the Pi-hole admin interface with the configured password"
    echo "4. Test Pi-hole DNS: dig @10.0.0.101 -p 5353 google.com"
    echo ""
    echo "Configuration files:"
    echo "  • kubectl config: ssh tiago@10.0.0.10 'cat ~/.kube/config'"
    echo "  • Cluster info: ssh tiago@10.0.0.10 'kubectl cluster-info'"
    echo ""
}

# Main execution
main() {
    check_prerequisites
    setup_ssh_agent
    test_connectivity
    install_requirements
    run_deployment
    run_validation
    show_completion
}

# Handle script interruption
trap 'echo -e "\n${RED}Deployment interrupted${NC}"; exit 1' INT TERM

# Run main function
main "$@"
