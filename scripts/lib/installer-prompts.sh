#!/usr/bin/env bash
# Shared interactive prompt primitives. Callers own strict-mode settings and
# validation; these functions only collect values consistently.

installer_prompt_section() {
  local title="$1"
  shift
  printf '\n== %s ==\n' "$title" >&2
  if (( $# > 0 )); then
    printf '  %s\n' "$@" >&2
  fi
}

installer_prompt_value() {
  local variable_name="$1" prompt_text="$2" default_value="${3:-}" answer=""
  read -rp "$prompt_text${default_value:+ [$default_value]}: " answer
  printf -v "$variable_name" '%s' "${answer:-$default_value}"
}

installer_prompt_secret() {
  local variable_name="$1" prompt_text="$2" answer=""
  IFS= read -rsp "$prompt_text: " answer
  printf '\n' >&2
  printf -v "$variable_name" '%s' "$answer"
}

installer_prompt_confirmed_secret() {
  local variable_name="$1" prompt_text="$2" confirmation_text="$3"
  local value="" confirmation=""

  installer_prompt_secret value "$prompt_text"
  installer_prompt_secret confirmation "$confirmation_text"
  if [[ "$value" != "$confirmation" ]]; then
    value=""
    confirmation=""
    printf -v "$variable_name" '%s' ''
    return 1
  fi
  printf -v "$variable_name" '%s' "$value"
  value=""
  confirmation=""
}

installer_prompt_yes_no() {
  local prompt_text="$1" default_choice="${2:-N}" non_interactive="${3:-false}"
  local answer="" suffix=""

  case "${default_choice^^}" in
    Y) default_choice=Y; suffix='[Y/n]' ;;
    N) default_choice=N; suffix='[y/N]' ;;
    *) printf '[ERROR] Invalid yes/no default: %s\n' "$default_choice" >&2; return 2 ;;
  esac
  if [[ "$non_interactive" == "true" ]]; then
    [[ "$default_choice" == "Y" ]]
    return
  fi
  read -rp "$prompt_text $suffix " answer
  answer="${answer:-$default_choice}"
  [[ "$answer" =~ ^[Yy]$ ]]
}

installer_select_node_transport() {
  local variable_name="$1" current_value="${2:-}" default_value="${3:-vrack}"
  local non_interactive="${4:-false}" answer="" selected=""

  case "${current_value,,}" in
    vrack|v-rack|ovh|lan|private-network) selected=vrack ;;
    tailscale|tailnet|ts) selected=tailscale ;;
    '') ;;
    *) return 2 ;;
  esac
  if [[ -n "$selected" ]]; then
    printf -v "$variable_name" '%s' "$selected"
    return
  fi
  [[ "$non_interactive" != "true" ]] || return 1

  case "${default_value,,}" in
    tailscale|tailnet|ts) default_value=tailscale ;;
    *) default_value=vrack ;;
  esac
  printf '%s\n' \
    "Select the private node transport:" \
    "  1) OVHcloud vRack (OVHcloud-only)" \
    "  2) Tailscale (hybrid cloud or non-OVHcloud providers)" >&2
  while true; do
    read -rp "Select 1 or 2 [$([[ "$default_value" == "vrack" ]] && printf 1 || printf 2)]: " answer
    case "${answer:-$default_value}" in
      1|vrack|vRack|v-rack|ovh|lan|private-network) selected=vrack ;;
      2|tailscale|tailnet|ts) selected=tailscale ;;
      *) printf 'Enter 1 for vRack or 2 for Tailscale.\n' >&2; continue ;;
    esac
    printf -v "$variable_name" '%s' "$selected"
    return
  done
}
