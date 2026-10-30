#!/usr/bin/env python3
"""Read-only release inventory. Does not launch the app, load packages or contact services."""
import argparse
import csv
import email
import gzip
import hashlib
import json
import platform
import plistlib
import re
import subprocess
from pathlib import Path


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1048576), b''):
            h.update(block)
    return h.hexdigest()


def command(*args):
    result = subprocess.run(args, capture_output=True, text=True, check=False)
    return {'status': result.returncode, 'output': (result.stdout + result.stderr).strip()}


def normalized(name):
    return re.sub(r'[-_.]+', '-', name).lower()


def is_notice(path):
    return bool(re.search(r'license|licence|copying|notice|copyright|authors', path.name, re.I))


def version(text):
    return tuple(int(v) for v in text.split('.')) + (0,) * max(0, 3 - len(text.split('.')))


def macho(path, base):
    with path.open('rb') as stream:
        if stream.read(4) not in (bytes.fromhex(x) for x in ('cffaedfe','cefaedfe','feedfacf','feedface','cafebabe','bebafeca','cafebabf','bfbafeca')):
            return None
    loads = command('/usr/bin/otool', '-l', str(path))
    arches = command('/usr/bin/lipo', '-archs', str(path))
    if any(item['status'] for item in (loads, arches)):
        raise RuntimeError('Cannot inspect Mach-O: ' + str(path))
    minimums = re.findall(r'\bminos ([0-9.]+)', loads['output'])
    minimums += re.findall(r'LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version ([0-9.]+)', loads['output'])
    dependencies = re.findall(r'cmd LC_(?:LOAD_DYLIB|LOAD_WEAK_DYLIB|REEXPORT_DYLIB|LAZY_LOAD_DYLIB|LOAD_UPWARD_DYLIB)\s+cmdsize \d+\s+name (.*?) \(offset', loads['output'])
    install_names = re.findall(r'cmd LC_ID_DYLIB\s+cmdsize \d+\s+name (.*?) \(offset', loads['output'])
    rpaths = re.findall(r'LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset', loads['output'])
    return {'path': str(path.relative_to(base)), 'sha256': digest(path), 'architectures': arches['output'].split(),
            'minimumMacOS': sorted(set(minimums), key=version), 'dependencies': dependencies, 'installNames': install_names, 'rpaths': rpaths}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime-root', type=Path, required=True, help='Installed version directory, containing python/')
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    runtime, app, output = (p.resolve() for p in (args.runtime_root, args.app, args.output))
    if output.is_relative_to(runtime) or output.is_relative_to(app):
        raise ValueError('Evidence output must be outside the installed runtime and signed app')
    resources = app / 'Contents/Resources/PDF'
    manifest_path = resources / 'runtime-manifest.json'
    manifest = json.loads(manifest_path.read_text())
    if runtime.name != manifest['id']:
        raise ValueError('Runtime directory does not match the signed app manifest')
    site = runtime / 'python/lib/python3.12/site-packages'
    locked = {normalized(row['name']): row for row in manifest['wheels']}
    distributions, notice_texts, installed = [], [], set()
    for metadata in sorted(site.glob('*.dist-info/METADATA')):
        info = email.message_from_bytes(metadata.read_bytes())
        name = info['Name']; key = normalized(name); installed.add(key)
        expected = locked.get(key)
        if expected and expected['version'] != info['Version']:
            raise ValueError('Installed version differs from manifest: ' + name)
        notices = []
        record = metadata.parent / 'RECORD'
        with record.open(newline='') as stream:
            for row in csv.reader(stream):
                path = (site / row[0]).resolve()
                if is_notice(path) and path.is_file():
                    if not path.is_relative_to(runtime):
                        raise ValueError('Notice outside runtime: ' + row[0])
                    relative = str(path.relative_to(runtime))
                    notices.append({'path': relative, 'sha256': digest(path), 'bytes': path.stat().st_size})
                    notice_texts.append('\n\n===== ' + name + ' ' + info['Version'] + ': ' + relative + ' =====\n\n' + path.read_text(errors='replace'))
        declared = info.get('License-Expression') or (info.get('License', '').splitlines() or [''])[0]
        distributions.append({'name': name, 'version': info['Version'], 'manifestWheel': expected,
                              'declaredLicense': declared, 'licenseClassifiers': [c for c in info.get_all('Classifier', []) if c.startswith('License ::')],
                              'notices': notices, 'metadataSHA256': digest(metadata), 'scope': 'locked wheel' if expected else 'Python bootstrap distribution; not a BabelDOC wheel'})
    if set(locked) - installed:
        raise ValueError('Locked distributions missing: ' + ', '.join(sorted(set(locked) - installed)))
    native = []
    for path in sorted((runtime / 'python').rglob('*')):
        if path.is_file() and not path.is_symlink():
            row = macho(path, runtime)
            if row: native.append(row)
    app_binary = app / 'Contents/MacOS/TranslationWorkbench'
    app_native = macho(app_binary, app)
    if not app_native: raise ValueError('App executable is not Mach-O')
    all_native = native + [app_native]
    incompatible = [r['path'] for r in all_native if 'arm64' not in r['architectures'] or not r['minimumMacOS'] or any(version(v) > (14, 2, 0) for v in r['minimumMacOS'])]
    external = [{'path': r['path'], 'dependency': d} for r in all_native for d in r['dependencies'] if d.startswith('/') and not d.startswith(('/usr/lib/', '/System/Library/')) and not Path(d).is_relative_to(runtime)]
    development_rpaths = [{'path': r['path'], 'rpath': p} for r in all_native for p in r['rpaths'] if '/Developer/' in p]
    bundled_notices = []
    for path in sorted((resources / 'Notices').iterdir()):
        if path.is_file():
            bundled_notices.append({'path': str(path.relative_to(app)), 'sha256': digest(path), 'bytes': path.stat().st_size})
            notice_texts.append('\n\n===== Bundled notice: ' + path.name + ' =====\n\n' + path.read_text(errors='replace'))
    supplements = []
    supplement_index = resources / 'Notices/supplemental-sources.json'
    if supplement_index.is_file():
        for row in json.loads(supplement_index.read_text()):
            notice = (resources / 'Notices' / row['filename']).resolve()
            if not notice.is_relative_to((resources / 'Notices').resolve()) or digest(notice) != row['sha256']:
                raise ValueError('Invalid supplemental notice: ' + row['name'])
            supplements.append(row)
    supplemented = {normalized(row['name']) for row in supplements}
    plist = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    report = {'evidenceType': 'read-only installed-file metadata and Mach-O audit; not clean-user launch',
              'host': {'machine': platform.machine(), 'macOS': platform.mac_ver()[0]},
              'runtimeID': manifest['id'], 'engineVersion': manifest['engineVersion'], 'pythonVersion': manifest['pythonVersion'],
              'manifestSHA256': digest(manifest_path), 'downloadCount': 1 + len(manifest['wheels']) + len(manifest['assets']),
              'downloadBytes': sum(r['bytes'] for r in [manifest['python']] + manifest['wheels'] + manifest['assets']),
              'app': {'bundleID': plist['CFBundleIdentifier'], 'version': plist['CFBundleShortVersionString'], 'build': plist['CFBundleVersion'],
                      'minimumSystem': plist['LSMinimumSystemVersion'], 'binary': app_native,
                      'codesignVerify': command('/usr/bin/codesign', '--verify', '--strict', str(app)),
                      'codesignDisplay': command('/usr/bin/codesign', '-dvvv', str(app))},
              'distributions': distributions, 'bundledNotices': bundled_notices, 'supplementalNotices': supplements, 'nativeBinaries': native,
              'findings': {'incompatibleOrUnknownPlatform': incompatible, 'nonSystemAbsoluteDependencies': external,
                           'developmentSearchPaths': development_rpaths,
                           'lockedWheelsWithoutNoticeFiles': [r['name'] for r in distributions if r['manifestWheel'] and not r['notices']],
                           'lockedWheelsWithoutInstalledOrSupplementalNotice': [r['name'] for r in distributions if r['manifestWheel'] and not r['notices'] and normalized(r['name']) not in supplemented]},
              'notVerified': ['ordinary user without developer tools', 'macOS 14.2 device (permanently deferred)', 'notarization', 'Gatekeeper on another Mac', 'public distribution license choice'],
              'networkRequests': 0, 'credentialReads': 0, 'paidCostUSD': 0}
    output.mkdir(parents=True, exist_ok=True)
    (output / 'runtime-audit.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    (output / 'third-party-notices.txt.gz').write_bytes(gzip.compress(('Installed package and bundled notices, copied verbatim; this collection is not a license compatibility opinion.\n' + ''.join(notice_texts)).encode(), mtime=0))
    print(json.dumps({'lockedWheels': len(locked), 'installedDistributions': len(distributions), 'nativeBinaries': len(native), 'findings': report['findings'], 'signatureVerified': report['app']['codesignVerify']['status'] == 0}, ensure_ascii=False))


if __name__ == '__main__':
    main()
