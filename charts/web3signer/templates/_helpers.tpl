{{/*
Expand the name of the chart.
*/}}
{{- define "web3signer.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "web3signer.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "web3signer.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "web3signer.labels" -}}
helm.sh/chart: {{ include "web3signer.chart" . }}
{{ include "web3signer.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "web3signer.selectorLabels" -}}
app.kubernetes.io/name: {{ include "web3signer.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "web3signer.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "web3signer.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}


{{/* Decrypt secret init container — decrypts ENCRYPTED_DECRYPTION_KEY via AWS KMS or Azure KV */}}
{{- define "web3signer.decryptSecretInitContainer" -}}
{{- $provider := .Values.encryptedDecryptionKey.provider -}}
- name: decrypt-secret
  {{- if eq $provider "aws" }}
  image: "{{ .Values.encryptedDecryptionKey.awsImage.registry }}/{{ .Values.encryptedDecryptionKey.awsImage.repository }}:{{ .Values.encryptedDecryptionKey.awsImage.tag }}"
  imagePullPolicy: {{ .Values.encryptedDecryptionKey.awsImage.pullPolicy }}
  {{- else if eq $provider "azure" }}
  image: "{{ .Values.encryptedDecryptionKey.azureImage.registry }}/{{ .Values.encryptedDecryptionKey.azureImage.repository }}:{{ .Values.encryptedDecryptionKey.azureImage.tag }}"
  imagePullPolicy: {{ .Values.encryptedDecryptionKey.azureImage.pullPolicy }}
  {{- end }}
  command:
    - /bin/sh
    - -c
    - |
      set -e
      {{- if eq $provider "aws" }}
      echo "Decrypting secret using AWS KMS..."
      {{- if .Values.encryptedDecryptionKey.aws.roleArn }}
      echo "Assuming role: $AWS_ROLE_ARN"
      CREDS=$(aws sts assume-role --role-arn "$AWS_ROLE_ARN" --role-session-name decrypt-session --output json)
      export AWS_ACCESS_KEY_ID=$(echo $CREDS | sed -n 's/.*"AccessKeyId": "\([^"]*\)".*/\1/p')
      export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | sed -n 's/.*"SecretAccessKey": "\([^"]*\)".*/\1/p')
      export AWS_SESSION_TOKEN=$(echo $CREDS | sed -n 's/.*"SessionToken": "\([^"]*\)".*/\1/p')
      {{- end }}
      echo "$ENCRYPTED_DECRYPTION_KEY" | base64 -d > /tmp/ciphertext.bin
      # Leave the value base64-encoded: the contract asserted below is that
      # /decrypted-secrets/DECRYPTION_KEY holds base64, never raw key bytes. Decoding here made
      # this branch write raw bytes, which sync-keys then base64-decoded again
      # (utils.str_to_bytes), so every key was rejected -- not an occasional one. The Azure
      # branch never had the bug because it writes the base64 its decrypt call returns.
      #
      # Raw bytes could not have worked anyway: the value passes through two command
      # substitutions before sync-keys sees it, and the shell drops every NUL byte and strips
      # trailing newlines, so a 32-byte key arrives one byte short per NUL. Base64 is ASCII and
      # survives both.
      DECRYPTED=$(aws kms decrypt \
        --region "$AWS_REGION" \
        --ciphertext-blob fileb:///tmp/ciphertext.bin \
        --output text \
        --query Plaintext)
      rm -f /tmp/ciphertext.bin
      {{- else if eq $provider "azure" }}
      echo "Decrypting secret using Azure Key Vault..."
      if [ -f "$AZURE_FEDERATED_TOKEN_FILE" ]; then
        az login --federated-token "$(cat $AZURE_FEDERATED_TOKEN_FILE)" \
          --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" --allow-no-subscriptions
      else
        {{- if .Values.encryptedDecryptionKey.azure.clientId }}
        az login --identity --allow-no-subscriptions --client-id "$AZURE_CLIENT_ID"
        {{- else }}
        az login --identity --allow-no-subscriptions
        {{- end }}
      fi
      {{- if .Values.encryptedDecryptionKey.useKeyVaultSecrets }}
      if ! command -v psql > /dev/null 2>&1; then
        if command -v apk > /dev/null 2>&1; then apk add --no-cache postgresql16-client > /dev/null 2>&1
        elif command -v tdnf > /dev/null 2>&1; then tdnf install -y postgresql-libs > /dev/null 2>&1
        fi
      fi
      echo "Fetching secrets from Key Vault..."
      DB_PASSWORD=$(az keyvault secret show --vault-name "$AZURE_VAULT_NAME" --name "$KV_SECRET_DB_PASSWORD" --query value -o tsv)
      DB_KEYSTORE_URL=$(az keyvault secret show --vault-name "$AZURE_VAULT_NAME" --name "$KV_SECRET_DB_KEYSTORE_URL" --query value -o tsv)
      echo "Querying ciphertext from KOS DB for client_cluster_id=$CLIENT_CLUSTER_ID"
      CIPHERTEXT=$(psql "$DB_KEYSTORE_URL" -tA -c "SELECT encrypted_encryption_key FROM encrypted_encryption_keys WHERE client_cluster_id = '$CLIENT_CLUSTER_ID' AND status = 5 LIMIT 1")
      [ -z "$CIPHERTEXT" ] && echo "ERROR: No encryption key found for client_cluster_id=$CLIENT_CLUSTER_ID" && exit 1
      {{- else }}
      CIPHERTEXT=$(echo "$ENCRYPTED_DECRYPTION_KEY" | tr -d '[:space:]')
      {{- end }}
      # base64url -> standard base64 + padding
      CIPHERTEXT=$(echo "$CIPHERTEXT" | tr '_-' '/+')
      case $((${#CIPHERTEXT} % 4)) in 2) CIPHERTEXT="${CIPHERTEXT}==" ;; 3) CIPHERTEXT="${CIPHERTEXT}=" ;; esac
      echo "Ciphertext length: ${#CIPHERTEXT}"
      DECRYPTED=$(az keyvault key decrypt \
        --name "$AZURE_KEY_NAME" \
        --vault-name "$AZURE_VAULT_NAME" \
        --algorithm "$AZURE_ALGORITHM" \
        --value "$CIPHERTEXT" \
        {{- if .Values.encryptedDecryptionKey.azure.keyVersion }}
        --version "$AZURE_KEY_VERSION" \
        {{- end }}
        --query result --output tsv)
      {{- end }}
      # Single point where every provider branch converges, so this is where the encoding
      # contract belongs. Both decrypt calls already return standard base64 and sync-keys
      # base64-decodes what it reads, so a value that does not decode to a valid AES key length
      # means a branch above got it wrong. Checking it here fails at the cause with a clear
      # message rather than as an opaque error inside sync-keys, and it covers both ways this
      # has gone wrong: raw bytes instead of base64 (decodes to 0) and a key shortened by the
      # shell eating a NUL (decodes to 31).
      DECODED_LEN=$(printf '%s' "$DECRYPTED" | base64 -d 2>/dev/null | wc -c | tr -d ' ')
      case "$DECODED_LEN" in
        16|24|32) ;;
        *)
          echo "ERROR: decrypted DECRYPTION_KEY is not base64 of a 16/24/32-byte AES key" >&2
          echo "ERROR: decoded to ${DECODED_LEN} bytes; expected base64 text, not raw key bytes" >&2
          exit 1
          ;;
      esac
      echo -n "$DECRYPTED" > /decrypted-secrets/DECRYPTION_KEY
      {{- if and (eq $provider "azure") .Values.encryptedDecryptionKey.useKeyVaultSecrets }}
      echo -n "$DB_PASSWORD" > /decrypted-secrets/DB_PASSWORD
      echo -n "$DB_KEYSTORE_URL" > /decrypted-secrets/DB_KEYSTORE_URL
      {{- end }}
      chmod 400 /decrypted-secrets/*
      chown 1000:1000 /decrypted-secrets/*
      echo "Secret decryption completed successfully"
  envFrom:
    - secretRef:
        name: {{ include "common.names.fullname" . }}
  securityContext:
    runAsUser: 0
  volumeMounts:
    - name: decrypted-secrets
      mountPath: /decrypted-secrets
{{- end -}}

{{- define "web3signer.initContainer" -}}
{{- if not .container.name -}}
  {{- fail "Init container name is required but not provided" -}}
{{- end -}}
{{- $mainImage := .root.Values.image -}}
{{- $useEncryptedSecret := and .root.Values.encryptedDecryptionKey.enabled .container.usesDecryptedSecret -}}
{{- $useKeyVaultSecrets := and $useEncryptedSecret .root.Values.encryptedDecryptionKey.useKeyVaultSecrets -}}
{{- $isFetchKeys := eq .container.name "fetch-keys" -}}
{{- $isMigrations := eq .container.name "migrations" -}}
{{- /*
  Extra sync-keys flags for the fetch-keys container. Built once here because there are two
  arg-rendering paths below -- the encryptedDecryptionKey one that execs through a shell, and
  the plain command/args one -- and a flag appended to only one of them is silently dropped on
  every release that happens to use the other.
*/ -}}
{{- $fetchKeysFlags := list -}}
{{- if $isFetchKeys -}}
  {{- if .root.Values.dbKeystoreTableName -}}
    {{- $fetchKeysFlags = concat $fetchKeysFlags (list "--table-name" .root.Values.dbKeystoreTableName) -}}
  {{- end -}}
{{- end -}}

- name: {{ .container.name }}
  {{- if .container.image }}
  {{- if typeIs "string" .container.image }}
  image: {{ .container.image }}
  {{- else }}
  image: "{{ .container.image.registry }}/{{ .container.image.repository }}:{{ .container.image.tag }}"
  {{- end }}
  imagePullPolicy: {{ .container.image.pullPolicy | default $mainImage.pullPolicy }}
  {{- else }}
  image: "{{ $mainImage.registry }}/{{ $mainImage.repository }}:{{ $mainImage.tag | default .root.Chart.AppVersion }}"
  imagePullPolicy: {{ $mainImage.pullPolicy }}
  {{- end }}
  {{- if $useEncryptedSecret }}
  {{- $renderedArgs := list }}
  {{- range .container.args }}
  {{- $renderedArgs = append $renderedArgs (tpl . $.root) }}
  {{- end }}
  {{- $renderedArgs = concat $renderedArgs $fetchKeysFlags }}
  {{- if and $isFetchKeys $useKeyVaultSecrets (not .root.Values.dbKeystoreUrl) }}
  {{- $renderedArgs = append $renderedArgs "--db-url" }}
  {{- $renderedArgs = append $renderedArgs "$DB_KEYSTORE_URL" }}
  {{- end }}
  command:
    - /bin/sh
    - -c
    - |
      set -e
      export DECRYPTION_KEY=$(cat /decrypted-secrets/DECRYPTION_KEY)
      {{- if $useKeyVaultSecrets }}
      export DB_PASSWORD=$(cat /decrypted-secrets/DB_PASSWORD)
      export DB_KEYSTORE_URL=$(cat /decrypted-secrets/DB_KEYSTORE_URL)
      {{- end }}
      {{- if $isMigrations }}
      {{- if $useKeyVaultSecrets }}
      export FLYWAY_PASSWORD="$DB_PASSWORD"
      {{- else }}
      export FLYWAY_PASSWORD={{ .root.Values.dbPassword | quote }}
      {{- end }}
      {{- end }}
      {{- if .container.command }}
      exec {{ range .container.command }}{{ tpl . $.root | quote }} {{ end }}{{ range $renderedArgs }}{{ . | quote }} {{ end }}
      {{- else if .container.args }}
      exec {{ range $renderedArgs }}{{ . | quote }} {{ end }}
      {{- else }}
      echo "Error: No command or args specified for container with usesDecryptedSecret"
      exit 1
      {{- end }}
  {{- else }}
  {{- if .container.command }}
  command:
    {{- (tpl (toYaml .container.command) .root) | nindent 4 }}
  {{- end }}
  {{- if or .container.args $fetchKeysFlags }}
  args:
    {{- if .container.args }}
    {{- (tpl (toYaml .container.args) .root) | nindent 2 }}
    {{- end }}
    {{- if $fetchKeysFlags }}
    {{- (toYaml $fetchKeysFlags) | nindent 2 }}
    {{- end }}
  {{- end }}
  {{- end }}
  {{- if .container.workingDir }}
  workingDir: {{ .container.workingDir }}
  {{- end }}
  {{- if or .container.env (and $isMigrations (not $useEncryptedSecret)) }}
  env:
    {{- if .container.env }}
    {{- (tpl (toYaml .container.env) .root) | nindent 2 }}
    {{- end }}
    {{- if and $isMigrations (not $useEncryptedSecret) }}
    {{- (list (dict "name" "FLYWAY_PASSWORD" "value" .root.Values.dbPassword) | toYaml) | nindent 2 }}
    {{- end }}
  {{- end }}
  {{- if and .container.envFrom (not $useEncryptedSecret) }}
  envFrom:
    {{- (tpl (toYaml .container.envFrom) .root) | nindent 4 }}
  {{- end }}
  {{- if .container.ports }}
  ports:
    {{- (tpl (toYaml .container.ports) .root) | nindent 4 }}
  {{- end }}
  securityContext:
    {{- toYaml (.container.securityContext | default .root.Values.securityContext) | nindent 4 }}
  {{- if .container.resources }}
  resources:
    {{- toYaml .container.resources | nindent 4 }}
  {{- end }}
  volumeMounts:
  {{- if .container.volumeMounts }}
    {{- tpl (toYaml .container.volumeMounts) .root | nindent 4 }}
  {{- end }}
  {{- if $useEncryptedSecret }}
    - name: decrypted-secrets
      mountPath: /decrypted-secrets
      readOnly: true
  {{- end }}
  {{- if .container.restartPolicy }}
  restartPolicy: {{ .container.restartPolicy }}
  {{- end }}
{{- end -}}
