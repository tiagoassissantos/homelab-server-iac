# Manual sudo Setup for Alpine Linux

## Problem
Your Alpine Linux server is using `doas-sudo-shim` instead of real `sudo`. Ansible requires full sudo functionality, but the shim only supports a subset of sudo options.

## Solution: Replace doas-sudo-shim with real sudo

Follow these steps **manually** on your Alpine server:

### Step 1: SSH into your Alpine server
```bash
ssh tiago@10.0.0.10
```
*Enter your SSH key passphrase when prompted*

### Step 2: Install real sudo (run these commands on the Alpine server)

```bash
# Update package cache
doas apk update

# Install real sudo and remove doas-sudo-shim
doas apk add sudo !doas-sudo-shim

# Add your user to the wheel group
doas addgroup tiago wheel

# Create sudoers configuration for wheel group
doas tee /etc/sudoers.d/wheel > /dev/null << 'EOF'
# Allow wheel group to run all commands without password (for Ansible)
%wheel ALL=(ALL:ALL) NOPASSWD: ALL
EOF

# Set proper permissions on the sudoers file
doas chmod 440 /etc/sudoers.d/wheel

# Test sudo functionality
sudo whoami
```

### Step 3: Verify installation
```bash
# Check sudo version
sudo --version

# Test passwordless sudo
sudo -n whoami

# Check user groups
groups

# Exit the SSH session
exit
```

### Step 4: Test from your local machine
After completing the above steps, test Ansible connectivity:

```bash
# From your local machine in the homelab_server_iac directory
ansible masters -m ping

# Should return:
# k3s-1 | SUCCESS => {
#     "ansible_facts": {
#         "discovered_interpreter_python": "/usr/bin/python3.12"
#     },
#     "changed": false,
#     "ping": "pong"
# }
```

## Expected Output

When you run `doas apk add sudo !doas-sudo-shim`, you should see something like:

```
(1/1) Installing sudo (1.9.x-rx)
(1/1) Purging doas-sudo-shim (1.x.x-rx)
Executing sudo-1.9.x-rx.post-install
```

## Troubleshooting

### If `doas` asks for password
This is normal for security. Enter your user password when prompted.

### If you get "permission denied" errors
Make sure you're in the `wheel` group:
```bash
groups tiago
```

### If sudo still doesn't work
Try recreating the sudoers file:
```bash
doas rm /etc/sudoers.d/wheel
doas tee /etc/sudoers.d/wheel > /dev/null << 'EOF'
%wheel ALL=(ALL:ALL) NOPASSWD: ALL
EOF
doas chmod 440 /etc/sudoers.d/wheel
```

### If Ansible still fails after this fix
You might need to clear Ansible's fact cache:
```bash
# Remove any cached facts
rm -rf ~/.ansible/tmp/
```

## Verification Commands

Run these on the Alpine server to verify everything is working:

```bash
# Check sudo is real sudo (not shim)
which sudo
sudo --version | head -1

# Verify passwordless sudo
sudo -n echo "Passwordless sudo works!"

# Check user is in wheel group
id tiago

# Test Python execution with sudo (what Ansible uses)
sudo python3 -c "print('Python + sudo works!')"
```

## Next Steps

Once sudo is working, you can proceed with the Ansible deployment:

```bash
# Test Ansible connectivity
ansible masters -m ping

# Run the full deployment
ansible-playbook -i inventories/prod/hosts.ini playbooks/platform.yml

# Or use the deployment script
./deploy.sh
```

## Alternative: Using ask-become-pass

If you prefer to keep the password prompt (more secure), you can run Ansible with:

```bash
ansible-playbook -i inventories/prod/hosts.ini playbooks/platform.yml --ask-become-pass
```

This will prompt you for the sudo password during execution.
