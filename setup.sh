#!/bin/bash

set -e

echo "Setting up Ansible environment for k3s deployment..."

# Check if ansible is installed
if ! command -v ansible &> /dev/null; then
    echo "Ansible is not installed. Please install it first:"
    echo "  pip install ansible"
    exit 1
fi

# Install required Ansible collections
echo "Installing Ansible collections..."
ansible-galaxy collection install -r requirements.yml --force

# Install Python dependencies for Kubernetes modules
echo "Installing Python dependencies..."
pip install kubernetes>=12.0.0

# Install additional Python packages that might be needed
pip install PyYAML>=3.11
pip install jsonpatch

echo ""
echo "Setup complete! You can now run the playbook with:"
echo "  ansible-playbook -i inventory/hosts.ini playbook.yaml"
echo ""
echo "Make sure your Alpine Linux server has Python 3 installed:"
echo "  ssh tiago@10.0.0.10 'sudo apk add python3'"
