#!/bin/bash

SSH_USER=$1
SSH_HOST=$2
SSH_PASS=$3
SSH_PORT=$4

# Create .ssh directory
mkdir -p /home/runner/.ssh

# Add SSH host to known hosts
ssh-keyscan -p "${SSH_PORT}" "${SSH_HOST}" >> /home/runner/.ssh/known_hosts

# Handle SSH password
echo "${SSH_PASS}" > /home/runner/.ssh/sshpass
chmod 600 /home/runner/.ssh/sshpass

# Install sshpass if not already installed
if ! command -v sshpass &> /dev/null; then
  sudo apt-get update
  sudo apt-get install -y sshpass
fi

# Export the password for sshpass to use
export SSHPASS="${SSH_PASS}"