{{- define "be-nemi.name" -}}
{{ .Chart.Name }}
{{- end }}

{{- define "be-nemi.fullname" -}}
{{ include "be-nemi.name" . }}-{{ .Release.Name }}
{{- end }}
    