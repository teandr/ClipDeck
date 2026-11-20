#!/bin/bash
# Builds a locally signed macOS application using Apple's installed toolchain.
set -euo pipefail

clipdeck_project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
clipdeck_make_zip=false

for clipdeck_argument in "$@"; do
    case "$clipdeck_argument" in
        --zip) clipdeck_make_zip=true ;;
        --help|-h)
            printf '%s\n' 'Usage: bash scripts/build.sh [--zip]' \
                'Builds dist/ClipDeck.app for the architecture of this Mac.' \
                '--zip also creates dist/ClipDeck-macos-<architecture>.zip.'
            exit 0
            ;;
        *) printf 'Unknown argument: %s\n' "$clipdeck_argument" >&2; exit 2 ;;
    esac
done

if [ "$(uname -s)" != Darwin ]; then
    printf '%s\n' 'ClipDeck uses AppKit. Run this build script on a Mac.' >&2
    exit 1
fi

if ! /usr/bin/xcrun --find swift >/dev/null 2>&1; then
    printf '%s\n' 'Swift was not found. Install Xcode Command Line Tools with:' \
        '  xcode-select --install' \
        'Then rerun this script. Swift 5.9 or newer is required.' >&2
    exit 1
fi

cd "$clipdeck_project_dir"
/usr/bin/xcrun swift --version

# Gate SDK symbols by the SDK actually passed to SwiftPM, not just the Swift
# compiler version. A newer compiler can be used with an older selected SDK.
clipdeck_sdk_path="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
clipdeck_sdk_version="$(/usr/bin/xcrun --sdk macosx --show-sdk-version)"
clipdeck_sdk_major="${clipdeck_sdk_version%%.*}"
case "$clipdeck_sdk_major" in
    ''|*[!0-9]*)
        printf 'Could not read the macOS SDK version: %s\n' "$clipdeck_sdk_version" >&2
        exit 1
        ;;
esac
clipdeck_glass_define="CLIPDECK_LEGACY_APPEARANCE"
if [ "$clipdeck_sdk_major" -ge 26 ]; then
    clipdeck_glass_define="CLIPDECK_HAS_GLASS"
fi
printf 'Using macOS SDK: %s\n' "$clipdeck_sdk_version"

# Compiler module caches embed absolute paths. A relocated checkout must
# build in a new scratch directory even if its old .build was copied with it.
clipdeck_checkout_key="$(printf '%s' "$clipdeck_project_dir" | /usr/bin/shasum -a 256 | /usr/bin/cut -c 1-16)"
clipdeck_swift_build_options=(
    --configuration release
    --scratch-path "$clipdeck_project_dir/.build/clipdeck-$clipdeck_checkout_key"
    --sdk "$clipdeck_sdk_path"
    -Xswiftc "-D$clipdeck_glass_define"
)
/usr/bin/xcrun swift build "${clipdeck_swift_build_options[@]}" --product ClipDeck
clipdeck_binary_dir="$(/usr/bin/xcrun swift build "${clipdeck_swift_build_options[@]}" --show-bin-path)"
clipdeck_binary="$clipdeck_binary_dir/ClipDeck"

if [ ! -x "$clipdeck_binary" ]; then
    printf 'Build output was not found: %s\n' "$clipdeck_binary" >&2
    exit 1
fi

mkdir -p "$clipdeck_project_dir/dist"
clipdeck_stage_dir="$(mktemp -d "$clipdeck_project_dir/.clipdeck-build.XXXXXX")"
trap 'rm -rf "$clipdeck_stage_dir"' EXIT
clipdeck_stage_app="$clipdeck_stage_dir/ClipDeck.app"
clipdeck_output_app="$clipdeck_project_dir/dist/ClipDeck.app"

mkdir -p "$clipdeck_stage_app/Contents/MacOS" "$clipdeck_stage_app/Contents/Resources"
cp "$clipdeck_binary" "$clipdeck_stage_app/Contents/MacOS/ClipDeck"
cp "$clipdeck_project_dir/Resources/Info.plist" "$clipdeck_stage_app/Contents/Info.plist"
chmod 755 "$clipdeck_stage_app/Contents/MacOS/ClipDeck"
/usr/bin/plutil -lint "$clipdeck_stage_app/Contents/Info.plist"

# This ad-hoc signature is for local use. It is not a Developer ID signature,
# notarization, or an App Store distribution signature.
/usr/bin/codesign --force --sign - --identifier app.clipdeck.ClipDeck \
    --timestamp=none "$clipdeck_stage_app"
/usr/bin/codesign --verify --strict --verbose=2 "$clipdeck_stage_app"

# Prepare the replacement before moving the previous generated bundle away.
if [ -e "$clipdeck_output_app" ]; then
    mv "$clipdeck_output_app" "$clipdeck_stage_dir/previous.app"
fi
if ! mv "$clipdeck_stage_app" "$clipdeck_output_app"; then
    if [ -e "$clipdeck_stage_dir/previous.app" ]; then
        mv "$clipdeck_stage_dir/previous.app" "$clipdeck_output_app"
    fi
    printf '%s\n' 'Could not place the application in dist/.' >&2
    exit 1
fi

printf '\nBuilt: %s\n' "$clipdeck_output_app"
printf '%s\n' 'Open with: open dist/ClipDeck.app' \
    'Install for this user with: bash install.command'

if "$clipdeck_make_zip"; then
    clipdeck_arch="$(uname -m)"
    clipdeck_archive="$clipdeck_project_dir/dist/ClipDeck-macos-$clipdeck_arch.zip"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent \
        "$clipdeck_output_app" "$clipdeck_stage_dir/ClipDeck.zip"
    mv -f "$clipdeck_stage_dir/ClipDeck.zip" "$clipdeck_archive"
    printf 'Archive: %s\n' "$clipdeck_archive"
fi
