#!/usr/bin/env python3
"""Inspect local runtime Mach-O signatures without executing or changing runtime code.

The required runtime path is the only directory scanned. JSON goes to stdout;
there is no signing, network, Keychain, Gatekeeper, or output-file operation.
Signature validity is an observation, not a publication or notarization verdict.
"""

import argparse
import base64
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import subprocess
import sys


MACHO_MAGICS = {
    bytes.fromhex(value)
    for value in (
        "cffaedfe", "cefaedfe", "feedfacf", "feedface",
        "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
    )
}
CODESIGN = "/usr/bin/codesign"
LIPO = "/usr/bin/lipo"


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def command(arguments, timeout):
    """Only callers with fixed display/verify/lipo arguments invoke this helper."""
    try:
        result = subprocess.run(
            arguments, capture_output=True, text=True, errors="replace",
            timeout=timeout, check=False,
            env={"PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C"},
        )
        return {
            "arguments": arguments,
            "exitStatus": result.returncode,
            "stdout": result.stdout.strip(),
            "stderr": result.stderr.strip(),
        }
    except (OSError, subprocess.TimeoutExpired) as error:
        return {
            "arguments": arguments, "exitStatus": None,
            "stdout": "", "stderr": str(error), "toolError": True,
        }


def is_macho(path):
    with path.open("rb") as stream:
        return stream.read(4) in MACHO_MAGICS


def fields(text):
    result = {}
    for line in text.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            result.setdefault(key, []).append(value)
    return result


def json_plist(value):
    if isinstance(value, bytes):
        return {"base64": base64.b64encode(value).decode("ascii")}
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, dict):
        return {key: json_plist(item) for key, item in value.items()}
    if isinstance(value, list):
        return [json_plist(item) for item in value]
    return value


def signature_slice(display, architecture):
    text = display["stderr"]
    values = fields(text)

    def first(key):
        return (values.get(key) or [None])[0]

    flags_match = re.search(
        r"^CodeDirectory .*? flags=(0x[0-9a-fA-F]+)(?:\(([^)]*)\))?",
        text, re.MULTILINE,
    )
    flags = int(flags_match.group(1), 16) if flags_match else None
    flag_names = (
        [value.strip() for value in (flags_match.group(2) or "").split(",") if value.strip()]
        if flags_match else []
    )
    is_unsigned = "code object is not signed at all" in text.lower()
    is_adhoc = first("Signature") == "adhoc" or (flags is not None and bool(flags & 0x2))
    authorities = values.get("Authority", [])
    if is_unsigned:
        kind = "unsigned"
    elif display["exitStatus"] != 0:
        kind = "query_error"
    elif is_adhoc:
        kind = "adhoc"
    elif any(value.startswith("Developer ID Application:") for value in authorities):
        kind = "developer_id_application"
    elif any(value.startswith("Developer ID Installer:") for value in authorities):
        kind = "developer_id_installer"
    elif any(value not in ("(unavailable)", "unavailable") for value in authorities):
        kind = "other_certificate"
    else:
        kind = "other_or_unknown_signature"
    team = first("TeamIdentifier")
    if team in ("not set", "none", ""):
        team = None
    timestamp = first("Timestamp")
    if timestamp in ("none", "not set", ""):
        timestamp = None
    entitlement_output = display["stdout"]
    if not entitlement_output:
        entitlements = {"status": "no_entitlements_returned", "value": None}
    else:
        try:
            parsed = plistlib.loads(entitlement_output.encode())
            entitlements = {"status": "parsed", "value": json_plist(parsed)}
        except (ValueError, plistlib.InvalidFileException, TypeError):
            entitlements = {"status": "unparsed", "value": None}
    return {
        "architecture": architecture,
        "signatureKind": kind,
        "identifier": first("Identifier"),
        "format": first("Format"),
        "authority": authorities,
        "teamIdentifier": team,
        "secureTimestamp": timestamp,
        "signedTime": first("Signed Time"),
        "codeDirectoryFlags": flags_match.group(1) if flags_match else None,
        "codeDirectoryFlagNames": flag_names,
        "hardenedRuntimeFlag": bool(flags & 0x10000) if flags is not None else None,
        "cdhash": first("CDHash"),
        "entitlements": entitlements,
        "display": display,
    }


def inspect(path, root, timeout):
    relative = str(path.relative_to(root))
    before_hash = sha256(path)
    before_stat = path.stat()
    arch_result = command([LIPO, "-archs", str(path)], timeout)
    architectures = arch_result["stdout"].split() if arch_result["exitStatus"] == 0 else []
    slices = []
    for architecture in architectures:
        display = command(
            [CODESIGN, "--display", "--verbose=4", "--entitlements", "-",
             "--arch", architecture, str(path)], timeout,
        )
        entry = signature_slice(display, architecture)
        entry["strictVerification"] = command(
            [CODESIGN, "--verify", "--strict", "--arch", architecture, "--verbose=4", str(path)],
            timeout,
        )
        entry["strictVerificationPassed"] = entry["strictVerification"]["exitStatus"] == 0
        slices.append(entry)
    verify = command(
        [CODESIGN, "--verify", "--strict", "--all-architectures", "--verbose=4", str(path)],
        timeout,
    )
    after_hash = sha256(path)
    kinds = sorted({entry["signatureKind"] for entry in slices})
    return {
        "path": relative,
        "bytes": before_stat.st_size,
        "sha256": before_hash,
        "sha256AfterAudit": after_hash,
        "contentChangedDuringAudit": before_hash != after_hash,
        "architectures": architectures,
        "architectureQuery": arch_result,
        "signatureKind": kinds[0] if len(kinds) == 1 else ("mixed" if kinds else "query_error"),
        "slices": slices,
        "strictVerificationPassed": verify["exitStatus"] == 0,
        "strictVerification": verify,
    }


def summarize(rows):
    slice_rows = [entry for row in rows for entry in row["slices"]]

    def presence(key):
        result = Counter()
        for row in rows:
            values = [item[key] for item in row["slices"]]
            if not values or any(item["signatureKind"] == "query_error" for item in row["slices"]):
                result["unknown"] += 1
            elif all(bool(value) for value in values):
                result["allSlicesPresent"] += 1
            elif any(bool(value) for value in values):
                result["someSlicesPresent"] += 1
            else:
                result["notDisplayedAllSlices"] += 1
        return dict(sorted(result.items()))

    teams = Counter()
    for row in rows:
        for team in {entry["teamIdentifier"] or "not_set" for entry in row["slices"]}:
            teams[team] += 1
    return {
        "machoFileCount": len(rows),
        "architectureSliceCount": len(slice_rows),
        "bySignatureKindFiles": dict(sorted(Counter(row["signatureKind"] for row in rows).items())),
        "bySignatureKindSlices": dict(sorted(Counter(row["signatureKind"] for row in slice_rows).items())),
        "byTeamIdentifierFiles": dict(sorted(teams.items())),
        "secureTimestampFiles": presence("secureTimestamp"),
        "hardenedRuntimeFlagFiles": presence("hardenedRuntimeFlag"),
        "strictVerification": {
            "passed": sum(row["strictVerificationPassed"] for row in rows),
            "failedOrUnavailable": sum(not row["strictVerificationPassed"] for row in rows),
        },
        "strictVerificationByArchitecture": {
            architecture: {
                "passed": sum(
                    entry["strictVerificationPassed"]
                    for entry in slice_rows if entry["architecture"] == architecture
                ),
                "failedOrUnavailable": sum(
                    not entry["strictVerificationPassed"]
                    for entry in slice_rows if entry["architecture"] == architecture
                ),
            }
            for architecture in sorted({entry["architecture"] for entry in slice_rows})
        },
        "developerIDApplicationFiles": sum(
            any(entry["signatureKind"] == "developer_id_application" for entry in row["slices"])
            for row in rows
        ),
        "nonAdhocAuthorityUnknownFiles": sum(
            any(entry["signatureKind"] == "other_or_unknown_signature" for entry in row["slices"])
            for row in rows
        ),
        "queryErrorFiles": sum(
            not row["architectures"]
            or any(entry["signatureKind"] == "query_error" for entry in row["slices"])
            or any(entry["strictVerification"].get("toolError", False) for entry in row["slices"])
            or row["strictVerification"].get("toolError", False)
            for row in rows
        ),
        "nativeFilesChangedDuringAudit": sum(row["contentChangedDuringAudit"] for row in rows),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime-root", type=Path, required=True, help="Existing installed runtime directory; never executed or modified")
    parser.add_argument("--jobs", type=int, default=4, help="Concurrent read-only file checks (1–16, default 4)")
    parser.add_argument("--timeout", type=int, default=30, help="Seconds per local inspection command (1–120, default 30)")
    args = parser.parse_args()
    if not 1 <= args.jobs <= 16 or not 1 <= args.timeout <= 120:
        parser.error("--jobs must be 1–16 and --timeout must be 1–120")
    root = args.runtime_root.expanduser().resolve(strict=True)
    if not root.is_dir() or root == Path(root.anchor):
        parser.error("--runtime-root must be a specific existing runtime directory")
    started = datetime.now(timezone.utc).isoformat()
    native_paths, symlinks = [], []

    def walk_error(error):
        raise error

    for directory, directories, filenames in os.walk(root, followlinks=False, onerror=walk_error):
        base = Path(directory)
        for name in list(directories):
            path = base / name
            if path.is_symlink():
                symlinks.append({"path": str(path.relative_to(root)), "target": os.readlink(path), "followed": False})
                directories.remove(name)
        for name in filenames:
            path = base / name
            if path.is_symlink():
                symlinks.append({"path": str(path.relative_to(root)), "target": os.readlink(path), "followed": False})
            elif path.is_file() and is_macho(path):
                native_paths.append(path)
    if not native_paths:
        raise ValueError("No regular Mach-O files found in --runtime-root")
    with ThreadPoolExecutor(max_workers=args.jobs) as executor:
        rows = list(executor.map(lambda path: inspect(path, root, args.timeout), sorted(native_paths)))
    summary = summarize(rows)
    report = {
        "schema": 1,
        "evidenceType": "Local read-only runtime Mach-O signature metadata and strict verification; not execution, installation, Gatekeeper or notarization evidence",
        "startedAtUTC": started,
        "finishedAtUTC": datetime.now(timezone.utc).isoformat(),
        "runtimeRoot": str(root),
        "host": {"machine": platform.machine(), "macOS": platform.mac_ver()[0]},
        "auditorSHA256": sha256(Path(__file__).resolve()),
        "scope": {
            "allRegularMachOFilesWithinRuntimeScanned": True,
            "symlinksFollowed": False,
            "runtimeCodeExecuted": False,
            "runtimeModified": False,
            "signingPerformed": False,
            "keychainOrCredentialQueries": 0,
            "explicitNetworkOrNotarizationQueries": 0,
            "gatekeeperOrSpctlInvocations": 0,
            "output": "JSON stdout only; caller chooses whether and where to save it",
        },
        "summary": summary,
        "interpretation": {
            "developerIDCount": "Counts only recognizable Developer ID Application authority text; unavailable/invalid identities are not proof of a different certificate class.",
            "missingTimestampOrFlags": "Not displayed means no corresponding value was returned, not an independent trust or notarization determination.",
            "verificationScope": "Whole-file strict verification checks all slices; per-architecture verification separates arm64 from unused unsigned x86_64 slices.",
        },
        "symlinksNotFollowed": sorted(symlinks, key=lambda row: row["path"]),
        "files": rows,
        "auditCompleted": summary["queryErrorFiles"] == 0 and summary["nativeFilesChangedDuringAudit"] == 0,
        "readyForPublication": False,
        "notVerified": [
            "Developer ID trust or certificate revocation policy beyond local codesign metadata/verification",
            "Apple notarization submission, acceptance, tickets, or stapling",
            "Gatekeeper, quarantine, clean-user installation or first execution",
            "Actual Python native-extension loading, library-validation policy, ONNX inference or PDF translation",
            "License compatibility, corresponding source, or permission to redistribute these binaries",
        ],
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report["auditCompleted"] else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print(json.dumps({"auditCompleted": False, "error": str(error), "readyForPublication": False}))
        sys.exit(1)
