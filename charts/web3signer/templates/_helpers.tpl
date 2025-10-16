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
{{- define "web3signer.initContainer" -}}
{{- if not .container.name -}}
  {{- fail "Init container name is required but not provided" -}}
{{- end -}}
{{- $mainImage := .root.Values.image -}}

- name: {{ .container.name }}
  {{- if .container.image }}
  {{- if typeIs "string" .container.image }}
  image: {{ .container.image }}
  {{- else if typeIs "object" .container.image }}
  image: "{{ .container.image.registry }}/{{ .container.image.repository }}:{{ .container.image.tag }}"
  {{- end }}
  imagePullPolicy: {{ .container.image.pullPolicy | default $mainImage.pullPolicy }}
  {{- else }}
  image: "{{ $mainImage.registry }}/{{ $mainImage.repository }}:{{ $mainImage.tag | default .root.Chart.AppVersion }}"
  imagePullPolicy: {{ $mainImage.pullPolicy }}
  {{- end }}
  {{- if .container.command }}
  command:
    {{- toYaml .container.command | nindent 4 }}
  {{- end }}
  {{- if .container.args }}
  args:
    {{- (tpl (toYaml .container.args) .root) | nindent 2 }}
  {{- end }}
  {{- if .container.workingDir }}
  workingDir: {{ .container.workingDir }}
  {{- end }}
  {{- if .container.env }}
  env:
    {{- (tpl (toYaml .container.env) .root) | nindent 2 }}
  {{- end }}
  {{- if .container.envFrom }}
  envFrom:
    {{- (tpl (toYaml .container.envFrom) .root) | nindent 4 }}
  {{- end }}
  {{- if .container.ports }}
  ports:
    {{- (tpl (toYaml .container.ports) .root) | nindent 4 }}
  {{- end }}
  {{- if or .container.securityContext .root.Values.securityContext }}
  securityContext:
    {{- toYaml (.container.securityContext | default .root.Values.securityContext) | nindent 4 }}
  {{- end }}
  {{- if .container.resources }}
  resources:
    {{- toYaml .container.resources | nindent 4 }}
  {{- end }}
  {{- if .container.volumeMounts }}
  volumeMounts:
    {{- tpl (toYaml .container.volumeMounts) .root | nindent 4 }}
  {{- end }}
  {{- if .container.restartPolicy }}
  restartPolicy: {{ .container.restartPolicy }}
  {{- end }}
{{- end -}}
