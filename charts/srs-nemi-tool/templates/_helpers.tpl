{{- define "srs-nemi-tool.name" -}}
{{ .Chart.Name }}
{{- end }}

{{- define "srs-nemi-tool.fullname" -}}
{{ include "srs-nemi-tool.name" . }}-{{ .Release.Name }}
{{- end }}
    