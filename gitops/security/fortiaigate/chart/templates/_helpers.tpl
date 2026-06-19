{{/*
Expand the name of the chart.
*/}}
{{- define "fortiaigate.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "fortiaigate.fullname" -}}
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
{{- define "fortiaigate.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "fortiaigate.labels" -}}
helm.sh/chart: {{ include "fortiaigate.chart" . }}
{{ include "fortiaigate.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "fortiaigate.selectorLabels" -}}
app.kubernetes.io/name: {{ include "fortiaigate.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "fortiaigate.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "fortiaigate.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Return the proper namespace
*/}}
{{- define "fortiaigate.namespace" -}}
{{- .Release.Namespace }}
{{- end }}

{{/*
Renders a JSON map of lowercase scanner-name -> effective maxScanChars.
Per-scanner override (scanners.<name>.env.maxScanChars) wins; otherwise
the global scanners.env.maxScanChars is used. Core parses this at startup
and uses it to bind per-scanner truncation limits into the scanner-cache
key, so changes to maxScanChars invalidate stale cache entries.

Keep the scanner list here aligned with templates/scanners.yaml line 11.
*/}}
{{- define "fortiaigate.scannerMaxCharsByName" -}}
{{- $globalMax := .Values.scanners.env.maxScanChars -}}
{{- $result := dict -}}
{{- range $scanner := list "language" "code" "promptinjection" "sensitive" "toxicity" "anonymize" "deanonymize" "customrule" -}}
  {{- $config := index $.Values.scanners $scanner -}}
  {{- $max := $globalMax -}}
  {{- if and $config.env (hasKey $config.env "maxScanChars") -}}
    {{- $max = $config.env.maxScanChars -}}
  {{- end -}}
  {{- $_ := set $result $scanner ($max | toString) -}}
{{- end -}}
{{- $result | toJson -}}
{{- end }}