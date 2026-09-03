{{- define "devops-challenge.labels" -}}
app.kubernetes.io/part-of: devops-challenge
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
{{- end }}

{{- define "devops-challenge.selectorLabels" -}}
app.kubernetes.io/name: {{ .component }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end }}

{{- define "devops-challenge.secretName" -}}
{{- .Values.secret.existingSecretName -}}
{{- end }}

{{- define "devops-challenge.serviceAccountName" -}}
{{- .Values.azureKeyVault.serviceAccountName -}}
{{- end }}
