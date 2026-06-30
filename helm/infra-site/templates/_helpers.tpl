{{/*
SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
SPDX-License-Identifier: Apache-2.0
*/}}

{{- define "nvidia-infra-controller-site-infra.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: nico-site
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{- define "nvidia-infra-controller-site-infra.namespace" -}}
{{ .Release.Namespace }}
{{- end }}
