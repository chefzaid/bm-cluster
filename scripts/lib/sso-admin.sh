#!/usr/bin/env bash
# shellcheck disable=SC2034 # Validation errors are read by scripts that source this library.

# Shared validation for the administrator identity provisioned through the
# SwirlIT Keycloak realm. Callers decide whether validation failures should be
# interactive warnings or fatal errors by reading SSO_ADMIN_VALIDATION_ERROR.

SSO_ADMIN_VALIDATION_ERROR=""

sso_admin_validate_username() {
    local username="$1"
    SSO_ADMIN_VALIDATION_ERROR=""

    if (( ${#username} < 3 || ${#username} > 128 )); then
        SSO_ADMIN_VALIDATION_ERROR="The administrator login must be between 3 and 128 characters."
        return 1
    fi
    if [[ "$username" == *".."* || "$username" == *. ]]; then
        SSO_ADMIN_VALIDATION_ERROR="The administrator login cannot contain consecutive dots or end with a dot."
        return 1
    fi

    if [[ "$username" == *"@"* ]]; then
        if [[ "${username%%@*}" == *. ]]; then
            SSO_ADMIN_VALIDATION_ERROR="The email login cannot contain a local part that ends with a dot."
            return 1
        fi
        if [[ ! "$username" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*@[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,63}$ ]]; then
            SSO_ADMIN_VALIDATION_ERROR="Use a valid email address or a username containing only letters, digits, dot, underscore, and hyphen."
            return 1
        fi
    elif [[ ! "$username" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$ ]]; then
        SSO_ADMIN_VALIDATION_ERROR="The administrator login must start with a letter or digit and contain only letters, digits, dot, underscore, and hyphen."
        return 1
    fi
}

sso_admin_validate_password() {
    local password="$1"
    local username="$2"
    SSO_ADMIN_VALIDATION_ERROR=""

    if (( ${#password} < 12 )); then
        SSO_ADMIN_VALIDATION_ERROR="The administrator password must contain at least 12 characters."
        return 1
    fi
    if [[ "$password" =~ [[:cntrl:]] ]]; then
        SSO_ADMIN_VALIDATION_ERROR="The administrator password cannot contain control characters."
        return 1
    fi
    if [[ ! "$password" =~ [[:lower:]] || ! "$password" =~ [[:upper:]] ||
          ! "$password" =~ [[:digit:]] || ! "$password" =~ [^[:alnum:]] ]]; then
        SSO_ADMIN_VALIDATION_ERROR="The administrator password must include lowercase, uppercase, numeric, and special characters."
        return 1
    fi
    if [[ "${password,,}" == "${username,,}" ]]; then
        SSO_ADMIN_VALIDATION_ERROR="The administrator password cannot equal the login."
        return 1
    fi
}

sso_admin_primary_email() {
    local username="$1"
    local platform_domain="${2:-${PLATFORM_DOMAIN:-}}"
    if [[ "$username" == *"@"* ]]; then
        printf '%s\n' "$username"
    else
        [[ -n "$platform_domain" ]] || return 1
        printf '%s@%s\n' "$username" "$platform_domain"
    fi
}
