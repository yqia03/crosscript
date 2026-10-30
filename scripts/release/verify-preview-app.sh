#!/bin/bash
# Read-only input checks; writes evidence only to a new directory. No dev tools.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: bash verify-preview-app.sh --app /Applications/TranslationWorkbench.app \
  --archive downloaded-preview.zip --archive-sha256 EXPECTED_SHA256 \
  --app-manifest APP-MANIFEST.tsv --manifest-sha256 EXPECTED_MANIFEST_SHA256 \
  --bundle-id dev.uown.translation-workbench --version 0.1.0 --build 1 \
  --output NEW_DIRECTORY [--minimum-macos 14.2] [--assess]

Checks archive hash, the entire installed file tree against a trusted publisher
manifest, metadata and ad-hoc signature integrity. A SHA-256 hash and ad-hoc
signature do not authenticate the publisher or establish software safety.
Requires macOS built-ins only; no Python, xcrun, Xcode or Homebrew.
Does not install/launch, change quarantine, sign, read credentials or call APIs.
--assess optionally records Gatekeeper's response; rejection is not called pass.
Exit 0 means static integrity only. Clean-Mac installation remains not-run.
EOF
}

PREVIEW_APP=''
PREVIEW_ARCHIVE=''
PREVIEW_SHA=''
PREVIEW_MANIFEST=''
PREVIEW_MANIFEST_SHA=''
PREVIEW_ID=''
PREVIEW_VERSION=''
PREVIEW_BUILD=''
PREVIEW_MINIMUM='14.2'
PREVIEW_OUTPUT=''
PREVIEW_ASSESS=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --assess) PREVIEW_ASSESS=1; shift ;;
        --app|--archive|--archive-sha256|--app-manifest|--manifest-sha256|--bundle-id|--version|--build|--minimum-macos|--output)
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { usage >&2; exit 2; }
            case "$1" in
                --app) PREVIEW_APP="$2" ;;
                --archive) PREVIEW_ARCHIVE="$2" ;;
                --archive-sha256) PREVIEW_SHA="$2" ;;
                --app-manifest) PREVIEW_MANIFEST="$2" ;;
                --manifest-sha256) PREVIEW_MANIFEST_SHA="$2" ;;
                --bundle-id) PREVIEW_ID="$2" ;;
                --version) PREVIEW_VERSION="$2" ;;
                --build) PREVIEW_BUILD="$2" ;;
                --minimum-macos) PREVIEW_MINIMUM="$2" ;;
                --output) PREVIEW_OUTPUT="$2" ;;
            esac
            shift 2 ;;
        *) usage >&2; exit 2 ;;
    esac
done
[[ "$(/usr/bin/uname -s)" == Darwin ]] || { echo 'Requires macOS.' >&2; exit 2; }
[[ -d "$PREVIEW_APP" && ! -L "$PREVIEW_APP" && "$PREVIEW_APP" == *.app ]] || { usage >&2; exit 2; }
[[ -f "$PREVIEW_ARCHIVE" && ! -L "$PREVIEW_ARCHIVE" && -f "$PREVIEW_MANIFEST" && ! -L "$PREVIEW_MANIFEST" ]] || { usage >&2; exit 2; }
[[ "$PREVIEW_SHA" =~ ^[0-9a-f]{64}$ && "$PREVIEW_MANIFEST_SHA" =~ ^[0-9a-f]{64}$ ]] || { usage >&2; exit 2; }
[[ "$PREVIEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$PREVIEW_BUILD" =~ ^[1-9][0-9]{0,3}(\.[0-9]{1,2}){0,2}$ ]] || { usage >&2; exit 2; }
[[ "$PREVIEW_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ && "$PREVIEW_MINIMUM" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { usage >&2; exit 2; }
[[ -n "$PREVIEW_OUTPUT" && ! -e "$PREVIEW_OUTPUT" && ! -L "$PREVIEW_OUTPUT" ]] || { echo 'Evidence output must be new.' >&2; exit 2; }
PREVIEW_APP="$(cd -P "$PREVIEW_APP" && pwd)"
PREVIEW_PARENT="$(cd -P "$(dirname "$PREVIEW_OUTPUT")" && pwd)"
PREVIEW_OUTPUT="$PREVIEW_PARENT/$(basename "$PREVIEW_OUTPUT")"
case "$PREVIEW_OUTPUT" in "$PREVIEW_APP"|"$PREVIEW_APP"/*) echo 'Evidence output must be outside the App.' >&2; exit 2 ;; esac
/bin/mkdir "$PREVIEW_OUTPUT"
PREVIEW_REPORT="$PREVIEW_OUTPUT/checks.txt"
PREVIEW_FAILED=0
record() { printf '%s\n' "$*" >> "$PREVIEW_REPORT"; }
fail() { record "$1=failed"; PREVIEW_FAILED=1; }
finish() {
    if [[ "$PREVIEW_FAILED" -eq 0 ]]; then
        record 'status=static-integrity-passed; no clean-Mac installation acceptance'
    else
        record 'status=static-integrity-failed; do not continue installation'
    fi
    cat "$PREVIEW_REPORT"
    exit "$PREVIEW_FAILED"
}
file_sha() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
make_manifest() {
    local destination="$1" path mode kind size value
    (cd "$PREVIEW_APP" && /usr/bin/find . -print | LC_ALL=C /usr/bin/sort) > "$PREVIEW_OUTPUT/paths.txt"
    : > "$destination"
    while IFS= read -r path; do
        if [[ "$path" == *\\* ]] || printf '%s' "$path" | LC_ALL=C /usr/bin/grep -q '[[:cntrl:]]'; then
            return 1
        fi
        [[ ! -L "$PREVIEW_APP/$path" ]] || return 1
        mode="$(/usr/bin/stat -f '%Lp' "$PREVIEW_APP/$path")"
        [[ "$mode" =~ ^[0-7]{1,3}$ ]] || return 1
        if [[ -f "$PREVIEW_APP/$path" ]]; then
            kind=f
            size="$(/usr/bin/stat -f '%z' "$PREVIEW_APP/$path")"
            value="$(file_sha "$PREVIEW_APP/$path")"
        elif [[ -d "$PREVIEW_APP/$path" ]]; then
            kind=d; size=-; value=-
        else
            return 1
        fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$kind" "$mode" "$size" "$value" "$path" >> "$destination"
    done < "$PREVIEW_OUTPUT/paths.txt"
}
record 'channel=non-notarized-preview'
record 'developer_id_signing=not-performed'
record 'notarization=not-performed; publisher declaration, not queried'
record 'publisher_identity=not-authenticated-by-ad-hoc-signature'
record 'app_build_source=not-proven-by-this-helper'
record 'clean_mac_installation=not-run'
record 'first_launch_permissions_recording_history_export=not-run'
record 'pdf_runtime_and_translation=not-run'
record "macos=$(/usr/bin/sw_vers -productVersion)"
record "host_architecture=$(/usr/bin/uname -m)"
record 'tree_scope=all paths, file bytes, permission modes and directories; no symlinks; xattrs outside digest'
record "archive_sha256=$(file_sha "$PREVIEW_ARCHIVE")"
record "manifest_sha256=$(file_sha "$PREVIEW_MANIFEST")"
if [[ "$(file_sha "$PREVIEW_ARCHIVE")" != "$PREVIEW_SHA" || "$(file_sha "$PREVIEW_MANIFEST")" != "$PREVIEW_MANIFEST_SHA" ]]; then
    fail trusted_input_hash; finish
fi
record 'trusted_input_hash=passed; source of expected hashes must be established separately'
if ! make_manifest "$PREVIEW_OUTPUT/APP-BEFORE.tsv" || ! /usr/bin/cmp -s "$PREVIEW_MANIFEST" "$PREVIEW_OUTPUT/APP-BEFORE.tsv"; then
    fail installed_full_file_tree; finish
fi
record 'installed_full_file_tree=matches-trusted-publisher-manifest'
for PREVIEW_KEY in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion LSMinimumSystemVersion; do
    case "$PREVIEW_KEY" in
        CFBundleIdentifier) PREVIEW_EXPECTED="$PREVIEW_ID" ;;
        CFBundleShortVersionString) PREVIEW_EXPECTED="$PREVIEW_VERSION" ;;
        CFBundleVersion) PREVIEW_EXPECTED="$PREVIEW_BUILD" ;;
        LSMinimumSystemVersion) PREVIEW_EXPECTED="$PREVIEW_MINIMUM" ;;
    esac
    PREVIEW_ACTUAL="$(/usr/libexec/PlistBuddy -c "Print :$PREVIEW_KEY" "$PREVIEW_APP/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$PREVIEW_ACTUAL" == "$PREVIEW_EXPECTED" ]] && record "$PREVIEW_KEY=passed" || fail "$PREVIEW_KEY"
done
if /usr/bin/codesign --verify --deep --strict --all-architectures --verbose=2 "$PREVIEW_APP" > "$PREVIEW_OUTPUT/signature-check.txt" 2>&1; then
    record 'strict_signature_integrity=passed'
else
    fail strict_signature_integrity
fi
if /usr/bin/codesign -dvvv "$PREVIEW_APP" > "$PREVIEW_OUTPUT/signature-details.txt" 2>&1 && \
   /usr/bin/grep -q '^Signature=adhoc$' "$PREVIEW_OUTPUT/signature-details.txt" && \
   ! /usr/bin/grep -q '^Authority=' "$PREVIEW_OUTPUT/signature-details.txt"; then
    record 'signature_kind=adhoc; does not establish developer identity'
else
    fail adhoc_signature_kind
fi
PREVIEW_NATIVE_COUNT=0
while IFS=$'\t' read -r PREVIEW_KIND PREVIEW_MODE PREVIEW_BYTES PREVIEW_DIGEST PREVIEW_PATH; do
    [[ "$PREVIEW_KIND" == f ]] || continue
    PREVIEW_DESCRIPTION="$(/usr/bin/file -b "$PREVIEW_APP/$PREVIEW_PATH")"
    case "$PREVIEW_DESCRIPTION" in
        Mach-O*)
            PREVIEW_NATIVE_COUNT=$((PREVIEW_NATIVE_COUNT + 1))
            [[ "$PREVIEW_DESCRIPTION" == *arm64* && "$PREVIEW_DESCRIPTION" != *x86* && "$PREVIEW_DESCRIPTION" != *universal* ]] || fail native_architecture
            if ! /usr/bin/codesign --verify --strict --all-architectures "$PREVIEW_APP/$PREVIEW_PATH" >> "$PREVIEW_OUTPUT/native-signatures.txt" 2>&1; then
                fail native_signature_integrity
            fi
            if ! /usr/bin/codesign -dvvv "$PREVIEW_APP/$PREVIEW_PATH" > "$PREVIEW_OUTPUT/native-one-details.txt" 2>&1 || \
               ! /usr/bin/grep -q '^Signature=adhoc$' "$PREVIEW_OUTPUT/native-one-details.txt"; then
                fail native_adhoc_signature_kind
            fi
            printf 'item=%s\n' "$PREVIEW_PATH" >> "$PREVIEW_OUTPUT/native-details.txt"
            cat "$PREVIEW_OUTPUT/native-one-details.txt" >> "$PREVIEW_OUTPUT/native-details.txt" ;;
    esac
done < "$PREVIEW_OUTPUT/APP-BEFORE.tsv"
[[ "$PREVIEW_NATIVE_COUNT" -gt 0 ]] && record "native_arm64_items=$PREVIEW_NATIVE_COUNT" || fail native_code_presence
if /usr/bin/codesign -d --entitlements - --xml "$PREVIEW_APP" > "$PREVIEW_OUTPUT/entitlements.plist" 2> "$PREVIEW_OUTPUT/entitlements-check.txt" && \
   ! /usr/bin/grep -qi 'invalid entitlements' "$PREVIEW_OUTPUT/entitlements-check.txt"; then
    if [[ -s "$PREVIEW_OUTPUT/entitlements.plist" ]]; then
        if /usr/bin/plutil -lint "$PREVIEW_OUTPUT/entitlements.plist" >> "$PREVIEW_OUTPUT/entitlements-check.txt" 2>&1; then
            PREVIEW_DEBUG="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$PREVIEW_OUTPUT/entitlements.plist" 2>/dev/null || true)"
            [[ "$PREVIEW_DEBUG" != true ]] && record 'debug_entitlement_absent=passed' || fail debug_entitlement_absent
        else
            fail entitlement_parse
        fi
    else
        record 'embedded_entitlements=none'
    fi
else
    fail embedded_entitlements
fi
for PREVIEW_QUARANTINE_ITEM in app archive; do
    case "$PREVIEW_QUARANTINE_ITEM" in app) PREVIEW_QUARANTINE_PATH="$PREVIEW_APP" ;; archive) PREVIEW_QUARANTINE_PATH="$PREVIEW_ARCHIVE" ;; esac
    if /usr/bin/xattr -p com.apple.quarantine "$PREVIEW_QUARANTINE_PATH" > "$PREVIEW_OUTPUT/$PREVIEW_QUARANTINE_ITEM-quarantine.txt" 2> "$PREVIEW_OUTPUT/$PREVIEW_QUARANTINE_ITEM-quarantine-check.txt"; then
        record "$PREVIEW_QUARANTINE_ITEM-quarantine=observed; preserved"
    else
        record "$PREVIEW_QUARANTINE_ITEM-quarantine=not-observed; no attribute changed"
    fi
done
if [[ "$PREVIEW_ASSESS" -eq 1 ]]; then
    if /usr/sbin/spctl --assess --type execute --verbose=4 "$PREVIEW_APP" > "$PREVIEW_OUTPUT/gatekeeper.txt" 2>&1; then
        record 'gatekeeper=accepted-observed; local policy/cache may affect this; not notarization or clean-install evidence'
    else
        record 'gatekeeper=rejected-or-error-observed; inspect log; no default acceptance claimed'
    fi
else
    record 'gatekeeper=not-assessed; use manual first-launch observation'
fi
if ! make_manifest "$PREVIEW_OUTPUT/APP-AFTER.tsv" || ! /usr/bin/cmp -s "$PREVIEW_MANIFEST" "$PREVIEW_OUTPUT/APP-AFTER.tsv" || \
   [[ "$(file_sha "$PREVIEW_ARCHIVE")" != "$PREVIEW_SHA" || "$(file_sha "$PREVIEW_MANIFEST")" != "$PREVIEW_MANIFEST_SHA" ]]; then
    fail input_preservation
else
    record 'input_preservation=passed'
fi
finish
