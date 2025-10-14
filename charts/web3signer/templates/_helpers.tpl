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
{{ include "web3signer.initContainer" (merge . (dict "root" $root)) | nindent 6 }}
{{ end }}

Container object structure:
  name: string (required)
  image: string (optional - full image path)
  tag: string (optional - defaults to main container tag)
  registry: string (optional - defaults to main container registry)
  repository: string (optional - defaults to main container repository)
  pullPolicy: string (optional - defaults to main container pullPolicy)
  command: []string (optional)
  args: []string (optional)
  env: []object (optional)
  envFrom: []object (optional)
  securityContext: object (optional - defaults to main container securityContext)
  resources: object (optional)
  volumeMounts: []object (optional)
  workingDir: string (optional)
  ports: []object (optional)
  restartPolicy: string (optional)
*/}}
{{- define "web3signer.initContainer" -}}
{{- $mainImage := .root.Values.image -}}

- name: {{ .name }}
  {{- if .image }}
  image: {{ .image }}
  {{- else }}
  image: "{{ .registry | default $mainImage.registry }}/{{ .repository | default $mainImage.repository }}:{{ .tag | default $mainImage.tag | default .root.Chart.AppVersion }}"
  {{- end }}
  imagePullPolicy: {{ .pullPolicy | default $mainImage.pullPolicy }}
  {{- if .command }}
  command:
    {{- toYaml .command | nindent 4 }}
  {{- end }}
  {{- if .args }}
  args:
    {{- $root := .root }}
    {{- range .args }}
    {{- if typeIs "string" . }}
    - {{ tpl . $root }}
    {{- else }}
    - {{ . }}
    {{- end }}
    {{- end }}
  {{- end }}
  {{- if .workingDir }}
  workingDir: {{ .workingDir }}
  {{- end }}
  {{- if .env }}
  env:
    {{- toYaml .env | nindent 4 }}
  {{- end }}
  {{- if .envFrom }}
  envFrom:
    {{- $root := .root }}
    {{- range .envFrom }}
    {{- if .secretRef }}
    - secretRef:
        {{- if .secretRef.name }}
        name: {{ tpl .secretRef.name $root }}
        {{- end }}
        {{- if .secretRef.optional }}
        optional: {{ .secretRef.optional }}
        {{- end }}
    {{- else }}
    - {{ toYaml . | nindent 6 }}
    {{- end }}
    {{- end }}
  {{- end }}
  {{- if .ports }}
  ports:
    {{- toYaml .ports | nindent 4 }}
  {{- end }}
  {{- if or .securityContext .root.Values.securityContext }}
  securityContext:
    {{- toYaml (.securityContext | default .root.Values.securityContext) | nindent 4 }}
  {{- end }}
  {{- if .resources }}
  resources:
    {{- toYaml .resources | nindent 4 }}
  {{- end }}
  {{- if .volumeMounts }}
  volumeMounts:
    {{- toYaml .volumeMounts | nindent 4 }}
  {{- end }}
  {{- if .restartPolicy }}
  restartPolicy: {{ .restartPolicy }}
  {{- end }}
{{- end -}}