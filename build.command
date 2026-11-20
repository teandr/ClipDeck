#!/bin/bash
set -euo pipefail
clipdeck_project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec /bin/bash "$clipdeck_project_dir/scripts/build.sh" "$@"
