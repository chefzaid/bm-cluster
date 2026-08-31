#!/usr/bin/env bash
# Shared short-lived GitLab administrator-token acquisition. Callers provide
# info() and fail(), and must call gitlab_revoke_ephemeral_admin_token on exit.

GITLAB_ADMIN_TOKEN_EPHEMERAL=false
GITLAB_BOOTSTRAP_TOKEN_NAME="${GITLAB_BOOTSTRAP_TOKEN_NAME:-bm-cluster-cli-bootstrap}"
GITLAB_ADMIN_USERNAME="${GITLAB_ADMIN_USERNAME:-root}"
GITLAB_NAMESPACE="${GITLAB_NAMESPACE:-${NAMESPACE:-infra}}"
GITLAB_WORKLOAD="${GITLAB_WORKLOAD:-deployment/gitlab}"

gitlab_prompt_admin_token() {
  cat >&2 <<'EOF'

GitLab administrator API token required:
  1. Sign in to GitLab with an administrator account.
  2. Open avatar -> Edit profile -> Access tokens.
  3. Create a short-lived personal access token with the "api" scope.
  4. Return here and paste it. Input is hidden and the token is not stored.
EOF
  IFS= read -rsp "GitLab administrator API token (glpat-...): " GITLAB_ADMIN_TOKEN
  printf '\n' >&2
  [[ -n "$GITLAB_ADMIN_TOKEN" ]] || fail "A GitLab administrator API token is required."
  export GITLAB_ADMIN_TOKEN
}

gitlab_acquire_admin_token() {
  local token_output token

  [[ -z "${GITLAB_ADMIN_TOKEN:-}" ]] || return 0
  if command -v kubectl >/dev/null 2>&1 &&
     kubectl get "$GITLAB_WORKLOAD" -n "$GITLAB_NAMESPACE" >/dev/null 2>&1; then
    info "Creating a one-day GitLab administrator token through the local GitLab command line"
    token_output="$(kubectl exec -n "$GITLAB_NAMESPACE" "$GITLAB_WORKLOAD" -- \
      env BM_TOKEN_NAME="$GITLAB_BOOTSTRAP_TOKEN_NAME" BM_ADMIN_USERNAME="$GITLAB_ADMIN_USERNAME" \
      gitlab-rails runner '
        require "securerandom"
        user = User.find_by_username(ENV.fetch("BM_ADMIN_USERNAME"))
        abort("GitLab administrator was not found") unless user&.admin?
        PersonalAccessToken.where(user: user, name: ENV.fetch("BM_TOKEN_NAME"), revoked: false).find_each(&:revoke!)
        raw = "glpat-#{SecureRandom.hex(24)}"
        token = user.personal_access_tokens.new(
          name: ENV.fetch("BM_TOKEN_NAME"),
          scopes: ["api"],
          expires_at: Date.current + 1
        )
        token.set_token(raw)
        token.save!
        puts "BM_CLUSTER_GITLAB_ADMIN_TOKEN=#{raw}"
      ' 2>/dev/null)" || token_output=""
    token="$(sed -n 's/^BM_CLUSTER_GITLAB_ADMIN_TOKEN=//p' <<< "$token_output" | tail -n 1)"
    if [[ "$token" == glpat-* ]]; then
      GITLAB_ADMIN_TOKEN="$token"
      GITLAB_ADMIN_TOKEN_EPHEMERAL=true
      export GITLAB_ADMIN_TOKEN
      return 0
    fi
    info "The local GitLab command line could not issue a token; interactive credentials are required"
  fi

  [[ -t 0 ]] || fail "Set GITLAB_ADMIN_TOKEN; automatic local GitLab token creation was unavailable."
  gitlab_prompt_admin_token
}

gitlab_revoke_ephemeral_admin_token() {
  if [[ "$GITLAB_ADMIN_TOKEN_EPHEMERAL" == "true" ]] && command -v kubectl >/dev/null 2>&1; then
    kubectl exec -n "$GITLAB_NAMESPACE" "$GITLAB_WORKLOAD" -- \
      env BM_TOKEN_NAME="$GITLAB_BOOTSTRAP_TOKEN_NAME" BM_ADMIN_USERNAME="$GITLAB_ADMIN_USERNAME" \
      gitlab-rails runner '
        user = User.find_by_username(ENV.fetch("BM_ADMIN_USERNAME"))
        PersonalAccessToken.where(user: user, name: ENV.fetch("BM_TOKEN_NAME"), revoked: false).find_each(&:revoke!) if user
      ' >/dev/null 2>&1 || true
  fi
  GITLAB_ADMIN_TOKEN=""
  unset GITLAB_ADMIN_TOKEN 2>/dev/null || true
}
