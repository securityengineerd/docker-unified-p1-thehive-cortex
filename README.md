# Unified TheHive5 + Cortex Docker Deployment + Nginx Reverse Proxy

This repository contains a **unified deployment stack** for:

- **TheHive** (Security Incident Response Platform)
- **Cortex** (Observable Analysis & Responder Engine)
- **Cassandra** (TheHive backend)
- **Elasticsearch** (TheHive & Cortex backend)
- **MinIO** (S3 storage for TheHive attachments)
- **Nginx** reverse proxy terminating HTTPS for:
  - `https://thehive.example.com`
  - `https://cortex.example.com`

All components run on **one host**, using **Docker Compose** and a **shared service network**.

This stack is designed to be:
- Production‑ready  
- Reverse‑proxied with Nginx  
- Secure by default (TLS termination enforced, app ports local‑only)  
- Automatically validated via the included init and permissions scripts  

---

# Features

### ✔ Unified Stack  
Both TheHive and Cortex run on a single machine with shared supporting services.

### ✔ Nginx Front-End  
Nginx listens on **80/443**, forcing HTTPS and reverse‑proxying to internal services.

### ✔ Secure Local-Only App Ports  
TheHive → `127.0.0.1:9000`  
Cortex → `127.0.0.1:9001`

Accessible only locally. External clients must use Nginx.

### ✔ Fully Scripted Initialization  
Includes:
- `check_permissions.sh`
- `init.sh` (sets kernel params, validates certs, validates .env, starts stack)

### ✔ TLS-Friendly  
Drop your certificates into `nginx/certs/` and you're done.

---

# Directory Structure

```
prod1-both/
│
├── docker-compose.yml
├── .env
│
├── nginx/
│   ├── conf.d/
│   │   ├── thehive.conf
│   │   └── cortex.conf
│   ├── certs/
│   │   ├── thehive.crt
│   │   ├── thehive.key
│   │   ├── cortex.crt
│   │   ├── cortex.key
│   └── log/
│
└── scripts/
    ├── init.sh
    └── check_permissions.sh
```

---

# Prerequisites

- Ubuntu 22.04 / 24.04 recommended
- Docker Engine + Docker Compose plugin
- `sysctl` access (for Elasticsearch tuning)
- Proper DNS configured:
  - `thehive.example.com` → host IP
  - `cortex.example.com` → host IP
- Valid TLS certificates

---

# Environment Variables (`.env`)

```
# FQDNs for nginx reverse proxy
THEHIVE_FQDN=thehive.example.com
CORTEX_FQDN=cortex.example.com

# Versions
ELASTIC_VERSION=8.12.2
CASSANDRA_VERSION=4.1
MINIO_VERSION=RELEASE.2024-12-18T00-00-00Z
THEHIVE_VERSION=5.5.0
CORTEX_VERSION=3.1.0

# Secrets
THEHIVE_SECRET=CHANGE_ME_64CHARS
MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=CHANGE_ME_MINIO
CORTEX_API_KEY=CHANGE_ME_CORTEX_KEY
CORTEX_SECRET=CHANGE_ME_CORTEX_SECRET
```

---

# Deployment

## 1. Place your TLS certificates

Place these inside:
```
nginx/certs/
```
Required:
- thehive.crt / thehive.key
- cortex.crt / cortex.key

## 2. Make scripts executable
```
chmod +x scripts/*.sh
```

## 3. Run initialization
```
./scripts/init.sh
```

## 4. Access services
- https://thehive.example.com
- https://cortex.example.com

---

# Security Model

### Nginx Terminates TLS  
All clients must use HTTPS.

### Internal Services Are Local-Only  
TheHive: 127.0.0.1:9000  
Cortex: 127.0.0.1:9001

### Secrets Protection  
Scripts enforce restrictive permissions.

### Elasticsearch Kernel Requirements  
`vm.max_map_count=262144` is applied automatically.

---

# Management
```
docker compose up -d
docker compose down
docker compose logs -f nginx
```

---

# Data Persistence

- elasticsearch_data
- cassandra_data
- minio_data
- cortex_jobs
- thehive_data

---

# You're All Set
A production‑ready, secure deployment of TheHive + Cortex behind Nginx.


