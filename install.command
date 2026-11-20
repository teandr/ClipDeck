#!/bin/bash
# Installs only this user's application bundle; does not remove preferences.
set -euo pipefail

clipdeck_project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
clipdeck_source_app="$clipdeck_project_dir/dist/ClipDeck.app"
clipdeck_install_parent="$HOME/Applications"
clipdeck_install_app="$clipdeck_install_parent/ClipDeck.app"

if [ "$(uname -s)" != Darwin ]; then
    printf '%s\n' 'Run this installer on a Mac.' >&2
    exit 1
fi

if [ ! -x "$clipdeck_source_app/Contents/MacOS/ClipDeck" ]; then
    /bin/bash "$clipdeck_project_dir/scripts/build.sh"
fi

/usr/bin/codesign --verify --strict "$clipdeck_source_app"
mkdir -p "$clipdeck_install_parent"
clipdeck_stage_dir="$(mktemp -d "$clipdeck_install_parent/.ClipDeck-install.XXXXXX")"
trap 'rm -rf "$clipdeck_stage_dir"' EXIT
/usr/bin/ditto "$clipdeck_source_app" "$clipdeck_stage_dir/ClipDeck.app"
/usr/bin/codesign --verify --strict "$clipdeck_stage_dir/ClipDeck.app"

# NSRunningApplication.terminate() requests normal termination without force
# killing or launching an absent app. Clipboard cells are memory-only.
/usr/bin/osascript -l JavaScript <<'JXA'
ObjC.import('AppKit');
var matching = $.NSRunningApplication.runningApplicationsWithBundleIdentifier('app.clipdeck.ClipDeck');
for (var index = 0; index < matching.count; index++) {
    matching.objectAtIndex(index).terminate;
}
for (var attempt = 0; attempt < 50; attempt++) {
    var allTerminated = true;
    for (var index = 0; index < matching.count; index++) {
        if (!matching.objectAtIndex(index).isTerminated) allTerminated = false;
    }
    if (allTerminated) break;
    delay(0.1);
}
for (var index = 0; index < matching.count; index++) {
    if (!matching.objectAtIndex(index).isTerminated) {
        throw new Error('Quit ClipDeck from its menu, then run the installer again.');
    }
}
JXA

if [ -e "$clipdeck_install_app" ]; then
    mv "$clipdeck_install_app" "$clipdeck_stage_dir/previous.app"
fi
if ! mv "$clipdeck_stage_dir/ClipDeck.app" "$clipdeck_install_app"; then
    if [ -e "$clipdeck_stage_dir/previous.app" ]; then
        mv "$clipdeck_stage_dir/previous.app" "$clipdeck_install_app"
    fi
    printf '%s\n' 'Installation failed; the previous application was restored.' >&2
    exit 1
fi

printf 'Installed: %s\n' "$clipdeck_install_app"
printf '%s\n' 'Rebuilding may require you to grant Accessibility permission again.'
/usr/bin/open "$clipdeck_install_app"
