{{- define "bm-cluster.identity" -}}
{{- $domain := required "publicDomain is required" .Values.publicDomain -}}
{{- if not (regexMatch "^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9_.~%+-]+)+\\.git$" .Values.gitopsRepositoryURL) -}}
{{- fail "gitopsRepositoryURL must be an HTTP(S) .git URL without embedded credentials" -}}
{{- end -}}
{{- $slug := .Values.organizationSlug | default (first (splitList "." $domain)) -}}
{{- $name := .Values.organizationName | default $slug -}}
{{- $group := .Values.gitlabGroupPath | default $slug -}}
{{- $project := .Values.gitlabProjectName | default "bm-cluster" -}}
{{- $realm := .Values.keycloakRealm | default $slug -}}
{{- $tls := .Values.tlsSecretName | default (printf "%s-tls" (replace "." "-" $domain)) -}}
{{- $alm := .Values.sonarAlmSetting | default (printf "%s-gitlab" $slug) -}}
{{- if or (not (regexMatch "^[a-z0-9]([a-z0-9-]*[a-z0-9])?$" $slug)) (gt (len $slug) 63) -}}
{{- fail "organizationSlug must be a lowercase DNS label of at most 63 characters" -}}
{{- end -}}
{{- if or (not (regexMatch "^[A-Za-z0-9_-][A-Za-z0-9_.-]*(/[A-Za-z0-9_-][A-Za-z0-9_.-]*)*$" $group)) (not (regexMatch "^[A-Za-z0-9_-][A-Za-z0-9_.-]*$" $project)) -}}
{{- fail "gitlabGroupPath and gitlabProjectName must be valid repository path components" -}}
{{- end -}}
{{- if or (eq $realm "master") (not (regexMatch "^[A-Za-z0-9_-][A-Za-z0-9_.-]*$" $realm)) (not (regexMatch "^[A-Za-z0-9_-][A-Za-z0-9_.-]*$" $alm)) -}}
{{- fail "keycloakRealm and sonarAlmSetting must be valid identifiers; master is reserved" -}}
{{- end -}}
{{- if or (not (regexMatch "^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$" $tls)) (gt (len $tls) 253) -}}
{{- fail "tlsSecretName must be a Kubernetes DNS subdomain" -}}
{{- end -}}
{{- $idp := .Values.cloudflareAccessIdpName | default (printf "%s Keycloak" $name) -}}
{{- $groupName := .Values.gitlabGroupName | default $name -}}
{{- $scanner := index .Values "trivy-operator" -}}
{{- if or (contains "__GITLAB_GROUP_PATH__" $scanner.image.repository) (contains "__GITLAB_GROUP_PATH__" $scanner.trivy.image.repository) -}}
{{- fail "Supply trivy-operator.image.repository and trivy-operator.trivy.image.repository for the selected GitLab project; the installer generates these Helm parameters" -}}
{{- end -}}
{{- range $display := list $name $idp $groupName -}}
{{- if or (regexMatch "[[:cntrl:]]" $display) (gt (len $display) 160) -}}
{{- fail "Organization, GitLab group and Cloudflare display names must be printable and at most 160 characters" -}}
{{- end -}}
{{- end -}}
{{- dict "__ORGANIZATION_SLUG__" $slug "__ORGANIZATION_NAME_JSON__" (toJson $name)
    "__GITLAB_GROUP_PATH__" $group "__GITLAB_PROJECT_NAME__" $project
    "__GITLAB_GROUP_NAME_JSON__" (toJson $groupName) "__KEYCLOAK_REALM__" $realm
    "__TLS_SECRET_NAME__" $tls "__SONAR_ALM_SETTING__" $alm
    "__CLOUDFLARE_ACCESS_IDP_NAME_JSON__" (toJson $idp)
    "__PLATFORM_TITLE_JSON__" (toJson (printf "%s Intranet" $name)) | toJson -}}
{{- end -}}
