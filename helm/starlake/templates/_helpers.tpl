{{/*
Expand the name of the chart.
*/}}
{{- define "starlake.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "starlake.fullname" -}}
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
{{- define "starlake.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "starlake.labels" -}}
helm.sh/chart: {{ include "starlake.chart" . }}
{{ include "starlake.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "starlake.selectorLabels" -}}
app.kubernetes.io/name: {{ include "starlake.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Component-specific labels
*/}}
{{- define "starlake.componentLabels" -}}
{{- $component := .component }}
{{- with .context }}
{{ include "starlake.labels" . }}
app.kubernetes.io/component: {{ $component }}
{{- end }}
{{- end }}

{{/*
Component-specific selector labels
*/}}
{{- define "starlake.componentSelectorLabels" -}}
{{- $component := .component }}
{{- with .context }}
{{ include "starlake.selectorLabels" . }}
app.kubernetes.io/component: {{ $component }}
{{- end }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "starlake.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "starlake.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
PostgreSQL host
*/}}
{{- define "starlake.postgresql.host" -}}
{{- if .Values.postgresql.external.enabled -}}
{{- .Values.postgresql.external.host -}}
{{- else -}}
{{- printf "%s-postgresql" (include "starlake.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
PostgreSQL port
*/}}
{{- define "starlake.postgresql.port" -}}
{{- if .Values.postgresql.external.enabled -}}
{{- .Values.postgresql.external.port -}}
{{- else -}}
5432
{{- end -}}
{{- end -}}

{{/*
PostgreSQL Starlake database name
*/}}
{{- define "starlake.postgresql.starlakeDatabase" -}}
{{- .Values.postgresql.external.starlakeDatabase -}}
{{- end -}}

{{/*
PostgreSQL Airflow database name
*/}}
{{- define "starlake.postgresql.airflowDatabase" -}}
{{- .Values.postgresql.external.airflowDatabase -}}
{{- end -}}

{{/*
PostgreSQL username
*/}}
{{- define "starlake.postgresql.username" -}}
{{- .Values.postgresql.credentials.username -}}
{{- end -}}

{{/*
PostgreSQL password secret name
*/}}
{{- define "starlake.postgresql.secretName" -}}
{{- if .Values.postgresql.credentials.existingSecret -}}
{{- .Values.postgresql.credentials.existingSecret -}}
{{- else -}}
{{- printf "%s-postgresql" (include "starlake.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
PostgreSQL username secret key
*/}}
{{- define "starlake.postgresql.usernameKey" -}}
{{- if .Values.postgresql.credentials.existingSecret -}}
{{- .Values.postgresql.credentials.usernameKey | default "postgres-user" -}}
{{- else -}}
postgres-user
{{- end -}}
{{- end -}}

{{/*
PostgreSQL password secret key
*/}}
{{- define "starlake.postgresql.passwordKey" -}}
{{- if .Values.postgresql.credentials.existingSecret -}}
{{- .Values.postgresql.credentials.passwordKey | default "postgres-password" -}}
{{- else -}}
postgres-password
{{- end -}}
{{- end -}}

{{/*
PostgreSQL JDBC URL for Starlake database
*/}}
{{- define "starlake.postgresql.jdbcUrl" -}}
{{- $host := include "starlake.postgresql.host" . }}
{{- $port := include "starlake.postgresql.port" . }}
{{- $database := include "starlake.postgresql.starlakeDatabase" . }}
{{- $username := include "starlake.postgresql.username" . }}
{{- printf "jdbc:postgresql://%s:%s/%s?user=%s" $host $port $database $username }}
{{- end }}

{{/*
PostgreSQL connection string for Airflow
*/}}
{{- define "starlake.postgresql.airflowConnectionString" -}}
{{- $host := include "starlake.postgresql.host" . }}
{{- $port := include "starlake.postgresql.port" . }}
{{- $database := include "starlake.postgresql.airflowDatabase" . }}
{{- $username := include "starlake.postgresql.username" . }}
{{- printf "postgresql+psycopg2://%s:$(POSTGRES_PASSWORD)@%s:%s/%s" $username $host $port $database }}
{{- end }}

{{/*
Storage class for PVCs
*/}}
{{- define "starlake.storageClass" -}}
{{- if .storageClass }}
{{- .storageClass }}
{{- else if .context.Values.global.storageClass }}
{{- .context.Values.global.storageClass }}
{{- else }}
{{- "" }}
{{- end }}
{{- end }}

{{/*
Frontend URL
*/}}
{{- define "starlake.frontendUrl" -}}
{{- if .Values.ingress.enabled -}}
{{- if .Values.ingress.tls.enabled -}}
{{- printf "https://%s" .Values.ingress.host -}}
{{- else -}}
{{- printf "http://%s" .Values.ingress.host -}}
{{- end -}}
{{- else -}}
{{- printf "http://localhost:%d" (int .Values.ui.service.port) -}}
{{- end -}}
{{- end -}}

{{/*
Starlake domain
*/}}
{{- define "starlake.domain" -}}
{{- if .Values.ingress.enabled -}}
{{- .Values.ingress.host -}}
{{- else -}}
localhost
{{- end -}}
{{- end -}}

{{/*
Wait for PostgreSQL init container
*/}}
{{- define "starlake.waitForPostgresql" -}}
- name: wait-for-postgresql
  image: busybox:1.35
  imagePullPolicy: IfNotPresent
  command:
    - sh
    - -c
    - |
      until nc -z {{ include "starlake.postgresql.host" . }} {{ include "starlake.postgresql.port" . }}; do
        echo "Waiting for PostgreSQL..."
        sleep 2
      done
      echo "PostgreSQL is ready!"
{{- end -}}

{{/*
Validate credentials - fails deployment if insecure defaults are used in production
Enable this validation with: security.validateCredentials: true
Recommended for production deployments to enforce secure credentials
*/}}
{{- define "starlake.validateCredentials" -}}
{{- if .Values.security.validateCredentials }}
  {{- /* PostgreSQL password validation */ -}}
  {{- if not .Values.postgresql.credentials.existingSecret }}
    {{- if eq .Values.postgresql.credentials.password "dbuser123" }}
      {{- fail "SECURITY ERROR: postgresql.credentials.password is set to default value 'dbuser123'. For production, set a secure password or use existingSecret." }}
    {{- end }}
    {{- if not .Values.postgresql.credentials.password }}
      {{- fail "SECURITY ERROR: postgresql.credentials.password is required. Set a secure password or use existingSecret." }}
    {{- end }}
  {{- end }}
  {{- /* Airflow admin password validation */ -}}
  {{- if .Values.airflow.enabled }}
    {{- if eq .Values.airflow.admin.password "airflow" }}
      {{- fail "SECURITY ERROR: airflow.admin.password is set to default value 'airflow'. For production, set a secure password." }}
    {{- end }}
    {{- /* Airflow secretKey validation */ -}}
    {{- if eq .Values.airflow.secretKey "starlake-airflow-secret-key-change-in-production" }}
      {{- fail "SECURITY ERROR: airflow.secretKey is set to default value. For production, generate a new key: python -c \"import secrets; print(secrets.token_hex(32))\"" }}
    {{- end }}
  {{- end }}
  {{- /* Gizmo credentials validation */ -}}
  {{- if .Values.gizmo.enabled }}
    {{- if eq .Values.gizmo.apiKey "a_secret_api_key" }}
      {{- fail "SECURITY ERROR: gizmo.apiKey is set to default value. For production, set a secure API key." }}
    {{- end }}
  {{- end }}
{{- end }}
{{- end -}}
