#!/usr/bin/env bash
set -euo pipefail

# Start the legal native Linux client after the same-user native Steam client
# has been authenticated.  Server credentials are intentionally entered in
# the PZ UI; this launcher never places them in argv or an environment value.

if (( EUID == 0 )); then
    printf '%s\n' 'Run the native client as the non-root goblin account.' >&2
    exit 2
fi

client_root="${GOBLIN_PZ_CLIENT_ROOT:-/home/goblin/pz-client/game}"
cachedir="${GOBLIN_PZ_CACHEDIR:-${HOME}/Zomboid}"
display="${GOBLIN_PZ_DISPLAY:-${DISPLAY:-:105}}"

install_root="${client_root}/projectzomboid"
if [[ ! -d "$install_root" && -d "${client_root}/ProjectZomboid" ]]; then
    install_root="${client_root}/ProjectZomboid"
fi

required=(
    "$install_root/ProjectZomboid64"
    "$install_root/ProjectZomboid64.json"
    "$install_root/projectzomboid.jar"
    "$install_root/pzexe.jar"
    "$install_root/jre64/bin/java"
    "$install_root/natives/libZNetNoSteam64.so"
    "$install_root/natives/libsteam_api.so"
)
for path in "${required[@]}"; do
    if [[ ! -f "$path" ]]; then
        printf 'MISSING %s\n' "$path" >&2
        printf '%s\n' 'Native client is incomplete; run setup-steam first.' >&2
        exit 1
    fi
done
if [[ ! -x "${install_root}/ProjectZomboid64" ]]; then
    printf 'NOT EXECUTABLE %s\n' "${install_root}/ProjectZomboid64" >&2
    exit 1
fi

if ! pgrep -u "$(id -u)" -x steam >/dev/null 2>&1; then
    printf '%s\n' 'Native Steam is not running for this user; authenticate/start Steam first.' >&2
    exit 1
fi

display_socket="/tmp/.X11-unix/X${display#:}"
if [[ ! -S "$display_socket" ]]; then
    printf 'X display is not available: %s\n' "$display" >&2
    exit 1
fi

mkdir -p "$cachedir"
export HOME="${HOME:-/home/goblin}"
export DISPLAY="$display"
export SDL_AUDIODRIVER="${SDL_AUDIODRIVER:-dummy}"
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"
export MESA_LOADER_DRIVER_OVERRIDE="${MESA_LOADER_DRIVER_OVERRIDE:-llvmpipe}"
export __EGL_VENDOR_LIBRARY_FILENAMES="${__EGL_VENDOR_LIBRARY_FILENAMES:-/usr/share/glvnd/egl_vendor.d/50_mesa.json}"
export __GLX_VENDOR_LIBRARY_NAME="${__GLX_VENDOR_LIBRARY_NAME:-mesa}"
export LD_LIBRARY_PATH="${install_root}/natives:${LD_LIBRARY_PATH:-}"
export PATH="${install_root}/jre64/bin:/usr/bin:/bin"

cd "$install_root"
exec "${install_root}/ProjectZomboid64" "-cachedir=${cachedir}"
