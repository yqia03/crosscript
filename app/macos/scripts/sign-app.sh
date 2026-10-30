#!/bin/bash
set -euo pipefail
APP_PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="${1:?Usage: sign-app.sh path/to/App.app}"
APP_SIGNING_DIR="$APP_PROJECT_ROOT/.local-signing"
APP_IDENTITY="${WORKBENCH_SIGNING_IDENTITY:--}"
APP_KEYCHAIN="${WORKBENCH_SIGNING_KEYCHAIN:-}"
if [[ -z "${WORKBENCH_SIGNING_IDENTITY+x}" && -f "$APP_SIGNING_DIR/enabled" ]]; then
    APP_IDENTITY="$(cat "$APP_SIGNING_DIR/identity")"
    if [[ -z "$APP_IDENTITY" || "$APP_IDENTITY" == - ]]; then
        printf '%s\n' 'Configured development signing identity is missing; refusing ad-hoc fallback.' >&2
        exit 1
    fi
    APP_KEYCHAIN="$APP_SIGNING_DIR/development.keychain-db"
    /usr/bin/python3 "$APP_PROJECT_ROOT/scripts/unlock-development-keychain.py" "$APP_SIGNING_DIR"
fi
SIGN_FLAGS=(--force --sign "$APP_IDENTITY" --options runtime --entitlements "$APP_PROJECT_ROOT/Resources/TranslationWorkbench.entitlements")
if [[ -n "$APP_KEYCHAIN" ]]; then
    SIGN_FLAGS+=(--keychain "$APP_KEYCHAIN")
fi
if [[ "$APP_IDENTITY" == - ]]; then
    SIGN_FLAGS+=(--timestamp=none)
    printf '%s\n' 'Ad-hoc signing does not authenticate the publisher. Verify privacy permissions for this exact build on the target Mac.' >&2
fi
/usr/bin/codesign "${SIGN_FLAGS[@]}" "$APP_BUNDLE"
/usr/bin/codesign --verify --strict "$APP_BUNDLE"
