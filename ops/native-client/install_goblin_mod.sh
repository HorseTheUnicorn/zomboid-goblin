#!/usr/bin/env bash
set -euo pipefail

repo_root="${GOBLIN_REPO_ROOT:-/home/goblin/zomboid-goblin}"
user_root="${GOBLIN_PZ_USER_ROOT:-/home/goblin/Zomboid}"
client_root="${GOBLIN_PZ_CLIENT_ROOT:-/home/goblin/pz-client/game}"
source_root="$repo_root/mod/Contents/mods/GoblinSurvivor"
target_root="$user_root/mods/GoblinSurvivor"

native_root=""
for candidate in \
    "$client_root/projectzomboid" \
    "$client_root/ProjectZomboid" \
    "$client_root"; do
    if [[ -x "$candidate/ProjectZomboid64" && -f "$candidate/projectzomboid.jar" ]]; then
        native_root="$candidate"
        break
    fi
done

if [[ -z "$native_root" ]]; then
    printf '%s\n' 'Native Linux client is not installed; install it before staging the client mod.' >&2
    exit 1
fi
if [[ ! -d "$source_root/42" ]]; then
    printf 'GoblinSurvivor source tree not found: %s\n' "$source_root/42" >&2
    exit 1
fi

mkdir -p "$target_root/42"
cp -r "$source_root/42/." "$target_root/42/"
if [[ -d "$source_root/common" ]]; then
    mkdir -p "$target_root/common"
    cp -r "$source_root/common/." "$target_root/common/"
fi

# Build 42's AdvancedAnimator walks these directories for every enabled mod
# and logs a NoSuchFileException when a mod has no animation assets. Goblin
# does not add animations, but keeping the expected directories present makes
# that absence explicit and keeps the server log clean.
animation_dirs=(
    "$target_root/common/media/AnimSets"
    "$target_root/common/media/actiongroups"
    "$target_root/42/media/AnimSets"
    "$target_root/42/media/actiongroups"
)
for directory in "${animation_dirs[@]}"; do
    mkdir -p "$directory"
done

digest="$(
    GOBLIN_REPO_FOR_HASH="$repo_root" /usr/bin/python3 -c '
import os
import sys

repo = os.environ["GOBLIN_REPO_FOR_HASH"]
sys.path.insert(0, repo)
from goblin_zomboid.mods import hash_tree

print(hash_tree(os.path.join(repo, "mod", "Contents", "mods", "GoblinSurvivor", "42")))
'
)"
if [[ ! "$digest" =~ ^[0-9a-f]{64}$ ]]; then
    printf '%s\n' 'Could not calculate a valid GoblinSurvivor SHA-256 digest.' >&2
    exit 1
fi

printf '%s\n' "$digest" > "$target_root/manifest.sha256"
mkdir -p "$user_root/Lua"
printf '%s\n' "$digest" > "$user_root/Lua/manifest.sha256"
printf '%s\n' "GoblinSurvivor staged at $target_root/42"
printf '%s\n' "GoblinSurvivor SHA-256: $digest"
printf '%s\n' 'Set GoblinSurvivorSHA256 to this digest in <cachedir>/Lua/goblin-bridge/config.ini before parity can verify.'
