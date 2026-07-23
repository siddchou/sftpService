# SFTP Service

Bash-based SFTP job runner for automated file uploads and downloads with support for multiple environments, encrypted credentials, retry logic, and log rotation.

## Architecture

```
sftp-service/
├── config/
│   ├── defaults.conf          # Global defaults (timeouts, dirs, retries)
│   ├── env/                   # Per-environment overrides
│   │   ├── dev.conf
│   │   ├── sit.conf
│   │   ├── uat.conf
│   │   └── prod.conf
│   ├── sftp-jobs.yml          # Base job definitions
│   ├── sftp-jobs.{env}.yml    # Per-environment job overrides
│   ├── credentials.yml.example
│   └── credentials.{env}.yml  # Encrypted credentials (git-ignored)
├── lib/
│   ├── common.sh              # Logging, log rotation, arg parsing, utils
│   ├── credential.sh          # AES-256-GCM encrypt/decrypt, credential store
│   └── sftp-core.sh           # Connect, upload, download primitives
├── scripts/
│   ├── sftp-run.sh            # Main entry point — run any job
│   ├── sftp-upload.sh         # Convenience wrapper for UPLOAD jobs
│   ├── sftp-download.sh       # Convenience wrapper for DOWNLOAD jobs
│   └── sftp-credential.sh     # Credential management CLI
└── keys/                      # SSH key pairs (git-ignored)
```

## Prerequisites

- **Bash** 4.4+ (for associative arrays)
- **OpenSSH** client (`sftp`, `ssh`, `ssh-keygen`)
- **yq** (YAML processor — go-yq variant)
- **OpenSSL** (for credential encryption)
- **sshpass** (optional, required only for PASSWORD-type credentials)

## Quick Start

### 1. Set the encryption key

```bash
export ORCHESTRATOR_ENCRYPTION_KEY="$(openssl rand -hex 32)"
```

This 32-byte hex key is used by AES-256-GCM to encrypt/decrypt all stored credentials. Store it in a secrets manager or environment config — never commit it.

### 2. Define a job

Edit `config/sftp-jobs.yml` and add a job entry:

```yaml
jobs:
  - name: upload-reports
    host: sftp.example.com
    port: 22
    username: deployer
    credential_ref: prod_sftp_key
    remote_dir: /incoming/reports
    file_pattern: "*.csv"
    direction: UPLOAD
    remote_file_name: "${fileName}_${timestamp}.${fileExtension}"
    working_dir: /opt/sftp-service/data/reports
```

Fields:

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Unique job identifier |
| `host` | Yes | SFTP server hostname or IP |
| `port` | No | SSH port (default: 22) |
| `username` | Yes | Remote user |
| `credential_ref` | Yes | Reference key into credentials store |
| `remote_dir` | Yes | Remote working directory |
| `file_pattern` | Yes | Glob pattern for files to transfer |
| `direction` | Yes | `UPLOAD` or `DOWNLOAD` |
| `remote_file_name` | No | Rename template (UPLOAD). Placeholders: `${fileName}`, `${fileExtension}`, `${timestamp}` |
| `working_dir` | No | Local staging directory (default: `SFTP_WORKING_DIR`) |
| `conn_timeout` | No | Connection timeout in seconds |
| `auth_timeout` | No | Authentication timeout in seconds |

### 3. Add a credential

```bash
# SSH key authentication
./scripts/sftp-credential.sh add prod_sftp_key SSH_KEY "/opt/sftp-service/keys/prod_ed25519"

# Password authentication
./scripts/sftp-credential.sh add my_password PASSWORD "secret123"
```

Credentials are encrypted with AES-256-GCM and stored in `config/credentials.yml` (or `credentials.{env}.yml`).

### 4. Run a job

```bash
# Run with default environment
./scripts/sftp-run.sh upload-reports

# Run with specific environment
./scripts/sftp-run.sh -e prod upload-reports

# Convenience wrappers
./scripts/sftp-upload.sh -e prod upload-reports
./scripts/sftp-download.sh -e dev fetch-backups
```

## Examples

### Example 1: Upload CSV reports to a remote server via SSH key

```bash
# Generate an SSH key
./scripts/sftp-credential.sh gen-key reports-server ed25519

# Store the key path as a credential
./scripts/sftp-credential.sh -e prod add reports_key SSH_KEY "/opt/sftp-service/keys/reports-server"

# Define the job in config/sftp-jobs.yml:
#
# jobs:
#   - name: upload-reports
#     host: sftp.example.com
#     port: 22
#     username: deployer
#     credential_ref: reports_key
#     remote_dir: /incoming/reports
#     file_pattern: "*.csv"
#     direction: UPLOAD
#     remote_file_name: "${fileName}_${timestamp}.${fileExtension}"
#     working_dir: /opt/sftp-service/data/reports

# Place your CSV files in the working directory
mkdir -p /opt/sftp-service/data/reports
cp sales-2026.csv /opt/sftp-service/data/reports/

# Run the upload
./scripts/sftp-upload.sh -e prod upload-reports
```

The file `sales-2026.csv` will be uploaded as `sales-2026_20260722_143052.csv`.

### Example 2: Download daily backup archives via password auth

```bash
# Store the password as a credential
./scripts/sftp-credential.sh -e prod add backup_pass PASSWORD "MyS3cretP@ss"

# Define the job in config/sftp-jobs.yml:
#
# jobs:
#   - name: fetch-backups
#     host: backup.internal.net
#     port: 2222
#     username: backup-agent
#     credential_ref: backup_pass
#     remote_dir: /exports/daily
#     file_pattern: "backup_*.tar.gz"
#     direction: DOWNLOAD
#     working_dir: /opt/sftp-service/data/backups

# Run the download
./scripts/sftp-download.sh -e prod fetch-backups
```

All files matching `backup_*.tar.gz` from the remote `/exports/daily` directory will be downloaded locally.

### Example 3: Run the same job across environments

Define a base job in `config/sftp-jobs.yml`:

```yaml
jobs:
  - name: sync-data
    host: sftp.dev.example.com
    username: data-user
    credential_ref: dev_key
    remote_dir: /data
    file_pattern: "*.json"
    direction: UPLOAD
    working_dir: /opt/sftp-service/data/sync
```

Then override the host per environment in `config/sftp-jobs.prod.yml`:

```yaml
jobs:
  - name: sync-data
    host: sftp.prod.example.com
    credential_ref: prod_key
```

Run against each environment:

```bash
./scripts/sftp-run.sh -e dev sync-data    # hits sftp.dev.example.com
./scripts/sftp-run.sh -e prod sync-data   # hits sftp.prod.example.com
```

The environment-specific config merges with the base — only `host` and `credential_ref` change, all other fields are inherited.

### Example 4: Set up a complete new environment

```bash
# 1. Create environment config
cat > config/env/staging.conf <<'EOF'
SFTP_DEFAULT_PORT=22
SFTP_CONN_TIMEOUT=20
SFTP_STRICT_HOST=true
SFTP_LOG_RETENTION_DAYS=14
SFTP_WORKING_DIR="/opt/sftp-service/data/staging"
SFTP_LOG_DIR="/opt/sftp-service/logs/staging"
SFTP_KEYS_DIR="/opt/sftp-service/keys/staging"
EOF

# 2. Create job overrides
cat > config/sftp-jobs.staging.yml <<'EOF'
jobs:
  - name: upload-reports
    host: sftp.staging.example.com
    credential_ref: staging_key
EOF

# 3. Create credential store
echo 'credentials: []' > config/credentials.staging.yml

# 4. Add credentials
./scripts/sftp-credential.sh -e staging gen-key staging-server ed25519
./scripts/sftp-credential.sh -e staging add staging_key SSH_KEY "/opt/sftp-service/keys/staging/staging-server"

# 5. Run
./scripts/sftp-run.sh -e staging upload-reports
```

### Example 5: Customize timeouts and retries

```bash
# Override defaults for a slow connection
export SFTP_CONN_TIMEOUT=60
export SFTP_TRANSFER_TIMEOUT=600
export SFTP_MAX_RETRIES=5
export SFTP_RETRY_DELAY=10

./scripts/sftp-run.sh -e prod upload-reports
```

### Example 6: Enable debug logging

```bash
export SFTP_DEBUG=true
./scripts/sftp-run.sh -e dev upload-reports
```

Debug messages will appear in both the console output and the log file.

### Example 7: Manage credentials

```bash
# List all credentials for an environment (safe — does not show values)
./scripts/sftp-credential.sh -e prod list

# Add a password credential
./scripts/sftp-credential.sh -e dev add dev_api_pass PASSWORD "dev-password-here"

# Update an existing credential (same ref overwrites the encrypted value)
./scripts/sftp-credential.sh -e dev add dev_api_pass PASSWORD "new-password"

# Remove a credential
./scripts/sftp-credential.sh -e dev delete dev_api_pass

# Generate different key types
./scripts/sftp-credential.sh gen-key legacy-server rsa-4096
./scripts/sftp-credential.sh gen-key modern-server ed25519
```

## Multi-Environment Support

The service supports four environments: `dev`, `sit`, `uat`, `prod`.

Each environment has its own:

- **Config overrides** — `config/env/{env}.conf` (timeouts, directories, strict host checking)
- **Job definitions** — `config/sftp-jobs.{env}.yml` (merged with base, env values win)
- **Credentials** — `config/credentials.{env}.yml` (separate credential store per env)

To add a new environment:

1. Copy `config/env/dev.conf` to `config/env/myenv.conf` and adjust values
2. Create `config/sftp-jobs.myenv.yml` with job overrides
3. Create `config/credentials.myenv.yml` with the header `credentials: []`

## Credential Management

```bash
# Add credential
./scripts/sftp-credential.sh -e prod add <ref> <PASSWORD|SSH_KEY> <value>

# List credentials (shows refs and types, not values)
./scripts/sftp-credential.sh -e prod list

# Delete credential
./scripts/sftp-credential.sh -e prod delete <ref>

# Generate SSH key pair
./scripts/sftp-credential.sh gen-key myserver ed25519
./scripts/sftp-credential.sh gen-key myserver rsa-4096

# Encrypt/decrypt standalone values
./scripts/sftp-credential.sh encrypt "my-secret"
./scripts/sftp-credential.sh decrypt "ENC[AESGCM;...]"
```

## Configuration

All defaults from `config/defaults.conf` can be overridden via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `SFTP_DEFAULT_PORT` | 22 | Default SSH port |
| `SFTP_CONN_TIMEOUT` | 30 | Connection timeout (seconds) |
| `SFTP_AUTH_TIMEOUT` | 30 | Authentication timeout (seconds) |
| `SFTP_TRANSFER_TIMEOUT` | 300 | Transfer timeout (seconds) |
| `SFTP_WORKING_DIR` | /opt/sftp-service/data | Local staging directory |
| `SFTP_LOG_DIR` | /opt/sftp-service/logs | Log directory |
| `SFTP_KEYS_DIR` | /opt/sftp-service/keys | SSH keys directory |
| `SFTP_KNOWN_HOSTS` | /opt/sftp-service/.ssh/known_hosts | Known hosts file |
| `SFTP_STRICT_HOST` | true | Strict host key checking |
| `SFTP_MAX_RETRIES` | 3 | Max retry attempts |
| `SFTP_RETRY_DELAY` | 5 | Delay between retries (seconds) |
| `SFTP_LOG_RETENTION_DAYS` | 30 | Log retention period |
| `SFTP_LOG_MAX_SIZE_KB` | 10240 | Max log file size before rotation |
| `SFTP_DEBUG` | false | Enable debug logging |
| `ORCHESTRATOR_ENCRYPTION_KEY` | *(required)* | 64-char hex string for AES-256 |

## Logging

- Per-job log files are written to `SFTP_LOG_DIR` with the naming pattern `{env}_{job}_{date}.log`
- Logs are also printed to stdout
- Automatic log rotation by age (default: 30 days) and size (default: 10MB)
- Old logs are compressed with gzip

## Security

- Credentials are encrypted at rest using AES-256-GCM
- `credentials*.yml` and `keys/` are git-ignored
- SSH key checking is enabled by default (disabled for dev profile)
- Password auth requires `sshpass` and is only used when explicitly configured
- Batch mode is used for all SFTP transfers (no interactive prompts)

## Retry Behavior

Each file transfer is retried up to `SFTP_MAX_RETRIES` times with `SFTP_RETRY_DELAY` seconds between attempts. The overall transfer is bounded by `SFTP_TRANSFER_TIMEOUT`.

## Signal Handling

Press `Ctrl+C` during a transfer to gracefully cancel. The current file transfer will finish, and a cancellation summary will be logged.
