#!/bin/bash

# Script to setup SSH agent for Ansible deployment
# This handles SSH keys with passphrases properly

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Setting up SSH agent for Ansible...${NC}"

# Function to setup SSH_ASKPASS
setup_ssh_askpass() {
    if [ -n "$SSH_ASKPASS" ] && [ -x "$SSH_ASKPASS" ]; then
        echo -e "${GREEN}SSH_ASKPASS already set: $SSH_ASKPASS${NC}"
        return 0
    fi

    # Try to find ssh-askpass programs
    local askpass_programs=(
        "/usr/lib/ssh/x11-ssh-askpass"
        "/usr/bin/ssh-askpass"
        "/usr/libexec/openssh/ssh-askpass"
        "/usr/lib/openssh/ssh-askpass"
    )

    for program in "${askpass_programs[@]}"; do
        if [ -x "$program" ]; then
            export SSH_ASKPASS="$program"
            echo -e "${GREEN}Found and set SSH_ASKPASS: $program${NC}"
            return 0
        fi
    done

    echo -e "${YELLOW}Warning: No SSH_ASKPASS program found${NC}"
    echo "You may need to install one:"
    echo "  Arch Linux: sudo pacman -S x11-ssh-askpass"
    echo "  Ubuntu/Debian: sudo apt install ssh-askpass-gnome"
    echo "  RHEL/CentOS: sudo yum install openssh-askpass"
    return 1
}

# Check if SSH key exists
SSH_KEY="$HOME/.ssh/id_ed25519"
if [ ! -f "$SSH_KEY" ]; then
    echo -e "${RED}Error: SSH key not found at $SSH_KEY${NC}"
    echo "Please generate an SSH key first:"
    echo "  ssh-keygen -t ed25519 -C 'your-email@example.com'"
    exit 1
fi

# Function to check if ssh-agent is running
is_ssh_agent_running() {
    [ -n "$SSH_AGENT_PID" ] && kill -0 "$SSH_AGENT_PID" 2>/dev/null
}

# Function to start ssh-agent
start_ssh_agent() {
    echo -e "${YELLOW}Starting SSH agent...${NC}"
    eval "$(ssh-agent -s)"

    # Save agent info for future sessions
    echo "export SSH_AUTH_SOCK=$SSH_AUTH_SOCK" > ~/.ssh-agent-env
    echo "export SSH_AGENT_PID=$SSH_AGENT_PID" >> ~/.ssh-agent-env
}

# Function to load existing agent
load_ssh_agent() {
    if [ -f ~/.ssh-agent-env ]; then
        source ~/.ssh-agent-env
        if is_ssh_agent_running; then
            echo -e "${GREEN}Using existing SSH agent (PID: $SSH_AGENT_PID)${NC}"
            return 0
        fi
    fi
    return 1
}

# Function to add key to agent
add_ssh_key() {
    echo -e "${YELLOW}Adding SSH key to agent...${NC}"

    # Check if key is already added
    if ssh-add -l 2>/dev/null | grep -q "$SSH_KEY"; then
        echo -e "${GREEN}SSH key is already loaded in agent${NC}"
        return 0
    fi

    # Try to add the key
    if ssh-add "$SSH_KEY"; then
        echo -e "${GREEN}SSH key added successfully${NC}"
        return 0
    else
        echo -e "${RED}Failed to add SSH key${NC}"
        return 1
    fi
}

# Main logic
if ! load_ssh_agent; then
    start_ssh_agent
fi

# Setup SSH_ASKPASS before adding keys
setup_ssh_askpass

if ! add_ssh_key; then
    echo -e "${RED}Failed to setup SSH agent${NC}"
    exit 1
fi

# Test SSH connection
echo -e "${YELLOW}Testing SSH connection...${NC}"
SERVER_IP="10.0.0.10"
SERVER_USER="tiago"

if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${SERVER_USER}@${SERVER_IP}" "echo 'SSH test successful'" 2>/dev/null; then
    echo -e "${GREEN}✅ SSH connection test successful${NC}"
else
    echo -e "${RED}❌ SSH connection test failed${NC}"
    echo ""
    echo "Please ensure:"
    echo "1. Your public key is added to the server:"
    echo "   ssh-copy-id ${SERVER_USER}@${SERVER_IP}"
    echo "2. The server allows SSH key authentication"
    echo "3. The server is reachable at ${SERVER_IP}"
    exit 1
fi

# Test Ansible connectivity
echo -e "${YELLOW}Testing Ansible connectivity...${NC}"
if ansible -i inventory/hosts.ini masters -m ping >/dev/null 2>&1; then
    echo -e "${GREEN}✅ Ansible connectivity test successful${NC}"
else
    echo -e "${RED}❌ Ansible connectivity test failed${NC}"
    echo "Run this to test manually:"
    echo "  ansible -i inventory/hosts.ini masters -m ping"
fi

echo ""
echo -e "${GREEN}SSH agent setup complete!${NC}"
echo ""
echo "Environment variables set:"
echo "  SSH_AUTH_SOCK=$SSH_AUTH_SOCK"
echo "  SSH_AGENT_PID=$SSH_AGENT_PID"
echo ""
echo "To use this in future terminal sessions, run:"
echo "  source ~/.ssh-agent-env"
echo ""
echo "You can now run the Ansible playbook:"
echo "  ansible-playbook -i inventory/hosts.ini playbook.yaml"
