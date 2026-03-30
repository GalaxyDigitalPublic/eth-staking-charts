# Web3Signer Helm Chart

This Helm chart deploys [Web3Signer](https://docs.web3signer.consensys.net/) for Ethereum validator key management.

## Prerequisites

- Kubernetes 1.18+
- Helm 3.0+
- PostgreSQL database for keystore and slashing protection

## Installation

```console
helm repo add gdstaking https://charts.staking.galaxy.com/

helm repo update

helm upgrade --install web3signer gdstaking/web3signer \
  --namespace web3signer \
  --create-namespace \
  --set dbKeystoreUrl="postgresql://user:pass@host/dbname" \
  --set decryptionKey="your-decryption-key"
```

## Configuration

See `values.yaml` for the full list of configuration options.

### Key Configuration Options

| Parameter | Description | Default |
|-----------|-------------|---------|
| `replicaCount` | Number of replicas | `3` |
| `network` | Ethereum network (mainnet, prater, gnosis) | `mainnet` |
| `decryptionKey` | Plain text key for decrypting validator private keys | `""` |
| `dbKeystoreUrl` | PostgreSQL connection string for keystore | `""` |
| `dbUrl` | JDBC URL for slashing protection database | `jdbc:postgresql://localhost/web3signer` |
| `encryptedDecryptionKey.enabled` | Enable encrypted decryption key mode | `false` |

## Encrypted Decryption Key

For enhanced security, you can store the decryption key encrypted and have it decrypted at runtime using AWS KMS or Azure Key Vault. This ensures:

1. The secret is encrypted at rest in Kubernetes secrets
2. Decryption only happens at pod startup via cloud KMS
3. The decrypted value is stored in a memory-backed volume (never on disk)
4. If the pod restarts, the init container must run again to decrypt

### AWS KMS Setup

#### Prerequisites

1. Create a KMS key in your AWS account
2. Create an IAM role with `kms:Decrypt` permission for the key
3. Configure IRSA (IAM Roles for Service Accounts) for your EKS cluster
4. Encrypt your decryption key:

```bash
aws kms encrypt \
  --key-id alias/web3signer-key \
  --plaintext "your-decryption-key" \
  --output text \
  --query CiphertextBlob
```

#### Configuration

```yaml
# Disable plain text mode
decryptionKey: ""

# Enable encrypted mode with AWS KMS
encryptedDecryptionKey:
  enabled: true
  ciphertext: "AQICAHh...your-base64-ciphertext..."
  provider: "aws"
  aws:
    region: "us-east-1"
    keyId: "alias/web3signer-key"
    # Optional: for cross-account access
    # roleArn: "arn:aws:iam::123456789012:role/cross-account-role"

# Configure service account with IRSA
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/web3signer-kms-role
```

#### IAM Policy Example

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "kms:Decrypt",
      "Resource": "arn:aws:kms:us-east-1:123456789012:key/your-key-id"
    }
  ]
}
```

### Azure Key Vault Setup

#### Prerequisites

1. Create an Azure Key Vault and a key within it
2. Configure Workload Identity or Pod Identity for your AKS cluster
3. Grant the managed identity "Key Vault Crypto User" role on the key
4. Encrypt your decryption key:

```bash
# First, encode your key to base64
echo -n "your-decryption-key" | base64

# Then encrypt using Azure CLI
az keyvault key encrypt \
  --name web3signer-key \
  --vault-name my-keyvault \
  --algorithm RSA-OAEP-256 \
  --value "eW91ci1kZWNyeXB0aW9uLWtleQ==" \
  --query result \
  --output tsv
```

#### Configuration

```yaml
# Disable plain text mode
decryptionKey: ""

# Enable encrypted mode with Azure Key Vault
encryptedDecryptionKey:
  enabled: true
  ciphertext: "your-encrypted-base64-value"
  provider: "azure"
  azure:
    vaultName: "my-keyvault"
    keyName: "web3signer-key"
    # Optional: specific key version (uses latest if empty)
    # keyVersion: "abc123"
    algorithm: "RSA-OAEP-256"

# Configure pod annotations for Workload Identity (example)
podAnnotations:
  azure.workload.identity/use: "true"

serviceAccount:
  annotations:
    azure.workload.identity/client-id: "your-managed-identity-client-id"
```

### Azure Key Vault Secrets Mode (`useKeyVaultSecrets`)

Eliminates **all** sensitive data from K8s secrets. Instead of storing the ciphertext in K8s, it is queried directly from the KOS database. DB password and keystore URL are fetched from KV secrets at runtime.

#### Prerequisites

1. **Azure Key Vault secrets** — store the DB password and keystore URL as secrets in your vault:
   ```bash
   az keyvault secret set --vault-name my-keyvault --name w3s-db-password --value "your-db-password"
   az keyvault secret set --vault-name my-keyvault --name w3s-db-keystore-url --value "postgresql://user:pass@host/db"
   ```
2. **Database permissions** — the DB user needs SELECT on the ciphertext table:
   ```sql
   GRANT SELECT ON TABLE encrypted_encryption_keys TO your_db_user;
   ```
3. **Workload Identity** — the managed identity needs both:
   - `Key Vault Crypto User` (for key decrypt)
   - `Key Vault Secrets User` (for secret read)

#### Configuration

```yaml
encryptedDecryptionKey:
  enabled: true
  provider: "azure"
  useKeyVaultSecrets: true
  clientClusterId: "your-client-cluster-id"
  keyVaultSecrets:
    dbPassword: "w3s-db-password"
    dbKeystoreUrl: "w3s-db-keystore-url"
  azure:
    vaultName: "my-keyvault"
    keyName: "kos-encryption-key"
    algorithm: "RSA-OAEP-256"
    clientId: "your-managed-identity-client-id"

# Shell variables — expanded at runtime by the init container wrapper
dbKeystoreUrl: "$DB_KEYSTORE_URL"
dbPassword: "$DB_PASSWORD"
```

#### How It Works

```
Pod Startup Flow (useKeyVaultSecrets):

  decrypt-secret init container:
    1. az login (Workload Identity)
    2. Fetch DB password from KV
    3. Fetch keystore URL from KV
    4. psql "$DB_KEYSTORE_URL" → query ciphertext from encrypted_encryption_keys
    5. az keyvault key decrypt → decrypt ciphertext
    6. Write DECRYPTION_KEY, DB_PASSWORD, DB_KEYSTORE_URL to /decrypted-secrets/

  fetch-keys:    reads $DB_KEYSTORE_URL and $DECRYPTION_KEY from /decrypted-secrets/
  migrations:    reads $DB_PASSWORD from /decrypted-secrets/
  web3signer:    reads DB_PASSWORD → WEB3SIGNER_ETH2_SLASHING_PROTECTION_DB_PASSWORD
```

The K8s secret only contains non-sensitive metadata (KV secret names, client cluster ID, Azure config).

### How It Works (Standard Mode)

When `encryptedDecryptionKey.enabled=true` without `useKeyVaultSecrets`:

1. A `decrypt-secret` init container is automatically injected before other init containers
2. This container uses AWS CLI or Azure CLI (depending on provider) to decrypt the ciphertext
3. The decrypted value is written to `/decrypted-secrets/DECRYPTION_KEY` (memory-backed volume)
4. The `fetch-keys` container reads the decryption key from this file instead of environment variables
5. On pod restart, the entire process repeats (key is never persisted)

## Init Containers

The chart uses init containers to prepare the environment. Default containers:

1. **init** - Creates data directories and sets permissions
2. **fetch-keys** - Fetches validator keys from the database
3. **copy-migrations** - Copies database migration files
4. **migrations** - Runs Flyway database migrations

### Custom Init Containers

You can customize init containers by overriding the `initContainers` list in values.yaml. Note that you must include ALL containers you want (the list replaces defaults entirely).

For containers that need access to the decrypted secret, add `usesDecryptedSecret: true`:

```yaml
initContainers:
  - name: my-custom-container
    usesDecryptedSecret: true  # Will auto-mount decrypted-secrets volume
    image:
      registry: "docker.io"
      repository: "my-image"
      tag: "latest"
    args:
      - my-command
      - --some-arg
```

## License

AGPL-3.0
