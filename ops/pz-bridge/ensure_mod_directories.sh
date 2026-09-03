#!/usr/bin/env bash
set -euo pipefail

# Run on the PZ guest as root. This repairs only the empty Build 42 media
# directories that AdvancedAnimator expects for a mod without custom assets.
# It never replaces files, follows symlinks, or restarts the server.

die() {
    printf 'mod-directory repair failed: %s\n' "$1" >&2
    exit 1
}

if (( EUID != 0 )); then
    die 'run as root on the PZ guest'
fi
if (( $# != 1 )); then
    die 'usage: ensure_mod_directories.sh /home/zomboid/Zomboid'
fi
if ! command -v getent >/dev/null 2>&1 || ! command -v realpath >/dev/null 2>&1; then
    die 'getent and realpath are required'
fi
if ! command -v install >/dev/null 2>&1; then
    die 'install is required'
fi

cachedir_input=$1
case "$cachedir_input" in
    /*) ;;
    *) die 'cachedir must be an absolute path' ;;
esac
case "$cachedir_input" in
    *$'\n'*|*$'\r'*|*'//'/*|*/./*|*/../*|*/..|*/.)
        die 'cachedir contains an unsafe component'
        ;;
esac
if [[ -L "$cachedir_input" || ! -d "$cachedir_input" ]]; then
    die 'cachedir must be an existing real directory'
fi

pz_record=$(getent passwd zomboid || true)
[[ -n "$pz_record" ]] || die 'zomboid service account does not exist'
IFS=: read -r _ _ _ _ _ pz_home _ <<< "$pz_record"
[[ -n "$pz_home" && -d "$pz_home" ]] || die 'zomboid home is missing'

cachedir=$(realpath -e -- "$cachedir_input")
pz_home=$(realpath -e -- "$pz_home")
case "$cachedir" in
    "$pz_home"/*) ;;
    *) die 'cachedir must be below the zomboid service home' ;;
esac

mods_root="$cachedir/mods"
mod_root="$mods_root/GoblinSurvivor"
if [[ -L "$mods_root" || ! -d "$mods_root" ]]; then
    die 'cachedir/mods must already be a real directory'
fi
if [[ -L "$mod_root" || ! -d "$mod_root" ]]; then
    die 'GoblinSurvivor mod root must already be a real directory'
fi
mods_root=$(realpath -e -- "$mods_root")
mod_root=$(realpath -e -- "$mod_root")
[[ "$mods_root" == "$cachedir/mods" ]] || die 'mods path resolves outside cachedir'
[[ "$mod_root" == "$mods_root/GoblinSurvivor" ]] || die 'mod path resolves outside mods'

parents=(
    "$mod_root/common/media"
    "$mod_root/42/media"
)
for parent in "${parents[@]}"; do
    if [[ -L "$parent" || ! -d "$parent" ]]; then
        die "required media parent is missing or not a real directory: $parent"
    fi
done

directories=(
    "$mod_root/common/media/AnimSets"
    "$mod_root/common/media/actiongroups"
    "$mod_root/42/media/AnimSets"
    "$mod_root/42/media/actiongroups"
)
for directory in "${directories[@]}"; do
    if [[ -L "$directory" || ( -e "$directory" && ! -d "$directory" ) ]]; then
        die "repair target is not a real directory: $directory"
    fi
    if [[ -d "$directory" ]]; then
        printf 'present %s\n' "$directory"
    else
        install -d -o zomboid -g zomboid -m 0750 -- "$directory"
        printf 'created %s\n' "$directory"
    fi
done

printf '%s\n' 'GoblinSurvivor animation directory repair complete; restart the PZ service separately to rescan the mod.'
