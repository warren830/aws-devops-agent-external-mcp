{{/*
Account-scoped name. All resources for a given account share this prefix, which
makes them easy to identify across namespaces and map back to values files.

Example: account.name="aws-global" → mcp-aws-global
*/}}
{{- define "mcp.fullname" -}}
{{- printf "mcp-%s" .Values.account.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
K8s label convention: selector matches on app, rest are informational.
*/}}
{{- define "mcp.labels" -}}
app.kubernetes.io/name: mcp-server
app.kubernetes.io/instance: {{ .Values.account.name }}
app.kubernetes.io/managed-by: Helm
app.kubernetes.io/part-of: aws-devops-agent-external-mcp
app: {{ include "mcp.fullname" . }}
{{- end -}}

{{- define "mcp.selectorLabels" -}}
app: {{ include "mcp.fullname" . }}
{{- end -}}

{{/*
The Secret name that will hold AK/SK for this account.
- Mode A (no ESO): use pre-existing secret specified by user
- Mode B (ESO on): chart-managed secret name derived from account.name
*/}}
{{- define "mcp.secretName" -}}
{{- if .Values.externalSecrets.enabled -}}
{{ include "mcp.fullname" . }}
{{- else -}}
{{ required "account.existingSecret must be set when externalSecrets.enabled=false" .Values.account.existingSecret }}
{{- end -}}
{{- end -}}

{{/*
Which key name inside the Secret holds AWS_ACCESS_KEY_ID.
- Mode A: user specifies (their Secret schema may vary)
- Mode B: always "AWS_ACCESS_KEY_ID" because ESO creates it that way
*/}}
{{- define "mcp.akSecretKey" -}}
{{- if .Values.externalSecrets.enabled -}}
AWS_ACCESS_KEY_ID
{{- else -}}
{{ required "account.secretKeys.AWS_ACCESS_KEY_ID must be set" .Values.account.secretKeys.AWS_ACCESS_KEY_ID }}
{{- end -}}
{{- end -}}

{{- define "mcp.skSecretKey" -}}
{{- if .Values.externalSecrets.enabled -}}
AWS_SECRET_ACCESS_KEY
{{- else -}}
{{ required "account.secretKeys.AWS_SECRET_ACCESS_KEY must be set" .Values.account.secretKeys.AWS_SECRET_ACCESS_KEY }}
{{- end -}}
{{- end -}}
