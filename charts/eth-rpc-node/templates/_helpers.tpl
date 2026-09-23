{{/*
Inlined name/label helpers -- see Chart.yaml for why this chart has no
dependency on the `common` library chart.
*/}}

{{- define "eth-rpc-node.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "eth-rpc-node.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "eth-rpc-node.labels" -}}
app.kubernetes.io/name: {{ include "eth-rpc-node.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- with .Values.additionalLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Convert a Kubernetes quantity ("16Gi", "512Mi", "2G") to bytes.
Helm has no unit parser, so the suffixes are handled explicitly.
*/}}
{{- define "eth-rpc-node.toBytes" -}}
{{- $q := . | toString -}}
{{- if hasSuffix "Gi" $q -}}
{{- mul (trimSuffix "Gi" $q | float64 | int64) 1073741824 -}}
{{- else if hasSuffix "Mi" $q -}}
{{- mul (trimSuffix "Mi" $q | float64 | int64) 1048576 -}}
{{- else if hasSuffix "G" $q -}}
{{- mul (trimSuffix "G" $q | float64 | int64) 1000000000 -}}
{{- else if hasSuffix "M" $q -}}
{{- mul (trimSuffix "M" $q | float64 | int64) 1000000 -}}
{{- else -}}
{{- $q | float64 | int64 -}}
{{- end -}}
{{- end -}}

{{/*
Heap ceiling in bytes for one layer.

An explicit `heap` wins. Otherwise it is `heapFraction` of the container memory
limit -- deriving it from the limit is what makes it impossible to set a heap
larger than the container, which is the mistake that OOMKilled teku.

Usage: include "eth-rpc-node.heapBytes" (dict "layer" .Values.execution)
*/}}
{{- define "eth-rpc-node.heapBytes" -}}
{{- $l := .layer -}}
{{- if $l.heap -}}
{{- include "eth-rpc-node.toBytes" $l.heap -}}
{{- else if and $l.resources $l.resources.limits $l.resources.limits.memory -}}
{{- $limit := include "eth-rpc-node.toBytes" $l.resources.limits.memory | float64 -}}
{{- mulf $limit ($l.heapFraction | default 0.75) | floor | int64 -}}
{{- else -}}
0
{{- end -}}
{{- end -}}

{{/*
Render one layer's container args: the client's derived flags from the data
table, then `extras` appended last.

Extras are appended and never merged into the derived list, so a raw flag can
add to the command line but can never remove a derived one. Overriding a list
in Helm replaces it, and that is precisely how six execution clients lost their
network flag and silently synced mainnet on a testnet cluster.
*/}}
{{- define "eth-rpc-node.args" -}}
{{- $spec := .spec -}}
{{- $ctx := .ctx -}}
{{- range $spec.flags }}
- {{ tpl . $ctx | quote }}
{{- end }}
{{- if and $.mev $spec.builderFlags }}
{{- range $spec.builderFlags }}
- {{ tpl . $ctx | quote }}
{{- end }}
{{- end }}
{{- if and $.checkpointUrl $spec.checkpointFlags }}
{{- range $spec.checkpointFlags }}
- {{ tpl . $ctx | quote }}
{{- end }}
{{- end }}
{{- range (splitList " " ($.extras | default "" | trim)) }}
{{- if . }}
- {{ . | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Environment for one layer: the client's heap variable (only if the table
defines one -- reth and lighthouse are Rust and have no managed heap), then
the user's `env` map.
*/}}
{{- define "eth-rpc-node.env" -}}
{{- $spec := .spec -}}
{{- $ctx := .ctx -}}
{{- with $spec.heap }}
- name: {{ .env }}
  value: {{ tpl .value $ctx | quote }}
{{- end }}
{{- range $k, $v := $.envMap }}
- name: {{ $k }}
  value: {{ $v | quote }}
{{- end }}
{{- end -}}
