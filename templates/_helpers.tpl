{{/*
Expand the name of the chart.
*/}}
{{- define "umbrella-owl.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "umbrella-owl.fullname" -}}
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
{{- define "umbrella-owl.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "umbrella-owl.labels" -}}
helm.sh/chart: {{ include "umbrella-owl.chart" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: wisbric
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end }}

{{/*
Build a docker config JSON for registry authentication.
Usage: {{ include "umbrella-owl.dockerconfigjson" . }}
*/}}
{{- define "umbrella-owl.dockerconfigjson" -}}
{{- $registry := .Values.registryCredentials.registry -}}
{{- $username := .Values.registryCredentials.username -}}
{{- $password := .Values.registryCredentials.password -}}
{{- $auth := printf "%s:%s" $username $password | b64enc -}}
{{- printf "{\"auths\":{\"%s\":{\"username\":\"%s\",\"password\":\"%s\",\"auth\":\"%s\"}}}" $registry $username $password $auth | b64enc -}}
{{- end }}

{{/*
Compute the owlstack dependency fullname so umbrella templates can reference
the generated Secret without duplicating raw resource names by hand.
*/}}
{{- define "umbrella-owl.owlstackFullname" -}}
{{- if .Values.owlstack.fullnameOverride }}
{{- .Values.owlstack.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default "owlstack" .Values.owlstack.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Resolve the Secret name used by the owlstack dependency chart.
*/}}
{{- define "umbrella-owl.owlstackSecretName" -}}
{{- if .Values.owlstack.secrets.create }}
{{- include "umbrella-owl.owlstackFullname" . }}
{{- else }}
{{- .Values.owlstack.secrets.existingSecret }}
{{- end }}
{{- end }}

{{/*
Compute the external Owlstack base URL for Keycloak redirect/web-origin wiring.
Prefer the explicit OIDC redirect URL when available, otherwise derive from the
first ingress host.
*/}}
{{- define "umbrella-owl.owlstackBaseUrl" -}}
{{- if .Values.owlstack.secrets.oidcRedirectUrl }}
{{- regexReplaceAll "/auth/oidc/callback$" .Values.owlstack.secrets.oidcRedirectUrl "" -}}
{{- else if and .Values.owlstack.ingress.enabled (gt (len .Values.owlstack.ingress.hosts) 0) }}
{{- printf "https://%s" (index .Values.owlstack.ingress.hosts 0).host -}}
{{- else -}}
{{- required "owlstack OIDC requires either owlstack.secrets.oidcRedirectUrl or owlstack.ingress.hosts[0].host" "" -}}
{{- end }}
{{- end }}

{{/*
Compute the external Keep base URL for Keycloak redirect/web-origin wiring.
*/}}
{{- define "umbrella-owl.keepBaseUrl" -}}
{{- if .Values.keep.oauth2Proxy.hostname }}
{{- printf "https://%s" .Values.keep.oauth2Proxy.hostname -}}
{{- else -}}
{{- if .Values.keep.enabled -}}
{{- required "keep.oauth2Proxy.hostname is required when keep.enabled=true" "" -}}
{{- else -}}
https://keep.invalid
{{- end -}}
{{- end }}
{{- end }}

{{/*
Compute the external Outline base URL for Keycloak redirect/web-origin wiring.
*/}}
{{- define "umbrella-owl.outlineBaseUrl" -}}
{{- if .Values.outline.outline.url }}
{{- trimSuffix "/" .Values.outline.outline.url -}}
{{- else if and .Values.outline.ingress.enabled (gt (len .Values.outline.ingress.hosts) 0) }}
{{- $host := index .Values.outline.ingress.hosts 0 -}}
{{- if kindIs "string" $host }}
{{- printf "https://%s" $host -}}
{{- else }}
{{- printf "https://%s" $host.host -}}
{{- end }}
{{- else -}}
{{- if .Values.outline.enabled -}}
{{- required "outline external URL requires outline.outline.url or outline.ingress.hosts[0]" "" -}}
{{- else -}}
https://outline.invalid
{{- end -}}
{{- end }}
{{- end }}
