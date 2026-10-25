# Travel Memory

`.env` file to work with the backend after creating a database in mongodb (see `backend/.env.example`):

```
MONGO_URI='ENTER_YOUR_URL'
PORT=3001
# Frontend origins allowed to call the API (comma separated)
CORS_ORIGIN=http://localhost:3000
# Optional
UPLOAD_DIR=uploads
MAX_UPLOAD_MB=5
TRUST_PROXY=0
```

Data format to be added (dates are `YYYY-MM-DD`):

```json
{
    "tripName": "Incredible India",
    "startDateOfJourney": "2022-03-19",
    "endDateOfJourney": "2022-03-27",
    "nameOfHotels":"Hotel Namaste, Backpackers Club",
    "placesVisited":"Delhi, Kolkata, Chennai, Mumbai",
    "totalCost": 800000,
    "tripType": "leisure",
    "experience": "Lorem Ipsum, Lorem Ipsum,Lorem Ipsum,Lorem Ipsum,Lorem Ipsum,Lorem Ipsum,Lorem Ipsum,Lorem Ipsum,Lorem Ipsum,Lorem Ipsum,Lorem Ipsum,Lorem Ipsum,Lorem Ipsum,Lorem Ipsum,Lorem Ipsum,Lorem Ipsum,Lorem Ipsum,Lorem Ipsum,Lorem Ipsum,Lorem Ipsum,Lorem Ipsum,Lorem Ipsum,Lorem Ipsum,Lorem Ipsum,Lorem Ipsum,Lorem Ipsum,Lorem Ipsum, ",
    "image": "https://t3.ftcdn.net/jpg/03/04/85/26/360_F_304852693_nSOn9KvUgafgvZ6wM0CNaULYUa7xXBkA.jpg",
    "shortDescription":"India is a wonderful country with rich culture and good people.",
    "featured": true
}
```


For frontend, you need to create `.env` file and put the following content (remember to change it based on your requirements):
```bash
REACT_APP_BACKEND_URL=http://localhost:3001
```

## How to run BE

Note: Make sure you have the .env file already added
```bash
cd backend
npm install
npm start        # or: npm run dev (auto-reload with nodemon)
```

## How to run FE
Note: Make sure you have the .env file already added
```bash
cd frontend
npm install
npm start
```

# Deploying the TravelMemory MERN App on AWS with Terraform and Ansible

Terraform builds the AWS infrastructure (VPC, subnets, gateways, EC2, security groups, IAM). Ansible configures the servers, installs MongoDB and Node.js, and deploys the [TravelMemory](https://github.com/UnpredictablePrashant/TravelMemory) application.

- **Cloud:** AWS, region `ap-south-1` (Mumbai)
- **Instance type:** `t2.micro` (1 vCPU, 1 GiB RAM) for both servers
- **OS:** Ubuntu 22.04 LTS
- **Stack:** React (served by Nginx) → Express/Node.js (systemd) → MongoDB 7.0

---

## 1. Architecture

```
                         Internet
                            |
                    [ Internet Gateway ]
                            |
 +--------------------------+---------------------------------------+
 | VPC 10.0.0.0/16                                                  |
 |                                                                  |
 |  Public subnet 10.0.1.0/24          Private subnet 10.0.2.0/24   |
 |  +---------------------------+      +-------------------------+  |
 |  | Web EC2 (t2.micro)        |      | DB EC2 (t2.micro)       |  |
 |  | Nginx :80                 |----->| MongoDB :27017          |  |
 |  |  /      -> React build    |      | auth enabled            |  |
 |  |  /api/  -> Express :3001  |      | no public IP            |  |
 |  | SSH only from my IP       |      | SSH only from web SG    |  |
 |  +---------------------------+      +-------------------------+  |
 |        |                                   |                     |
 |  [ NAT Gateway + Elastic IP ] <------------+  (outbound only)    |
 +------------------------------------------------------------------+
```

### How the components interact

| From | To | Port | Purpose |
|---|---|---|---|
| Browser | Web EC2 (Nginx) | 80 | Loads the React app and calls `/api/*` |
| Nginx | Express (localhost) | 3001 | Reverse proxy, `/api/` prefix stripped |
| Express | DB EC2 (MongoDB) | 27017 | Reads and writes trip data, authenticated |
| My laptop | Web EC2 | 22 | SSH and Ansible, restricted to my IP |
| My laptop | DB EC2 | 22 | SSH via the web server as a jump host |
| DB EC2 | Internet (via NAT) | 80/443 | Package installs only, no inbound path |

The React app is built with `REACT_APP_BACKEND_URL=http://<web-public-ip>/api`. Because Nginx serves both the frontend and the API on port 80, there are no CORS issues and only port 80 is exposed.

---

## 2. Repository structure

```
.
├── terraform/
│   ├── versions.tf
│   ├── variables.tf
│   ├── main.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
├── ansible/
│   ├── ansible.cfg
│   ├── site.yml
│   ├── inventory/            # hosts.ini is generated, not committed
│   ├── group_vars/
│   │   ├── all/vars.yml
│   │   ├── all/vault.yml     # encrypted with ansible-vault
│   │   ├── web.yml
│   │   └── db.yml
│   └── roles/
│       ├── common/           # swap, SSH hardening, ufw
│       ├── mongodb/
│       └── webserver/
├── scripts/gen_inventory.sh
├── docs/screenshots/
└── README.md
```

---

## 3. Prerequisites

On your workstation (Linux/macOS/WSL):

| Tool | Check |
|---|---|
| AWS CLI v2 | `aws --version` |
| Terraform >= 1.5 | `terraform version` |
| Ansible (full package) | `ansible --version` |
| Git, SSH client | `git --version` |

```bash
pip install ansible
ansible-galaxy collection install community.general ansible.posix
```

An AWS account with an IAM user that can create VPC, EC2, and IAM resources.

---

## 4. Part 1: Infrastructure with Terraform

### Step 1: Configure the AWS CLI

```bash
aws configure
# AWS Access Key ID, Secret Access Key, region: ap-south-1, output: json
aws sts get-caller-identity      # confirms authentication
```

### Step 2: Create the SSH key pair

```bash
ssh-keygen -t ed25519 -f ~/.ssh/tf-mern-key -C "mern-assignment"
chmod 600 ~/.ssh/tf-mern-key
```

Terraform uploads only the `.pub` file. The private key never leaves your machine.

### Step 3: Initialise the Terraform project

```bash
mkdir -p terraform && cd terraform
```

`versions.tf`

```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}
```

`variables.tf`

```hcl
variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "project" {
  type    = string
  default = "mern-travelmemory"
}

variable "instance_type" {
  type    = string
  default = "t2.micro"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  type    = string
  default = "10.0.2.0/24"
}

variable "my_ip_cidr" {
  type        = string
  description = "Your public IP in CIDR form, e.g. 203.0.113.25/32"
}

variable "public_key_path" {
  type    = string
  default = "~/.ssh/tf-mern-key.pub"
}
```

`terraform.tfvars.example` (copy to `terraform.tfvars`, which is gitignored)

```hcl
my_ip_cidr = "203.0.113.25/32"
```

```bash
echo "my_ip_cidr = \"$(curl -s https://checkip.amazonaws.com)/32\"" > terraform.tfvars
terraform init
```

### Step 4: Network, compute, security and IAM (`main.tf`)

```hcl
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  az = data.aws_availability_zones.available.names[0]
}

# Ubuntu 22.04 LTS (x86_64, which t2.micro requires)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# ---------- VPC and networking ----------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project}-vpc" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = local.az
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project}-public" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = local.az
  tags              = { Name = "${var.project}-private" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-igw" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.project}-nat-eip" }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id # NAT lives in the PUBLIC subnet
  depends_on    = [aws_internet_gateway.igw]
  tags          = { Name = "${var.project}-nat" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "${var.project}-public-rt" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "${var.project}-private-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# ---------- Security groups ----------
resource "aws_security_group" "web" {
  name        = "${var.project}-web-sg"
  description = "Web server"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from my IP only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-web-sg" }
}

resource "aws_security_group" "db" {
  name        = "${var.project}-db-sg"
  description = "Database server"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "SSH from web server (jump host)"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]
  }

  ingress {
    description     = "MongoDB from web server only"
    from_port       = 27017
    to_port         = 27017
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-db-sg" }
}

# ---------- IAM role for EC2 ----------
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${var.project}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# Session Manager access as a fallback to SSH
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Allows shipping logs/metrics to CloudWatch
resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# ---------- EC2 instances ----------
resource "aws_key_pair" "deployer" {
  key_name   = "${var.project}-key"
  public_key = file(pathexpand(var.public_key_path))
}

resource "aws_instance" "web" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type # t2.micro
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.web.id]
  key_name               = aws_key_pair.deployer.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = { Name = "${var.project}-web", Role = "web" }
}

resource "aws_instance" "db" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type # t2.micro
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.db.id]
  key_name               = aws_key_pair.deployer.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = { Name = "${var.project}-db", Role = "db" }
}
```

### Step 5: Outputs (`outputs.tf`)

```hcl
output "web_public_ip" {
  description = "Public IP of the web server"
  value       = aws_instance.web.public_ip
}

output "db_private_ip" {
  description = "Private IP of the database server"
  value       = aws_instance.db.private_ip
}

output "ssh_web" {
  value = "ssh -i ~/.ssh/tf-mern-key ubuntu@${aws_instance.web.public_ip}"
}
```

### Step 6: Apply

```bash
terraform fmt
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

Expected: about 22 resources created, with `web_public_ip` and `db_private_ip` printed. The NAT Gateway takes 1 to 2 minutes.

### Step 7: Verify SSH access

```bash
# Web server, direct
ssh -i ~/.ssh/tf-mern-key ubuntu@$(terraform output -raw web_public_ip)

# DB server, through the web server as jump host
ssh -i ~/.ssh/tf-mern-key \
  -o ProxyCommand="ssh -i ~/.ssh/tf-mern-key -W %h:%p -q ubuntu@$(terraform output -raw web_public_ip)" \
  ubuntu@$(terraform output -raw db_private_ip)
```

A connection attempt from any other IP to the web server times out, which confirms the security group works.

---

## 5. Part 2: Configuration with Ansible

### Step 8: Generate the inventory from Terraform outputs

`scripts/gen_inventory.sh`

```bash
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
```

```bash
chmod +x scripts/gen_inventory.sh && ./scripts/gen_inventory.sh
```

### Step 9: Ansible configuration

`ansible/ansible.cfg`

```ini
[defaults]
inventory           = inventory/hosts.ini
roles_path          = roles
host_key_checking   = False
interpreter_python  = auto_silent
vault_password_file = .vault_pass

[ssh_connection]
pipelining = True
```

```bash
cd ansible
ansible all -m ping     # both hosts must return pong
```

The DB host answering `pong` proves the jump-host path works.

### Step 10: Variables and secrets

`group_vars/all/vars.yml`

```yaml
admin_ip_cidr: "203.0.113.25/32"      # same value as Terraform my_ip_cidr
web_subnet_cidr: "10.0.1.0/24"

app_repo: "https://github.com/UnpredictablePrashant/TravelMemory.git"
app_dir: /opt/travelmemory
backend_port: 3001

mongo_admin_user: admin
mongo_app_user: travel_app
mongo_app_db: travelmemory
mongo_admin_password: "{{ vault_mongo_admin_password }}"
mongo_app_password: "{{ vault_mongo_app_password }}"
```

`group_vars/all/vault.yml`, encrypted

```bash
echo "choose-a-vault-password" > .vault_pass && chmod 600 .vault_pass
ansible-vault create group_vars/all/vault.yml
```

```yaml
vault_mongo_admin_password: "AdminPassw0rdChangeMe"
vault_mongo_app_password: "AppPassw0rdChangeMe"
```

Use alphanumeric passwords. They are embedded in shell commands and a connection string.

`group_vars/web.yml`

```yaml
db_host: "{{ hostvars['db1'].ansible_host }}"
ufw_rules:
  - { port: "22", src: "{{ admin_ip_cidr }}" }
  - { port: "80", src: "any" }
```

`group_vars/db.yml`

```yaml
ufw_rules:
  - { port: "22",    src: "{{ web_subnet_cidr }}" }
  - { port: "27017", src: "{{ web_subnet_cidr }}" }
```

### Step 11: Master playbook (`site.yml`)

The database is configured before the web server so the app has something to connect to.

```yaml
---
- name: Baseline and hardening
  hosts: all
  become: true
  roles: [common]

- name: Database server
  hosts: db
  become: true
  roles: [mongodb]

- name: Web server
  hosts: web
  become: true
  roles: [webserver]
```

### Step 12: Role `common` (swap, SSH hardening, firewall)

`roles/common/handlers/main.yml`

```yaml
---
- name: Restart ssh
  ansible.builtin.service:
    name: ssh
    state: restarted
```

`roles/common/tasks/main.yml`

```yaml
---
- name: Update apt cache and upgrade packages
  ansible.builtin.apt:
    update_cache: true
    upgrade: safe
    cache_valid_time: 3600

# t2.micro has only 1 GiB RAM: swap prevents OOM kills during npm install / React build
- name: Create 1 GiB swap file
  ansible.builtin.command: dd if=/dev/zero of=/swapfile bs=1M count=1024
  args:
    creates: /swapfile
  register: swap_created

- name: Set swap file permissions
  ansible.builtin.file:
    path: /swapfile
    mode: "0600"

- name: Format swap file
  ansible.builtin.command: mkswap /swapfile
  when: swap_created.changed

- name: Enable swap
  ansible.builtin.command: swapon /swapfile
  when: swap_created.changed

- name: Persist swap in fstab
  ansible.posix.mount:
    path: none
    src: /swapfile
    fstype: swap
    opts: sw
    state: present

- name: Harden sshd
  ansible.builtin.lineinfile:
    path: /etc/ssh/sshd_config
    regexp: "^#?{{ item.key }}\\s"
    line: "{{ item.key }} {{ item.value }}"
    validate: "sshd -t -f %s"
  loop:
    - { key: PermitRootLogin,        value: "no" }
    - { key: PasswordAuthentication, value: "no" }
    - { key: PubkeyAuthentication,   value: "yes" }
    - { key: MaxAuthTries,           value: "3" }
  notify: Restart ssh

- name: Install ufw
  ansible.builtin.apt:
    name: ufw
    state: present

- name: Allow required ports
  community.general.ufw:
    rule: allow
    proto: tcp
    port: "{{ item.port }}"
    from_ip: "{{ item.src }}"
  loop: "{{ ufw_rules }}"

- name: Enable ufw with default deny inbound
  community.general.ufw:
    state: enabled
    policy: deny
    direction: incoming
```

### Step 13: Role `mongodb`

`roles/mongodb/defaults/main.yml`

```yaml
mongo_auth: enabled
```

`roles/mongodb/handlers/main.yml`

```yaml
---
- name: Restart mongod
  ansible.builtin.service:
    name: mongod
    state: restarted
```

`roles/mongodb/templates/mongod.conf.j2`

```yaml
storage:
  dbPath: /var/lib/mongodb
  wiredTiger:
    engineConfig:
      cacheSizeGB: 0.25        # keeps MongoDB inside t2.micro's 1 GiB RAM
systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log
net:
  port: 27017
  bindIp: 127.0.0.1,{{ ansible_default_ipv4.address }}   # private IP only, never 0.0.0.0
processManagement:
  timeZoneInfo: /usr/share/zoneinfo
security:
  authorization: {{ mongo_auth }}
```

`roles/mongodb/tasks/main.yml`

```yaml
---
- name: Ensure apt keyrings directory exists
  ansible.builtin.file:
    path: /etc/apt/keyrings
    state: directory
    mode: "0755"

- name: Add MongoDB 7.0 signing key
  ansible.builtin.get_url:
    url: https://pgp.mongodb.com/server-7.0.asc
    dest: /etc/apt/keyrings/mongodb-server-7.0.asc
    mode: "0644"

- name: Add MongoDB 7.0 repository
  ansible.builtin.apt_repository:
    repo: "deb [signed-by=/etc/apt/keyrings/mongodb-server-7.0.asc] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse"
    filename: mongodb-org-7.0

- name: Install MongoDB
  ansible.builtin.apt:
    name: mongodb-org
    state: present
    update_cache: true

- name: Check whether authentication is already configured
  ansible.builtin.shell: >
    mongosh --quiet admin -u "{{ mongo_admin_user }}" -p "{{ mongo_admin_password }}"
    --eval "db.runCommand({ping:1}).ok"
  register: auth_check
  failed_when: false
  changed_when: false
  no_log: true

# First run only: start without auth, create users, then lock it down
- name: Bootstrap users
  when: auth_check.rc != 0
  block:
    - name: Temporary config without auth
      ansible.builtin.template:
        src: mongod.conf.j2
        dest: /etc/mongod.conf
        mode: "0644"
      vars:
        mongo_auth: disabled

    - name: Start mongod
      ansible.builtin.service:
        name: mongod
        state: restarted
        enabled: true

    - name: Wait for MongoDB
      ansible.builtin.wait_for:
        host: 127.0.0.1
        port: 27017
        delay: 3
        timeout: 60

    - name: Create admin user
      ansible.builtin.shell: |
        mongosh --quiet --eval '
          const a = db.getSiblingDB("admin");
          if (!a.getUser("{{ mongo_admin_user }}")) {
            a.createUser({user: "{{ mongo_admin_user }}", pwd: "{{ mongo_admin_password }}",
                          roles: [{role: "root", db: "admin"}]});
          }'
      no_log: true

    - name: Create application database user
      ansible.builtin.shell: |
        mongosh --quiet --eval '
          const d = db.getSiblingDB("{{ mongo_app_db }}");
          if (!d.getUser("{{ mongo_app_user }}")) {
            d.createUser({user: "{{ mongo_app_user }}", pwd: "{{ mongo_app_password }}",
                          roles: [{role: "readWrite", db: "{{ mongo_app_db }}"}]});
          }
          d.init.insertOne({created: new Date()});'
      no_log: true

- name: Final config with authentication enabled
  ansible.builtin.template:
    src: mongod.conf.j2
    dest: /etc/mongod.conf
    mode: "0644"
  notify: Restart mongod

- name: Apply pending restarts
  ansible.builtin.meta: flush_handlers

- name: Ensure mongod is running and enabled
  ansible.builtin.service:
    name: mongod
    state: started
    enabled: true
```

### Step 14: Role `webserver`

`roles/webserver/handlers/main.yml`

```yaml
---
- name: Restart backend
  ansible.builtin.systemd:
    name: travelmemory
    state: restarted

- name: Reload nginx
  ansible.builtin.service:
    name: nginx
    state: reloaded
```

`roles/webserver/templates/backend.env.j2`

```
PORT={{ backend_port }}
MONGO_URI=mongodb://{{ mongo_app_user }}:{{ mongo_app_password }}@{{ db_host }}:27017/{{ mongo_app_db }}?authSource={{ mongo_app_db }}
```

`roles/webserver/templates/frontend.env.j2`

```
REACT_APP_BACKEND_URL=http://{{ ansible_host }}/api
GENERATE_SOURCEMAP=false
```

`roles/webserver/templates/travelmemory.service.j2`

```ini
[Unit]
Description=TravelMemory Express backend
After=network.target

[Service]
User=ubuntu
WorkingDirectory={{ app_dir }}/backend
EnvironmentFile={{ app_dir }}/backend/.env
Environment=NODE_ENV=production
ExecStart=/usr/bin/node index.js
Restart=always
RestartSec=5
MemoryMax=300M

[Install]
WantedBy=multi-user.target
```

`roles/webserver/templates/nginx.conf.j2`

```nginx
server {
    listen 80 default_server;
    server_name _;

    root {{ app_dir }}/frontend/build;
    index index.html;

    location / {
        try_files $uri /index.html;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:{{ backend_port }}/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

`roles/webserver/tasks/main.yml`

```yaml
---
- name: Install base packages
  ansible.builtin.apt:
    name: [git, nginx, curl, ca-certificates, gnupg]
    state: present
    update_cache: true

- name: Download NodeSource setup script (Node.js 20)
  ansible.builtin.get_url:
    url: https://deb.nodesource.com/setup_20.x
    dest: /tmp/nodesource_setup.sh
    mode: "0755"

- name: Add NodeSource repository
  ansible.builtin.command: bash /tmp/nodesource_setup.sh
  args:
    creates: /etc/apt/sources.list.d/nodesource.list

- name: Install Node.js and npm
  ansible.builtin.apt:
    name: nodejs
    state: present
    update_cache: true

- name: Create app directory
  ansible.builtin.file:
    path: "{{ app_dir }}"
    state: directory
    owner: ubuntu
    group: ubuntu
    mode: "0755"

- name: Clone TravelMemory
  ansible.builtin.git:
    repo: "{{ app_repo }}"
    dest: "{{ app_dir }}"
    update: false
  become_user: ubuntu

- name: Write backend .env
  ansible.builtin.template:
    src: backend.env.j2
    dest: "{{ app_dir }}/backend/.env"
    owner: ubuntu
    group: ubuntu
    mode: "0600"
  no_log: true
  notify: Restart backend

- name: Install backend dependencies
  community.general.npm:
    path: "{{ app_dir }}/backend"
    state: present
  become_user: ubuntu

- name: Write frontend .env
  ansible.builtin.template:
    src: frontend.env.j2
    dest: "{{ app_dir }}/frontend/.env"
    owner: ubuntu
    group: ubuntu
    mode: "0644"
  register: frontend_env

- name: Install frontend dependencies
  community.general.npm:
    path: "{{ app_dir }}/frontend"
    state: present
  become_user: ubuntu

- name: Check for existing production build
  ansible.builtin.stat:
    path: "{{ app_dir }}/frontend/build/index.html"
  register: build_stat

- name: Build React frontend
  ansible.builtin.command: npm run build
  args:
    chdir: "{{ app_dir }}/frontend"
  environment:
    CI: "false"
    NODE_OPTIONS: "--max-old-space-size=768"   # fits t2.micro with swap
  become_user: ubuntu
  when: frontend_env.changed or not build_stat.stat.exists

- name: Install systemd unit
  ansible.builtin.template:
    src: travelmemory.service.j2
    dest: /etc/systemd/system/travelmemory.service
    mode: "0644"
  register: unit

- name: Reload systemd
  ansible.builtin.systemd:
    daemon_reload: true
  when: unit.changed

- name: Enable and start backend
  ansible.builtin.systemd:
    name: travelmemory
    state: started
    enabled: true

- name: Remove default nginx site
  ansible.builtin.file:
    path: /etc/nginx/sites-enabled/default
    state: absent
  notify: Reload nginx

- name: Install nginx site
  ansible.builtin.template:
    src: nginx.conf.j2
    dest: /etc/nginx/conf.d/travelmemory.conf
    mode: "0644"
  notify: Reload nginx

- name: Enable nginx
  ansible.builtin.service:
    name: nginx
    state: started
    enabled: true
```

### Step 15: Run the playbook

```bash
ansible-playbook site.yml --syntax-check
ansible-playbook site.yml
ansible-playbook site.yml     # second run: expect changed=0 (idempotency check)
```

On a `t2.micro` the first run takes roughly 10 to 15 minutes. Most of that is `npm install` and the React build, which are slow on 1 vCPU with swap.

---

## 6. Verification

```bash
WEB_IP=$(terraform -chdir=../terraform output -raw web_public_ip)

# 1. Frontend is served
curl -I http://$WEB_IP/

# 2. API reaches Express and MongoDB
curl http://$WEB_IP/api/trip

# 3. Create a record through the API path
curl -X POST http://$WEB_IP/api/trip \
  -H "Content-Type: application/json" \
  -d '{"tripName":"Test","startDateOfJourney":"2026-01-01","endDateOfJourney":"2026-01-05","nameOfHotels":"Hotel","placesVisited":"Pune","totalCost":1000,"tripType":"leisure","experience":"good","image":"x","shortDescription":"s","featured":false}'
```

Server-side checks (SSH in):

```bash
# Web server
systemctl status travelmemory nginx
free -h                                   # swap active
sudo ufw status verbose

# DB server (via jump host)
systemctl status mongod
ss -tlnp | grep 27017                     # bound to 127.0.0.1 and 10.0.2.x only
mongosh --quiet --eval "db.adminCommand('listDatabases')"   # must fail: auth required
sudo ufw status verbose
```

Negative tests to capture as evidence:

- SSH to the web server from a different network times out.
- `nc -zv <db_private_ip> 27017` from the laptop fails because the DB has no public path.
- `ssh root@<web_ip>` and password login are rejected.

Open `http://<web_public_ip>` in a browser, add a trip and confirm it appears in the list.

---

## 7. Security summary

| Layer | Control |
|---|---|
| Network | DB in a private subnet with no public IP; outbound only through NAT |
| Security groups | Web: 22 from my IP, 80 from anywhere. DB: 22 and 27017 from the web SG only |
| Host firewall | `ufw` default deny inbound, with the same rules repeated at host level |
| SSH | Key-only authentication, root login disabled, `MaxAuthTries 3` |
| MongoDB | Authentication on, separate admin and least-privilege app user, bound to private IP |
| Secrets | Ansible Vault for DB passwords; `.env` mode 0600; nothing secret committed |
| IAM | Role with SSM and CloudWatch policies only; IMDSv2 enforced |
| Transport | HTTP only in this assignment. Production would add TLS via a domain and ACM/Let's Encrypt |

---

## 8. t2.micro notes

- 1 GiB RAM is tight for `npm install` and the React build, so a 1 GiB swap file is created by the `common` role and Node is capped with `--max-old-space-size=768`.
- MongoDB's WiredTiger cache is capped at 0.25 GB and the backend service at 300 MB so the three processes (MongoDB, Node, Nginx) don't compete for memory.
- t2 instances are burstable. Sustained builds can exhaust CPU credits and slow down, which is normal for this assignment.
- The web server's public IP changes if the instance is stopped and started. Re-run `gen_inventory.sh` and the playbook (the frontend must be rebuilt because the IP is baked into the build). An Elastic IP avoids this.
- The NAT Gateway and its Elastic IP are billed hourly and are not covered by EC2 free-tier hours.

---

## 9. Screenshots

Stored in `docs/screenshots/`:

1. `terraform-apply.png`: successful apply with outputs
2. `aws-console-vpc.png`: VPC, subnets, route tables, IGW, NAT
3. `aws-console-ec2.png`: both t2.micro instances running
4. `security-groups.png`: web and DB inbound rules
5. `ansible-ping.png` and `ansible-playbook-run.png`: ping success and final recap
6. `ansible-idempotent.png`: second run with `changed=0`
7. `mongod-status.png` and `ss-27017.png`: MongoDB running and bound correctly
8. `app-browser.png`: working application with data
9. `negative-tests.png`: blocked SSH and blocked DB access

---

## 10. Cleanup

```bash
cd terraform
terraform destroy
```

Confirm in the AWS console that the NAT Gateway, Elastic IP, and both instances are gone.

---

## 11. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `terraform apply` fails on `aws_key_pair` | Wrong `public_key_path`, or the key name already exists in the region |
| SSH to web times out | `my_ip_cidr` is stale (your IP changed). Update tfvars and re-apply |
| `ansible ping` fails for db1 only | Jump host command wrong, or the web SG rule for port 22 is missing |
| apt/npm hangs on the DB host | Private route table is not pointing to the NAT Gateway |
| `npm run build` is killed | Swap not active. Check `free -h` and re-run the `common` role |
| Backend `MongoServerError: Authentication failed` | `authSource` missing in `MONGO_URI`, or password mismatch with the vault |
| Frontend calls `localhost` | `.env` was written after the build. Delete `frontend/build` and re-run |
| 502 from Nginx on `/api/` | Backend not running: `journalctl -u travelmemory -n 50` |

---

## 12. Submission

1. Add `.gitignore`:

   ```
   *.tfstate
   *.tfstate.*
   .terraform/
   terraform.tfvars
   tfplan
   ansible/.vault_pass
   ansible/inventory/hosts.ini
   *.pem
   id_*
   ```

2. Push to GitHub:

   ```bash
   git init && git add . && git commit -m "MERN deployment with Terraform and Ansible"
   git branch -M main
   git remote add origin https://github.com/<your-username>/<repo-name>.git
   git push -u origin main
   ```

3. Put the repository link in a `.txt`, `.docx`, or `.pdf` file and upload it on Vlearn.

## API

| Method | Path          | Description |
|--------|---------------|-------------|
| GET    | `/trip`       | List trips (featured first, newest first). Optional `?featured=true\|false`. The `experience` text is left out of the list. |
| GET    | `/trip/:id`   | Get one trip. `400` for a malformed id, `404` if it does not exist. |
| POST   | `/trip`       | Create a trip. Send JSON, or `multipart/form-data` with an optional `image` file. Returns `201` with `{ message, trip }`. |
| GET    | `/uploads/:file` | Uploaded images. |
| GET    | `/health`     | `200` when the API and database are up, `503` otherwise. |

Errors are always JSON: `{ "error": "message", "details": { "field": "reason" } }`.

Example upload:

```bash
curl -F tripName="Kyoto" -F startDateOfJourney=2024-11-02 -F endDateOfJourney=2024-11-09 \
     -F shortDescription="Temples and maple leaves" -F tripType=backpacking \
     -F image=@photo.jpg http://localhost:3001/trip
```

### Upload rules
- JPEG, PNG, GIF or WEBP only (SVG is rejected). The real file signature is checked, not only the extension/MIME type.
- Max size `MAX_UPLOAD_MB` (default 5 MB), one file per request.
- Files get a random name and are served with `X-Content-Type-Options: nosniff`.

### Security measures
- `helmet` security headers, CORS limited to `CORS_ORIGIN`, rate limiting (stricter on `POST /trip`), 100kb JSON body limit.
- Input allow-listing and validation (lengths, dates, trip type, cost, http(s)-only image links); NoSQL query sanitising.
- No internal error details are leaked to clients.
- Frontend nginx sends CSP, `X-Frame-Options`, `nosniff` and `Referrer-Policy` headers.

## Docker

```bash
# Backend (uploads are kept in a volume)
docker build -t travelmemory-be ./backend
docker run -p 3001:3001 -e MONGO_URI=... -e CORS_ORIGIN=http://localhost -v tm-uploads:/app/uploads travelmemory-be

# Frontend (the backend URL is baked in at build time)
docker build -t travelmemory-fe --build-arg REACT_APP_BACKEND_URL=http://localhost:3001 ./frontend
docker run -p 80:80 travelmemory-fe
```
