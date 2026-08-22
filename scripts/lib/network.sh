#!/usr/bin/env bash
# Shared IPv4 and cluster-network validation helpers. This file is sourced.

normalize_server_exposure() {
    case "${1,,}" in
        internet|internet-exposed|public|external) printf 'internet\n' ;;
        local|local-only|private|internal|lan) printf 'local\n' ;;
        *) return 1 ;;
    esac
}

valid_ipv4() {
    local ip="$1" octet
    local -a octets

    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
        (( 10#$octet <= 255 )) || return 1
    done
}

trusted_private_ipv4() {
    local ip="$1" a b _

    valid_ipv4 "$ip" || return 1
    IFS='.' read -r a b _ <<< "$ip"
    a=$((10#$a))
    b=$((10#$b))
    (( a == 10 )) ||
        (( a == 172 && b >= 16 && b <= 31 )) ||
        (( a == 192 && b == 168 )) ||
        (( a == 100 && b >= 64 && b <= 127 ))
}

tailscale_ipv4() {
    local ip="$1" a b _

    valid_ipv4 "$ip" || return 1
    IFS='.' read -r a b _ <<< "$ip"
    a=$((10#$a))
    b=$((10#$b))
    (( a == 100 && b >= 64 && b <= 127 ))
}

trusted_private_cidr() {
    local cidr="$1" ip prefix a b _

    [[ "$cidr" == */* ]] || return 1
    ip="${cidr%/*}"
    prefix="${cidr#*/}"
    trusted_private_ipv4 "$ip" || return 1
    [[ "$prefix" =~ ^[0-9]{1,2}$ ]] || return 1
    prefix=$((10#$prefix))
    (( prefix >= 1 && prefix <= 32 )) || return 1
    IFS='.' read -r a b _ <<< "$ip"
    a=$((10#$a))
    b=$((10#$b))

    if (( a == 10 )); then
        (( prefix >= 8 ))
    elif (( a == 172 && b >= 16 && b <= 31 )); then
        (( prefix >= 12 ))
    elif (( a == 192 && b == 168 )); then
        (( prefix >= 16 ))
    else
        (( a == 100 && b >= 64 && b <= 127 && prefix >= 10 ))
    fi
}

ipv4_to_int() {
    local a b c d

    IFS='.' read -r a b c d <<< "$1"
    printf '%u' "$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))"
}

cidr_contains_ip() {
    local cidr="$1" ip="$2" network prefix mask ip_value network_value

    trusted_private_cidr "$cidr" && trusted_private_ipv4 "$ip" || return 1
    network="${cidr%/*}"
    prefix=$((10#${cidr#*/}))
    ip_value="$(ipv4_to_int "$ip")"
    network_value="$(ipv4_to_int "$network")"
    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    (( (ip_value & mask) == (network_value & mask) ))
}

server_url_ipv4() {
    local value="${1%/}" authority host

    value="${value#https://}"
    authority="${value%%/*}"
    [[ -n "$authority" && "$authority" == "$value" ]] || return 1
    host="${authority%%:*}"
    trusted_private_ipv4 "$host" || return 1
    printf '%s' "$host"
}

interface_owning_ip() {
    local address="$1"

    ip -4 -o address show scope global | awk -v ip="$address" \
        '{split($4, parts, "/")} parts[1] == ip {print $2; exit}'
}
