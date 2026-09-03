#!/usr/bin/env bash
set -euo pipefail

secrets_file="${1:-/etc/goblin-zomboid/secrets.env}"
if [[ "$secrets_file" != /* || "$secrets_file" == *..* ]]; then
    printf '%s\n' 'secrets path must be an absolute path without parent traversal.' >&2
    exit 2
fi
if [[ ! -f "$secrets_file" ]]; then
    printf 'MISSING %s\n' "$secrets_file" >&2
    exit 1
fi

mode="$(stat -c %a -- "$secrets_file")"
owner="$(stat -c %U:%G -- "$secrets_file")"
size="$(stat -c %s -- "$secrets_file")"
printf 'credentials metadata: mode=%s owner=%s size=%s path=%s\n' \
    "$mode" "$owner" "$size" "$secrets_file"

if [[ "$mode" != "600" ]]; then
    printf '%s\n' 'credentials metadata check failed: expected mode 600.' >&2
    exit 1
fi
if [[ "$size" -le 0 ]]; then
    printf '%s\n' 'credentials metadata check failed: file is empty.' >&2
    exit 1
fi

keys="$(cut -d= -f1 -- "$secrets_file")"
required_keys=(
    STEAM_USERNAME
    STEAM_PASSWORD
    PZ_SERVER_HOST
    PZ_SERVER_PORT
    PZ_SERVER_USERNAME
    PZ_SERVER_PASSWORD
)
for key in "${required_keys[@]}"; do
    if ! grep -Fqx -- "$key" <<<"$keys"; then
        printf 'MISSING key %s\n' "$key" >&2
        exit 1
    fi
done

printf '%s\n' 'credentials metadata: required keys present; values not displayed.'
