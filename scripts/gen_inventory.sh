#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../terraform"

WEB_IP=$(terraform output -raw web_public_ip)
DB_IP=$(terraform output -raw db_private_ip)
KEY=~/.ssh/tf-mern-key

cat > ../ansible/inventory/hosts.ini <<EOF
[web]
web1 ansible_host=${WEB_IP}

[db]
db1 ansible_host=${DB_IP} ansible_ssh_common_args='-o ProxyCommand="ssh -i ${KEY} -o StrictHostKeyChecking=accept-new -W %h:%p -q ubuntu@${WEB_IP}"'

[all:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=${KEY}
EOF
echo "Inventory written."