#!/usr/bin/env python3
"""Non-notarized ad-hoc preview stages; the default preflight only reads inputs."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import stat
import subprocess
import sys
import zipfile


ROOT = pathlib.Path(__file__).resolve().parents[2]
NOTICES = ('LICENSE', 'THIRD_PARTY_NOTICES.md', 'CONTRIBUTING.md')
MACHO = {bytes.fromhex(value) for value in (
    'cffaedfe', 'cefaedfe', 'feedfacf', 'feedface',
    'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}


class PreviewError(Exception):
    pass


def require(value, message):
    if not value:
        raise PreviewError(message)


def sha(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def write_json(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')


def tree(root):
    """All paths, kinds, Unix permission bits and regular-file bytes; no xattrs."""
    require(root.is_dir() and not root.is_symlink(), 'Expected a non-symlink directory.')
    rows = []
    for path in [root] + sorted(root.rglob('*'), key=lambda item: bytes(item.relative_to(root))):
        relative = '.' if path == root else './' + str(path.relative_to(root))
        require(not any(ord(char) < 32 or ord(char) == 127 or char == '\\' for char in relative),
                'Control characters and backslashes are unsupported in preview paths.')
        require(not any(part in ('__pycache__', '__MACOSX', '.DS_Store') or part.startswith('._') or part.endswith(('.pyc', '.pyo')) for part in pathlib.PurePosixPath(relative).parts),
                'Generated cache or metadata sidecar is forbidden in preview inputs; rebuild from clean source.')
        require(not path.is_symlink(), 'Preview bundles must not contain symlinks; add an explicit policy first.')
        mode = stat.S_IMODE(path.lstat().st_mode)
        require(not mode & 0o7000, 'Special permission bits are unsupported in preview payloads.')
        if path.is_file():
            row = ('f', format(mode, 'o'), str(path.stat().st_size), sha(path), relative)
        elif path.is_dir():
            row = ('d', format(mode, 'o'), '-', '-', relative)
        else:
            raise PreviewError('Special files are unsupported in preview payloads.')
        rows.append(row)
    return ''.join('\t'.join(row) + '\n' for row in rows)


def tree_sha(value):
    return hashlib.sha256(value.encode()).hexdigest()


class Preview:
    def __init__(self, args, runner=None):
        self.args = args
        self.runner = runner or (lambda command: subprocess.run(command, capture_output=True, text=True, check=False))
        self.output = None
        self.commands = []

    def run(self, *command):
        command = [str(value) for value in command]
        try:
            result = self.runner(command)
        except OSError as error:
            result = subprocess.CompletedProcess(command, 127, '', str(error))
        entry = dict(command=command, exitCode=result.returncode, stdout=result.stdout, stderr=result.stderr)
        self.commands.append(entry)
        if self.output:
            with (self.output / 'commands.jsonl').open('a') as stream:
                stream.write(json.dumps(entry) + '\n')
        require(result.returncode == 0, f'{pathlib.Path(command[0]).name} failed ({result.returncode}); see command evidence.')
        return result.stdout + result.stderr if command[0] == '/usr/bin/codesign' else result.stdout

    def select(self):
        args = self.args
        require(re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', args.version), 'Use a numeric three-component version.')
        require(re.fullmatch(r'[1-9][0-9]{0,3}(?:\.[0-9]{1,2}){0,2}', args.build), 'Use a positive numeric build.')
        require(re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', args.bundle_id), 'Invalid expected bundle ID.')
        require(re.fullmatch(r'[0-9]+\.[0-9]+(?:\.[0-9]+)?', args.minimum_macos), 'Invalid minimum macOS version.')
        require(re.fullmatch(r'[0-9a-f]{40}', args.source), 'Declare a full lowercase source commit SHA.')
        selected = pathlib.Path(args.app).expanduser()
        require(not selected.is_symlink(), 'App argument must not be a symlink.')
        app = selected.resolve()
        require(app.is_dir() and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*\.app', app.name), 'Expected a safely named existing App bundle.')
        expected = dict(CFBundleIdentifier=args.bundle_id, CFBundleShortVersionString=args.version,
                        CFBundleVersion=args.build, LSMinimumSystemVersion=args.minimum_macos)
        return app, expected

    def new_output(self, inputs):
        require(self.args.output, 'Explicit write stages require a new --output directory.')
        selected = pathlib.Path(self.args.output).expanduser()
        require(not selected.is_symlink(), 'Output must not be a symlink.')
        output = selected.resolve()
        require(not output.exists() and output.parent.is_dir(), 'Output must be new with an existing parent.')
        for value in inputs:
            value = value.resolve()
            require(not output.is_relative_to(value) and not value.is_relative_to(output), 'Output must be independent of every input.')
        require(not pathlib.Path(self.args.source_root).resolve().is_relative_to(output), 'Output must not contain the source repository.')
        output.mkdir()
        self.output = output
        with (output / 'commands.jsonl').open('x') as stream:
            for row in self.commands:
                stream.write(json.dumps(row) + '\n')
        return output

    def entitlements(self, path):
        # Keep stdout separate from codesign's ordinary diagnostic stderr.
        self.run('/usr/bin/codesign', '-d', '--entitlements', '-', '--xml', path)
        result = self.commands[-1]
        require('invalid entitlements' not in result['stderr'].lower(), 'The input has invalid embedded entitlements.')
        value = plistlib.loads(result['stdout'].encode()) if result['stdout'].strip() else {}
        require(isinstance(value, dict) and value.get('com.apple.security.get-task-allow') in (None, False),
                'Debug entitlements are forbidden in preview distribution.')
        return value

    def inspect(self, app, expected, adhoc=True):
        before = tree(app)
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        require(isinstance(info, dict), 'Info.plist must be a dictionary.')
        for key, value in expected.items():
            require(info.get(key) == value, f'Unexpected {key}.')
        executable = info.get('CFBundleExecutable', '')
        require(isinstance(executable, str) and executable and pathlib.Path(executable).name == executable,
                'Invalid executable name.')
        main = app / 'Contents/MacOS' / executable
        require(main.is_file() and main.stat().st_mode & 0o111, 'Main executable is missing its executable permission.')
        self.run('/usr/bin/codesign', '--verify', '--deep', '--strict', '--all-architectures', app)
        details = self.run('/usr/bin/codesign', '-dvvv', app)
        if adhoc:
            require(re.search(r'^Signature=adhoc$', details, re.M), 'Only an already ad-hoc App is accepted; old certificate/unknown signatures are not ad-hoc.')
            require(not re.search(r'^Authority=', details, re.M), 'An ad-hoc preview must not claim a certificate authority.')
        app_entitlements = self.entitlements(app)
        items = []
        for path in sorted(app.rglob('*')):
            if path.is_dir():
                require(path.suffix not in {'.app', '.framework', '.xpc', '.appex', '.bundle'}, 'Nested code bundles need an explicit preview policy.')
                continue
            with path.open('rb') as stream:
                native = stream.read(4) in MACHO
            if not native:
                continue
            require(self.run('/usr/bin/lipo', '-archs', path).split() == ['arm64'], 'Preview requires arm64-only native code.')
            self.run('/usr/bin/codesign', '--verify', '--strict', '--all-architectures', path)
            signature = self.run('/usr/bin/codesign', '-dvvv', path)
            require(not adhoc or re.search(r'^Signature=adhoc$', signature, re.M), 'A native code item is not ad-hoc signed.')
            entitlements = self.entitlements(path)
            require(path == main or not entitlements, 'Nested code entitlements need an explicit per-item policy.')
            items.append(dict(path=path, runtime=bool(re.search(r'flags=.*\bruntime\b', signature))))
        require(any(item['path'] == main for item in items), 'Missing Mach-O main executable.')
        require(tree(app) == before, 'Input App changed during inspection.')
        return dict(manifest=before, entitlements=app_entitlements, items=items, signature=details)

    def source(self):
        source_root = pathlib.Path(self.args.source_root).resolve()
        commit = self.run('/usr/bin/git', '-C', source_root, 'rev-parse', '--verify', self.args.source + '^{commit}').strip()
        require(commit == self.args.source, 'Declared commit did not resolve exactly.')
        head = self.run('/usr/bin/git', '-C', source_root, 'rev-parse', 'HEAD').strip()
        dirty = bool(self.run('/usr/bin/git', '-C', source_root, 'status', '--porcelain', '--untracked-files=normal').strip())
        return dict(declaredCommit=commit, headObserved=head, worktreeClean=not dirty,
                    appBuildProvenanceVerified=False,
                    scope='Commit existence and App metadata only. This tool does not prove the App was built from that commit; frozen source/build binding remains a separate release gate.')

    @staticmethod
    def status(stage):
        return dict(schema=1, stage=stage, channel='non-notarized-preview',
                    packagingToolSHA256=sha(pathlib.Path(__file__)),
                    developerIDSigning='not-performed', notarization='not-performed', stapling='not-performed',
                    publisherIdentityVerified=False, gatekeeperAssessment='not-performed',
                    cleanMacInstallation='not-run', productWorkflows='not-run',
                    sourceLicenseCompliance='not-verified-by-this-tool', readyForPublication=False)

    def preflight(self):
        app, expected = self.select()
        inspection = self.inspect(app, expected)
        report = self.status('preflight')
        report.update(status='preflight-passed', appName=app.name, expected=expected, source=self.source(),
                      signatureKind='adhoc', nativeCodeItems=len(inspection['items']), appTreeSHA256=tree_sha(inspection['manifest']),
                      treeScope='Every path, file byte, permission mode and directory; symlinks/special files rejected. Extended attributes are outside this digest.')
        return app, expected, inspection, report

    def prepare(self):
        app, expected = self.select()
        # A certificate which is untrusted/invalid is not silently called verified.
        inspection = self.inspect(app, expected, adhoc=False)
        source = self.source()
        output = self.new_output([app])
        staged = output / app.name
        self.run('/usr/bin/ditto', app, staged)
        require(tree(staged) == inspection['manifest'], 'Working copy differs before explicit ad-hoc signing.')
        entitlements = output / 'preserved-entitlements.plist'
        with entitlements.open('xb') as stream:
            stream.write(plistlib.dumps(inspection['entitlements']))
        main = plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleExecutable']
        for item in sorted(inspection['items'], key=lambda row: len(row['path'].parts), reverse=True):
            relative = item['path'].relative_to(app)
            if relative == pathlib.Path('Contents/MacOS') / main:
                continue
            flags = ['--options', 'runtime'] if item['runtime'] else []
            self.run('/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', *flags, staged / relative)
        runtime = ['--options', 'runtime'] if any(item['path'] == app / 'Contents/MacOS' / main and item['runtime'] for item in inspection['items']) else []
        self.run('/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', *runtime, '--entitlements', entitlements, staged)
        prepared = self.inspect(staged, expected)
        require(prepared['entitlements'] == inspection['entitlements'], 'Ad-hoc preparation changed embedded entitlements.')
        require(tree(app) == inspection['manifest'], 'Original input changed during ad-hoc preparation.')
        (output / 'INPUT-APP-MANIFEST.tsv').write_text(inspection['manifest'])
        (output / 'APP-MANIFEST.tsv').write_text(prepared['manifest'])
        report = self.status('prepare-adhoc')
        report.update(status='prepared-adhoc', appName=app.name, expected=expected, source=source,
                      originalSignatureKind='adhoc' if 'Signature=adhoc' in inspection['signature'] else 'certificate-or-unknown; no publisher identity attested',
                      inputAppTreeSHA256=tree_sha(inspection['manifest']), appTreeSHA256=tree_sha(prepared['manifest']),
                      inputUnchanged=True, embeddedEntitlementsPreserved=True, signatureKind='adhoc')
        write_json(output / 'prepared.json', report)
        return report

    def package(self):
        app, expected, inspection, report = self.preflight()
        notice_root = pathlib.Path(self.args.notice_root).resolve()
        notices = [notice_root / name for name in NOTICES]
        require(all(path.is_file() and not path.is_symlink() for path in notices), 'Require regular LICENSE, THIRD_PARTY_NOTICES.md and CONTRIBUTING.md external attachments.')
        notice_hashes = {path.name: sha(path) for path in notices}
        output = self.new_output([app, *notices])
        name = f'Crosscript-preview-{self.args.version}-{self.args.build}'
        payload = output / name
        payload.mkdir()
        staged = payload / app.name
        self.run('/usr/bin/ditto', app, staged)
        require(tree(staged) == inspection['manifest'], 'Staged App differs from input.')
        for path in notices:
            with (payload / path.name).open('xb') as stream:
                stream.write(path.read_bytes())
        (payload / 'APP-MANIFEST.tsv').write_text(inspection['manifest'])
        (payload / 'PREVIEW.txt').write_text(
            'Crosscript non-notarized preview.\n'
            'Existing ad-hoc signature integrity checked; no publisher identity is authenticated.\n'
            'Developer ID signing, notarization, stapling: not-performed.\n'
            'Default Gatekeeper acceptance and clean-Mac installation: not verified.\n'
            'Ad-hoc integrity and this ZIP hash do not establish safety, licensing compliance or source provenance.\n'
            f'Declared source commit: {self.args.source}; App build provenance: not verified by this packaging tool; see companion RELEASE-BINDING.json.\n'
            'LICENSE/THIRD_PARTY_NOTICES.md/CONTRIBUTING.md are current external texts;\n'
            'their inclusion does not prove that this App matches the current source or dependency updates.\n'
            'Use the non-notarized-preview installation guide; retain quarantine.\n'
            'A trusted-source per-App Open Anyway exception, where macOS offers it, is a user decision.\n'
            'Do not override damage/malware/revocation warnings or disable system protection.\n')
        payload_before = tree(payload)
        archive = output / (name + '.zip')
        self.run('/usr/bin/ditto', '-c', '-k', '--norsrc', '--noextattr', '--qtn', '--noacl', '--keepParent', payload, archive)
        archive_sha = sha(archive)
        with zipfile.ZipFile(archive) as zipped:
            entries = zipped.infolist()
            require(len(entries) == len({item.filename for item in entries}), 'Duplicate archive members are unsupported.')
            for item in entries:
                path = pathlib.PurePosixPath(item.filename)
                require(not path.is_absolute() and '..' not in path.parts and '\\' not in item.filename,
                        'Unsafe archive member path.')
                require(not any(part in ('__pycache__', '__MACOSX', '.DS_Store') or part.startswith('._') or part.endswith(('.pyc', '.pyo')) for part in path.parts),
                        'Generated cache or metadata sidecar in archive.')
                require(path.parts and path.parts[0] == name and not stat.S_ISLNK(item.external_attr >> 16),
                        'Unexpected archive root, metadata sidecar or symlink.')
        extracted = output / 'extracted'
        extracted.mkdir()
        self.run('/usr/bin/ditto', '-x', '-k', archive, extracted)
        require(list(extracted.iterdir()) == [extracted / name], 'Unexpected extracted top-level content.')
        require(tree(extracted / name) == payload_before, 'Extracted full payload tree differs.')
        extracted_app = extracted / name / app.name
        final = self.inspect(extracted_app, expected)
        require(final['manifest'] == inspection['manifest'], 'Extracted full App tree differs.')
        require(tree(app) == inspection['manifest'] and tree(staged) == inspection['manifest'], 'Input or staged App changed during packaging.')
        require(tree(payload) == payload_before and sha(archive) == archive_sha, 'Payload/archive changed during verification.')
        require({path.name: sha(path) for path in notices} == notice_hashes, 'Notice inputs changed during packaging.')
        require({path.name: sha(payload / path.name) for path in notices} == notice_hashes, 'External notice copies differ.')
        with (output / 'APP-MANIFEST.tsv').open('x') as stream:
            stream.write(inspection['manifest'])
        (output / 'SHA256SUMS.txt').write_text(f'{archive_sha}  {archive.name}\n{tree_sha(inspection["manifest"])}  APP-MANIFEST.tsv\n')
        report.update(stage='package', status='packaged-and-verified-locally', archive=archive.name,
                      archiveSHA256=archive_sha, archiveBytes=archive.stat().st_size,
                      externalNotices=notice_hashes, currentNoticesProveOlderAppMatchesCurrentSource=False,
                      fullInputAppUnchanged=True, fullStagedAppMatches=True, fullExtractedPayloadMatches=True,
                      fullExtractedAppMatches=True, extractedAdhocIntegrity='passed')
        write_json(output / 'preview.json', report)
        return report


def main(argv=None, runner=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', choices=('preflight', 'prepare-adhoc', 'package'), default='preflight', nargs='?')
    parser.add_argument('--app', required=True)
    parser.add_argument('--source', required=True, help='Declared commit only; not a build-provenance attestation.')
    parser.add_argument('--source-root', default=str(ROOT))
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    parser.add_argument('--bundle-id', default='dev.uown.translation-workbench')
    parser.add_argument('--minimum-macos', default='14.2')
    parser.add_argument('--notice-root', default=str(ROOT))
    parser.add_argument('--output')
    args = parser.parse_args(argv)
    tool = Preview(args, runner)
    try:
        if args.stage == 'preflight':
            report = tool.preflight()[-1]
        else:
            report = tool.prepare() if args.stage == 'prepare-adhoc' else tool.package()
    except (PreviewError, OSError, ValueError, plistlib.InvalidFileException, zipfile.BadZipFile) as error:
        report = tool.status(args.stage)
        report.update(status='failed', error=str(error), commands=tool.commands)
        if tool.output:
            write_json(tool.output / 'failure.json', report)
        print(json.dumps(report, indent=2))
        return 1
    print(json.dumps(report, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
