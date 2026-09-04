#!/usr/bin/env bash
set -euo pipefail

# Run on the PZ guest as root. The bridge root must be below the PZ user's
# cachedir/Lua directory; this script never creates a guessed fallback root.

die() {
    printf 'bridge provisioning failed: %s\n' "$1" >&2
    exit 1
}

if (( EUID != 0 )); then
    die 'run as root on the PZ guest'
fi
if (( $# != 1 )); then
    die 'usage: provision_bridge.sh /home/zomboid/Zomboid/Lua/goblin-bridge'
fi
if ! command -v getent >/dev/null 2>&1 || ! command -v realpath >/dev/null 2>&1; then
    die 'getent and realpath are required'
fi
if ! command -v setfacl >/dev/null 2>&1; then
    die 'setfacl is required to grant traversal without exposing the save tree'
fi

requested_root=$1
case "$requested_root" in
    /*/Lua/goblin-bridge) ;;
    *) die 'path must end in /Lua/goblin-bridge' ;;
esac
case "$requested_root" in
    *$'\n'*|*$'\r'*|*'//'/*|*/./*|*/../*|*/..|*/.)
        die 'path contains an unsafe component'
        ;;
esac
if [[ -L "$requested_root" ]]; then
    die 'bridge root must not be a symlink'
fi

pz_record=$(getent passwd zomboid || true)
goblin_record=$(getent passwd goblin || true)
[[ -n "$pz_record" ]] || die 'zomboid service account does not exist'
[[ -n "$goblin_record" ]] || die 'goblin relay account does not exist'
IFS=: read -r _ _ _ _ _ pz_home _ <<< "$pz_record"
IFS=: read -r _ _ _ _ _ goblin_home _ <<< "$goblin_record"
[[ -n "$pz_home" && -d "$pz_home" ]] || die 'zomboid home is missing'
[[ -n "$goblin_home" && -d "$goblin_home" ]] || die 'goblin home is missing'

lua_root=${requested_root%/goblin-bridge}
cachedir=${lua_root%/Lua}
[[ -d "$cachedir" && -d "$lua_root" ]] || die 'cachedir/Lua must already exist'
cachedir=$(realpath -e "$cachedir")
lua_root=$(realpath -e "$lua_root")
case "$cachedir" in
    "$pz_home"/*) ;;
    *) die 'cachedir must be below the zomboid service home' ;;
esac
[[ "$lua_root" == "$cachedir/Lua" ]] || die 'Lua directory is not the cachedir child'
bridge_root="$lua_root/goblin-bridge"
if [[ -e "$bridge_root" && ! -d "$bridge_root" ]]; then
    die 'bridge root exists but is not a directory'
fi
if [[ -L "$bridge_root" ]]; then
    die 'bridge root must not be a symlink'
fi

if ! getent group goblinbridge >/dev/null 2>&1; then
    groupadd --system goblinbridge
fi
usermod -a -G goblinbridge zomboid
usermod -a -G goblinbridge goblin

# The relay needs execute-only traversal on the existing parent directories;
# it receives no directory listing or read permission for the save tree.
setfacl -m u:goblin:--x "$pz_home"
setfacl -m u:goblin:--x "$cachedir"
setfacl -m u:goblin:--x "$lua_root"

install -d -o zomboid -g goblinbridge -m 2770 "$bridge_root"
channels=(state events commands responses acks runtime archive deadletter)
for channel in "${channels[@]}"; do
    if [[ -L "$bridge_root/$channel" || ( -e "$bridge_root/$channel" && ! -d "$bridge_root/$channel" ) ]]; then
        die "bridge channel is not a real directory: $channel"
    fi
    install -d -o zomboid -g goblinbridge -m 2770 "$bridge_root/$channel"
done

marker="$bridge_root/.goblin-bridge-v1"
if [[ -L "$marker" ]]; then
    die 'bridge marker must not be a symlink'
elif [[ ! -e "$marker" ]]; then
    umask 007
    printf '%s\n' 'goblin-bridge-v1' > "$marker"
    chown root:goblinbridge "$marker"
    chmod 0660 "$marker"
elif [[ ! -f "$marker" || -L "$marker" ]]; then
    die 'bridge marker exists but is not a regular file'
fi

ready_index="$bridge_root/commands/.ready-index.json"
if [[ -L "$ready_index" ]]; then
    die 'ready index must not be a symlink'
elif [[ ! -e "$ready_index" ]]; then
    umask 007
    printf '%s\n' '[]' > "$ready_index"
    chown root:goblinbridge "$ready_index"
    chmod 0660 "$ready_index"
elif [[ ! -f "$ready_index" || -L "$ready_index" ]]; then
    die 'ready index exists but is not a regular file'
fi

config_file="$bridge_root/config.ini"
if [[ -L "$config_file" || ( -e "$config_file" && ! -f "$config_file" ) ]]; then
    die 'Goblin config exists but is not a regular file'
elif [[ ! -e "$config_file" ]]; then
    umask 007
    printf '%s\n' \
        '# GoblinSurvivor integration configuration.' \
        '# Keep the master switch false until the NPC and bridge checks pass.' \
        'GoblinEnabled=false' \
        'GoblinBridgeRoot=goblin-bridge' \
        'GoblinNpcId=goblin.primary' \
        'GoblinNpcName=Goblin' \
        'GoblinNpcProgram=Companion' \
        'GoblinNpcProtected=true' \
        'GoblinManagedNpcCount=3' \
        'GoblinCommanders=' \
        'MinimumBaseGuards=1' \
        'GoblinTrackerExact=true' > "$config_file"
fi
chown root:goblinbridge "$config_file"
chmod 0660 "$config_file"

printf 'bridge provisioned at %s\n' "$bridge_root"
printf 'accounts granted through group goblinbridge: zomboid, goblin\n'
printf 'Goblin config: %s (master switch defaults to false)\n' "$config_file"
printf '%s\n' 'Restart the PZ service before testing so its supplementary group is active.'
