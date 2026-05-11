{{/*
Resource name prefix — distinguishes from AWS chart's "mcp-" prefix.

Example: account.name="aliyun-prod" → mcp-aliyun-prod
*/}}
{{- define "mcp.fullname" -}}
{{- printf "mcp-%s" .Values.account.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mcp.labels" -}}
app.kubernetes.io/name: mcp-aliyun-server
app.kubernetes.io/instance: {{ .Values.account.name }}
app.kubernetes.io/managed-by: Helm
app.kubernetes.io/part-of: aws-devops-agent-external-mcp
app.kubernetes.io/component: aliyun
app: {{ include "mcp.fullname" . }}
{{- end -}}

{{- define "mcp.selectorLabels" -}}
app: {{ include "mcp.fullname" . }}
{{- end -}}

{{- define "mcp.secretName" -}}
{{- if .Values.externalSecrets.enabled -}}
{{ include "mcp.fullname" . }}
{{- else -}}
{{ required "account.existingSecret must be set when externalSecrets.enabled=false" .Values.account.existingSecret }}
{{- end -}}
{{- end -}}

{{- define "mcp.akSecretKey" -}}
{{- if .Values.externalSecrets.enabled -}}
ALIBABA_CLOUD_ACCESS_KEY_ID
{{- else -}}
{{ required "account.secretKeys.ALIBABA_CLOUD_ACCESS_KEY_ID must be set" .Values.account.secretKeys.ALIBABA_CLOUD_ACCESS_KEY_ID }}
{{- end -}}
{{- end -}}

{{- define "mcp.skSecretKey" -}}
{{- if .Values.externalSecrets.enabled -}}
ALIBABA_CLOUD_ACCESS_KEY_SECRET
{{- else -}}
{{ required "account.secretKeys.ALIBABA_CLOUD_ACCESS_KEY_SECRET must be set" .Values.account.secretKeys.ALIBABA_CLOUD_ACCESS_KEY_SECRET }}
{{- end -}}
{{- end -}}
