#!/usr/bin/env bash
set -euo pipefail

client_root="${GOBLIN_PZ_CLIENT_ROOT:-/home/goblin/pz-client/game}"

roots=(
    "$client_root/projectzomboid"
    "$client_root/ProjectZomboid"
    "$client_root"
)

for root in "${roots[@]}"; do
    modern_required=(
        "$root/ProjectZomboid64"
        "$root/ProjectZomboid64.json"
        "$root/projectzomboid.jar"
        "$root/pzexe.jar"
        "$root/jre64/bin/java"
        "$root/natives/libZNetNoSteam64.so"
        "$root/natives/libsteam_api.so"
    )
    legacy_required=(
        "$root/ProjectZomboid64"
        "$root/ProjectZomboid64.json"
        "$root/java/projectzomboid.jar"
        "$root/linux64/ZNetNoSteam64.so"
    )

    for required_name in modern_required legacy_required; do
        case "$required_name" in
            modern_required) required=("${modern_required[@]}") ;;
            legacy_required) required=("${legacy_required[@]}") ;;
        esac
        complete=1
        for path in "${required[@]}"; do
            if [[ ! -f "$path" ]]; then
                complete=0
                break
            fi
        done
        if (( complete == 1 )); then
            for path in "${required[@]}"; do
                printf 'OK %s\n' "$path"
            done
            printf 'OK native client root %s\n' "$root"
            printf '%s\n' 'Native Linux client files are present. This does not prove Steam/server compatibility or Goblin mod parity.'
            exit 0
        fi
    done
done

display_root="$client_root/projectzomboid"
if [[ ! -d "$display_root" && -d "$client_root/ProjectZomboid" ]]; then
    display_root="$client_root/ProjectZomboid"
fi
required=(
    "$display_root/ProjectZomboid64"
    "$display_root/ProjectZomboid64.json"
    "$display_root/projectzomboid.jar"
    "$display_root/pzexe.jar"
    "$display_root/jre64/bin/java"
    "$display_root/natives/libZNetNoSteam64.so"
    "$display_root/natives/libsteam_api.so"
)
for path in "${required[@]}"; do
    if [[ ! -f "$path" ]]; then
        printf 'MISSING %s\n' "$path"
    else
        printf 'OK %s\n' "$path"
    fi
done
printf '%s\n' 'Native client is not complete; do not attempt a multiplayer body test.' >&2
exit 1
