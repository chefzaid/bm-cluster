#!/usr/bin/env bash
# Kubernetes inventory is the authority for management sources, not a CIDR or
# user-provided list of worker addresses. Callers also source lib/network.sh.

control_plane_private_ips() {
    local nodes_json="$1" node_cidr="$2" addresses address
    local -a address_list=()
    trusted_private_cidr "$node_cidr" || return 1
    addresses="$(jq -er '
        [.items[] |
          select((.metadata.labels | has("node-role.kubernetes.io/control-plane")) or
                 (.metadata.labels | has("node-role.kubernetes.io/master"))) |
          .status.addresses[]? | select(.type == "InternalIP") | .address] |
        unique | if length > 0 then join(",") else error("No control-plane InternalIPs") end
    ' <<< "$nodes_json")" || return 1
    IFS=',' read -r -a address_list <<< "$addresses"
    for address in "${address_list[@]}"; do
        trusted_private_ipv4 "$address" && cidr_contains_ip "$node_cidr" "$address" || return 1
    done
    printf '%s\n' "$addresses"
}

control_plane_address_member() {
    local addresses="$1" address="$2"
    trusted_private_ipv4 "$address" && [[ ",$addresses," == *",$address,"* ]]
}
