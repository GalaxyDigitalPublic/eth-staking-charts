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


{{/*
Generic init container template
Usage in template:
{{ $root := $ }}
{{ range .Values.initContainers }}
{{ include "web3signer.initContainer" (dict "root" $root "container" .) | nindent 6 }}
{{ end }}

Container object structure:
  name: string (required)
  image: object/string (optional)
    - If object: (defaults to main container image values)
    - If object:
      registry: string (optional)
      repository: string (optional)
      tag: string (optional)
      pullPolicy: string (optional)
    - If string: full image path
  command: []string (optional - if not set, container's default ENTRYPOINT is used)
  args: []string (optional - if args contain templates they will be rendered)
  env: []object (optional - if templates they will be rendered)
  envFrom: []object (optional - if templates they will be rendered)
  securityContext: object (optional - defaults to main container securityContext)
  resources: object (optional)
  volumeMounts: []object (optional - if templates they will be rendered)
  workingDir: string (optional)
  ports: []object (optional - if templates they will be rendered)
  restartPolicy: string (optional)
*/}}
{{/*
Decrypt secret init container template
This container decrypts the ENCRYPTED_DECRYPTION_KEY using AWS KMS or Azure Key Vault
and writes the decrypted value to /decrypted-secrets/DECRYPTION_KEY

AWS: Uses IRSA (IAM Roles for Service Accounts) - credentials are automatically
     provided via the service account's projected token. Ensure your service account
     is annotated with the appropriate IAM role ARN.

Azure: Uses Managed Identity (Workload Identity or Pod Identity) - requires
       az login --identity to authenticate before accessing Key Vault.
*/}}
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
      echo "Decrypting secret using AWS KMS (via IRSA)..."
      # AWS credentials are provided automatically via IRSA
      # The service account must be annotated with: eks.amazonaws.com/role-arn: <IAM_ROLE_ARN>
      # and the IAM role must have kms:Decrypt permission for the specified key
      {{- if .Values.encryptedDecryptionKey.aws.roleArn }}
      # Assume role for cross-account access (if needed beyond IRSA)
      echo "Assuming role: $AWS_ROLE_ARN"
      CREDS=$(aws sts assume-role --role-arn "$AWS_ROLE_ARN" --role-session-name decrypt-session --output json)
      export AWS_ACCESS_KEY_ID=$(echo $CREDS | sed -n 's/.*"AccessKeyId": "\([^"]*\)".*/\1/p')
      export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | sed -n 's/.*"SecretAccessKey": "\([^"]*\)".*/\1/p')
      export AWS_SESSION_TOKEN=$(echo $CREDS | sed -n 's/.*"SessionToken": "\([^"]*\)".*/\1/p')
      {{- end }}
      # Decode base64 ciphertext and decrypt with KMS
      echo "$ENCRYPTED_DECRYPTION_KEY" | base64 -d > /tmp/ciphertext.bin
      DECRYPTED=$(aws kms decrypt \
        --region "$AWS_REGION" \
        --ciphertext-blob fileb:///tmp/ciphertext.bin \
        --output text \
        --query Plaintext | base64 -d)
      rm -f /tmp/ciphertext.bin
      {{- else if eq $provider "azure" }}
      echo "Decrypting secret using Azure Key Vault (via Workload Identity)..."
      # Login using Azure Workload Identity with federated token
      if [ -f "$AZURE_FEDERATED_TOKEN_FILE" ]; then
        echo "Using federated token for authentication..."
        az login --federated-token "$(cat $AZURE_FEDERATED_TOKEN_FILE)" \
          --service-principal \
          -u "$AZURE_CLIENT_ID" \
          -t "$AZURE_TENANT_ID" \
          --allow-no-subscriptions
      else
        echo "Federated token not found, falling back to managed identity..."
        {{- if .Values.encryptedDecryptionKey.azure.clientId }}
        az login --identity --allow-no-subscriptions --client-id "$AZURE_CLIENT_ID"
        {{- else }}
        az login --identity --allow-no-subscriptions
        {{- end }}
      fi
      echo "Logged in to Azure, decrypting secret..."
      # Remove any whitespace/newlines that may have been introduced
      CIPHERTEXT=$(echo "$ENCRYPTED_DECRYPTION_KEY" | tr -d '[:space:]')
      # Add padding if needed (base64 strings must be multiple of 4 chars)
      case $((${#CIPHERTEXT} % 4)) in
        2) CIPHERTEXT="${CIPHERTEXT}==" ;;
        3) CIPHERTEXT="${CIPHERTEXT}=" ;;
      esac
      echo "Ciphertext length: ${#CIPHERTEXT}"
      # Decrypt the ciphertext using Azure Key Vault
      DECRYPTED=$(az keyvault key decrypt \
        --name "$AZURE_KEY_NAME" \
        --vault-name "$AZURE_VAULT_NAME" \
        --algorithm "$AZURE_ALGORITHM" \
        --value "$CIPHERTEXT" \
        {{- if .Values.encryptedDecryptionKey.azure.keyVersion }}
        --version "$AZURE_KEY_VERSION" \
        {{- end }}
        --query result --output tsv | base64 -d)
      {{- end }}
      # Write decrypted value to shared volume (memory-backed, not persisted)
      # File is owned by user 1000 so non-root containers can read it
      echo -n "$DECRYPTED" > /decrypted-secrets/DECRYPTION_KEY
      chmod 400 /decrypted-secrets/DECRYPTION_KEY
      chown 1000:1000 /decrypted-secrets/DECRYPTION_KEY
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
  {{- /* When using encrypted secret, wrap the original command/args to source the key from file */ -}}
  {{- if $useEncryptedSecret }}
  {{- $renderedArgs := list }}
  {{- range .container.args }}
  {{- $renderedArgs = append $renderedArgs (tpl . $.root) }}
  {{- end }}
  command:
    - /bin/sh
    - -c
    - |
      set -e
      export DECRYPTION_KEY=$(cat /decrypted-secrets/DECRYPTION_KEY)
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
  {{- if .container.args }}
  args:
    {{- (tpl (toYaml .container.args) .root) | nindent 2 }}
  {{- end }}
  {{- end }}
  {{- if .container.workingDir }}
  workingDir: {{ .container.workingDir }}
  {{- end }}
  {{- if .container.env }}
  env:
    {{- (tpl (toYaml .container.env) .root) | nindent 2 }}
  {{- end }}
  {{- /* Skip envFrom when using encrypted secret (key comes from file instead) */ -}}
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
  {{- /* Add decrypted-secrets volume mount when using encrypted secret */ -}}
  {{- if $useEncryptedSecret }}
    - name: decrypted-secrets
      mountPath: /decrypted-secrets
      readOnly: true
  {{- end }}
  {{- if .container.restartPolicy }}
  restartPolicy: {{ .container.restartPolicy }}
  {{- end }}
{{- end -}}
