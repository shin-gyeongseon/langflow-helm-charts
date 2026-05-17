{{/*
Expand the name of the chart.
*/}}
{{- define "langflow-runtime.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "langflow-runtime.fullname" -}}
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
{{- define "langflow-runtime.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "langflow-runtime.labels" -}}
helm.sh/chart: {{ include "langflow-runtime.chart" . }}
{{ include "langflow-runtime.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "langflow-runtime.selectorLabels" -}}
app.kubernetes.io/name: {{ include "langflow-runtime.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "langflow-runtime.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "langflow-runtime.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Runtime database secret name
*/}}
{{- define "langflow-runtime.databaseSecretName" -}}
{{- printf "%s-runtime-db" (include "langflow-runtime.fullname" .) -}}
{{- end }}

{{/*
Runtime env shared by Deployment and PreSync Job
*/}}
{{- define "langflow-runtime.runtimeEnv" -}}
- name: LANGFLOW_LOAD_FLOWS_PATH
  value: {{ .Values.downloadFlows.path | quote }}
- name: LANGFLOW_DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ include "langflow-runtime.databaseSecretName" . }}
      key: database-url
{{- range .Values.env }}
{{- if and (ne .name "LANGFLOW_DATABASE_URL") (ne .name "LANGFLOW_LOAD_FLOWS_PATH") }}
{{ toYaml (list .) }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Shared flow download script before starting Langflow runtime
*/}}
{{- define "langflow-runtime.downloadFlowsScript" -}}
mkdir -p {{ .Values.downloadFlows.path }} &&
{{- range .Values.downloadFlows.flows }}
{{- $targetFile := printf "%s/%s.json" $.Values.downloadFlows.path (.uuid | default (.url | sha256sum | trunc 8)) -}}
echo "Downloading flows from {{ .url }} to {{ $targetFile }}" &&
curl --fail -o '{{ $targetFile }}' \
  {{- if .basicAuth }}
  -u "{{ .basicAuth }}" \
  {{- end }}
  {{- if .headers }}
  {{- range $key, $value := .headers }}
  -H "{{ $key }}: {{ $value }}" \
  {{- end }}
  {{- end }}
  '{{ .url }}' &&
{{- if .endpoint }}
python -c 'import json, sys;f = sys.argv[1]; data = json.load(open(f));data["endpoint_name"]="{{ .endpoint }}";json.dump(data, open(f, "w"))' '{{ $targetFile }}' &&
{{- end }}
{{- end }}
echo 'Flows downloaded'
{{- end }}
