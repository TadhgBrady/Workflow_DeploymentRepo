# Generic deployment helper template
# This is referenced by individual service deployment templates
{{- define "year4-project.deployment" -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "year4-project.fullname" . }}-{{ .service }}
  namespace: {{ .Values.namespace.name }}
  labels:
    {{- include "year4-project.labels" . | nindent 4 }}
    service: {{ .service }}
spec:
  replicas: {{ .replicas }}
  selector:
    matchLabels:
      {{- include "year4-project.selectorLabels" . | nindent 6 }}
      service: {{ .service }}
  template:
    metadata:
      labels:
        {{- include "year4-project.selectorLabels" . | nindent 8 }}
        service: {{ .service }}
    spec:
      containers:
      - name: {{ .service }}
        image: "{{ .Values.image.registry }}/{{ .imageName }}:{{ .Values.image.tag }}"
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        ports:
        - name: http
          containerPort: {{ .port }}
          protocol: TCP
        env:
        - name: ENVIRONMENT
          value: "{{ .Values.env.ENVIRONMENT }}"
        - name: LOG_LEVEL
          value: "{{ .Values.env.LOG_LEVEL }}"
        {{- if .healthCheck }}
        livenessProbe:
          httpGet:
            path: {{ .healthCheckPath }}
            port: {{ .port }}
          initialDelaySeconds: {{ .healthCheckInitial }}
          periodSeconds: {{ .healthCheckPeriod }}
        readinessProbe:
          httpGet:
            path: {{ .healthCheckPath }}
            port: {{ .port }}
          initialDelaySeconds: 5
          periodSeconds: 5
        {{- end }}
        resources:
          {{- toYaml .resources | nindent 10 }}
{{- end }}
