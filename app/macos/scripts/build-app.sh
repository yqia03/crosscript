#!/bin/bash
set -euo pipefail
APP_PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_REPOSITORY_ROOT="$(cd "$APP_PROJECT_ROOT/../.." && pwd)"
APP_CONFIGURATION="${1:-debug}"
case "$APP_CONFIGURATION" in debug|release) ;; *) echo 'Usage: build-app.sh [debug|release]' >&2; exit 2 ;; esac
APP_BUNDLE="${WORKBENCH_APP_BUNDLE:-$APP_PROJECT_ROOT/.build/app/TranslationWorkbench.app}"
if [[ "$APP_CONFIGURATION" == release && -e "$APP_BUNDLE" ]]; then
    echo 'Release builds require a fresh WORKBENCH_APP_BUNDLE path; existing app preserved.' >&2
    exit 1
fi
if [[ -L "$APP_BUNDLE" ]]; then
    echo 'App output must not be a symbolic link.' >&2
    exit 1
fi
# A fresh output has no executable to replace. Existing debug outputs still
# require the original running-process check; release outputs always reject reuse.
if [[ -e "$APP_BUNDLE" ]]; then
    if ! APP_RUNNING_EXECUTABLES="$(/bin/ps -ww -axo comm=)"; then
        printf '%s\n' 'Cannot check running applications; refusing to replace the app bundle.' >&2
        exit 1
    fi
    if /usr/bin/grep -Fx "$APP_BUNDLE/Contents/MacOS/TranslationWorkbench" <<< "$APP_RUNNING_EXECUTABLES" >/dev/null; then
        printf '%s\n' 'This app bundle is running. Quit and save recordings before replacing it, or set WORKBENCH_APP_BUNDLE to a separate candidate path.' >&2
        exit 1
    fi
fi
cd "$APP_PROJECT_ROOT"
APP_SWIFT_FLAGS=(--arch arm64 -Xswiftc -file-prefix-map -Xswiftc "$APP_REPOSITORY_ROOT=/CrosscriptSource" -Xswiftc -file-compilation-dir -Xswiftc /CrosscriptSource)
if [[ -n "${WORKBENCH_SWIFT_SCRATCH_PATH:-}" ]]; then
    APP_SWIFT_FLAGS+=(--scratch-path "$WORKBENCH_SWIFT_SCRATCH_PATH" -Xswiftc -file-prefix-map -Xswiftc "$WORKBENCH_SWIFT_SCRATCH_PATH=/CrosscriptBuild")
fi
# Use only within the caller's enforced process-tree network sandbox.
if [[ "${WORKBENCH_OUTER_NETWORK_SANDBOX:-0}" == 1 ]]; then
    APP_SWIFT_FLAGS+=(--disable-sandbox)
fi
/usr/bin/swift build -c "$APP_CONFIGURATION" "${APP_SWIFT_FLAGS[@]}" -v
APP_BINARY_DIR="$(/usr/bin/swift build -c "$APP_CONFIGURATION" "${APP_SWIFT_FLAGS[@]}" --show-bin-path)"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources/Legal"
cp "$APP_BINARY_DIR/TranslationWorkbench" "$APP_BUNDLE/Contents/MacOS/TranslationWorkbench"
if [[ "$APP_CONFIGURATION" == release ]]; then
    /usr/bin/strip -S "$APP_BUNDLE/Contents/MacOS/TranslationWorkbench"
fi
cp "$APP_PROJECT_ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$APP_PROJECT_ROOT/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
# Only copy source resources. Development bytecode and Finder metadata are not release inputs.
/usr/bin/rsync -r --exclude='__pycache__' --exclude='*.pyc' --exclude='*.pyo' --exclude='.DS_Store' --exclude='._*' \
    "$APP_PROJECT_ROOT/Sources/TranslationWorkbench/Resources/PDF" "$APP_BUNDLE/Contents/Resources/"
cp "$APP_REPOSITORY_ROOT/LICENSE" "$APP_BUNDLE/Contents/Resources/Legal/LICENSE.txt"
cp "$APP_REPOSITORY_ROOT/THIRD_PARTY_NOTICES.md" "$APP_BUNDLE/Contents/Resources/Legal/THIRD_PARTY_NOTICES.txt"
cp "$APP_REPOSITORY_ROOT/docs/source-and-build.md" "$APP_BUNDLE/Contents/Resources/Legal/SOURCE_AND_BUILD.txt"
if [[ -n "${WORKBENCH_SOURCE_REVISION:-}" || -n "${WORKBENCH_SOURCE_ARCHIVE_SHA256:-}" ]]; then
    [[ "${WORKBENCH_SOURCE_REVISION:-}" =~ ^[0-9a-f]{40}$ && "${WORKBENCH_SOURCE_ARCHIVE_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || {
        echo 'Both source revision and source archive SHA-256 must be valid.' >&2; exit 2;
    }
    /usr/libexec/PlistBuddy -c "Add :CrosscriptSourceRevision string $WORKBENCH_SOURCE_REVISION" "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CrosscriptSourceArchiveSHA256 string $WORKBENCH_SOURCE_ARCHIVE_SHA256" "$APP_BUNDLE/Contents/Info.plist"
fi
bash "$APP_PROJECT_ROOT/scripts/sign-app.sh" "$APP_BUNDLE"
printf '%s\n' "$APP_BUNDLE"
