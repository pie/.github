SSH_USER=$1
SSH_HOST=$2
SSH_KEY=$3
SSH_PORT=$4


#ADD PRIVATE KEY
mkdir -p /home/runner/.ssh
ssh-keyscan -p "${SSH_PORT}" "${SSH_HOST}" >> /home/runner/.ssh/known_hosts
echo "${SSH_KEY}" > /home/runner/.ssh/github_actions
chmod 600 /home/runner/.ssh/github_actions
eval "$(ssh-agent -a /tmp/ssh_agent.sock)"
ssh-add /home/runner/.ssh/github_actions

#CREATE .~/ssh/config
cat > /home/runner/.ssh/config << EOL
Host server
HostName "${SSH_HOST}"
User "${SSH_USER}"
Port "${SSH_PORT}"
IdentityFile /home/runner/.ssh/github_actions
EOL