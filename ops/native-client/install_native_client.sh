#!/usr/bin/env bash
set -euo pipefail

# Compatibility entry point. Keep one guided setup path so credentials,
# Steam Guard, native-client verification, and protected secret-file creation
# cannot drift between two installers.
exec "$(dirname "$0")/goblin-zomboid" setup-steam "$@"
