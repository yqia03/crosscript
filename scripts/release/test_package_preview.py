#!/usr/bin/env python3
"""Offline preview-tool boundary checks; fake tools never access Apple services."""
import contextlib
import importlib.util
import io
import json
import pathlib
import plistlib
import shutil
import stat
import subprocess
import tempfile
import unittest
import zipfile


SPEC = importlib.util.spec_from_file_location('package_preview', pathlib.Path(__file__).with_name('package-preview.py'))
preview = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(preview)
SOURCE = 'a' * 40


class FakeTools:
    def __init__(self):
        self.calls = []
        self.adhoc = True
        self.prepared = set()
        self.architecture = 'arm64'
        self.invalid_signature = False
        self.entitlements = {'com.apple.security.device.audio-input': True}
        self.invalid_entitlements = False
        self.dirty = True
        self.change_extracted_file = False
        self.change_source_at_zip = None
        self.add_metadata_sidecar = False
        self.images = {}
        self.active_mounts = set()
        self.fail_attach = False
        self.fail_detaches = 0
        self.fail_image_verify = False
        self.mounted_mutation = None
        self.change_source_at_dmg = None
        self.change_copied_file = False
        self.invalid_mounted_signature = False

    def __call__(self, command):
        self.calls.append(command)
        name = pathlib.Path(command[0]).name
        output, error = '', ''
        code = 0
        if name == 'git':
            output = SOURCE if 'rev-parse' in command else (' M sample.swift\n' if self.dirty else '')
        elif name == 'lipo':
            output = self.architecture + '\n'
        elif name == 'codesign':
            if '--sign' in command:
                assert command[command.index('--sign') + 1] == '-'
                assert '--timestamp=none' in command and '--deep' not in command
                self.prepared.add(str(command[-1]))
                signature = pathlib.Path(command[-1]) / 'Contents/_CodeSignature'
                signature.mkdir(exist_ok=True)
                (signature / 'CodeResources').write_text('synthetic ad-hoc signature')
            elif '--verify' in command:
                on_mount = any(pathlib.Path(command[-1]).is_relative_to(path) for path in self.active_mounts)
                code = 1 if self.invalid_signature or (on_mount and self.invalid_mounted_signature) else 0
                error = 'CSSMERR_TP_NOT_TRUSTED' if code else ''
            elif '--entitlements' in command:
                output = plistlib.dumps(self.entitlements).decode()
                if self.invalid_entitlements:
                    output, error = '', 'warning: binary contains an invalid entitlements blob'
            elif '-dvvv' in command:
                is_prepared = any(str(command[-1]).startswith(path) for path in self.prepared)
                error = 'CodeDirectory v=20500 flags=0x10000(runtime)\n'
                error += 'Signature=adhoc\n' if self.adhoc or is_prepared else 'Authority=(unavailable)\nSignature size=1703\n'
        elif name == 'ditto':
            if '-c' in command:
                folder, archive = map(pathlib.Path, command[-2:])
                with zipfile.ZipFile(archive, 'w') as zipped:
                    for path in [folder] + sorted(folder.rglob('*')):
                        zipped.write(path, path.relative_to(folder.parent))
                    if self.add_metadata_sidecar:
                        zipped.writestr('__MACOSX/._private-metadata', b'synthetic test metadata')
                if self.change_source_at_zip:
                    self.change_source_at_zip.write_text('changed while packaging')
            elif '-x' in command:
                archive, destination = map(pathlib.Path, command[-2:])
                with zipfile.ZipFile(archive) as zipped:
                    for entry in zipped.infolist():
                        path = pathlib.Path(zipped.extract(entry, destination))
                        path.chmod(stat.S_IMODE(entry.external_attr >> 16))
                if self.change_extracted_file:
                    next(destination.glob('*/Input.app/Contents/Resources/example.txt')).write_text('tampered')
            else:
                shutil.copytree(command[-2], command[-1])
                if self.change_copied_file and 'copied' in pathlib.Path(command[-1]).parts:
                    (pathlib.Path(command[-1]) / 'Contents/Resources/example.txt').write_text('tampered copy')
        elif name == 'hdiutil':
            if command[1] == 'create':
                archive = pathlib.Path(command[-1])
                source = pathlib.Path(command[command.index('-srcfolder') + 1])
                image = archive.with_suffix('.contents')
                shutil.copytree(source, image, symlinks=True)
                self.images[archive] = image
                archive.write_bytes(b'synthetic compressed image')
                if self.change_source_at_dmg:
                    self.change_source_at_dmg.write_text('changed while building image')
            elif command[1] == 'verify':
                code = 1 if self.fail_image_verify else 0
            elif command[1] == 'attach':
                mountpoint = pathlib.Path(command[command.index('-mountpoint') + 1])
                shutil.copytree(self.images[pathlib.Path(command[-1])], mountpoint, dirs_exist_ok=True, symlinks=True)
                self.active_mounts.add(mountpoint)
                if self.mounted_mutation:
                    self.mounted_mutation(mountpoint)
                output = plistlib.dumps({'system-entities': [{'dev-entry': '/dev/disk99s1', 'mount-point': str(mountpoint)}]}).decode()
                code = 1 if self.fail_attach else 0
            elif command[1] == 'detach':
                if self.fail_detaches:
                    self.fail_detaches -= 1
                    code = 1
                else:
                    mountpoint = pathlib.Path(command[-1])
                    self.active_mounts.discard(mountpoint)
                    for path in mountpoint.iterdir():
                        if path.is_dir() and not path.is_symlink():
                            shutil.rmtree(path)
                        else:
                            path.unlink()
            else:
                raise AssertionError(f'Unknown hdiutil command: {command}')
        else:
            raise AssertionError(f'Forbidden or unknown tool: {command}')
        return subprocess.CompletedProcess(command, code, output, error)


class PreviewTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name).resolve()
        self.app = self.root / 'Input.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/Resources').mkdir()
        self.binary = self.app / 'Contents/MacOS/TranslationWorkbench'
        self.binary.write_bytes(bytes.fromhex('cffaedfe') + b'fake offline Mach-O')
        self.binary.chmod(0o755)
        self.resource = self.app / 'Contents/Resources/example.txt'
        self.resource.write_text('preserve all resources')
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleExecutable': 'TranslationWorkbench', 'CFBundleIdentifier': 'dev.uown.translation-workbench',
            'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '1', 'LSMinimumSystemVersion': '14.2'}))
        self.notices = self.root / 'notices'
        self.notices.mkdir()
        for name in preview.NOTICES:
            (self.notices / name).write_text('synthetic current legal attachment ' + name)
        self.tools = FakeTools()
        self.common = ['--app', str(self.app), '--source', SOURCE, '--source-root', str(self.root),
                       '--version', '0.1.0', '--build', '1', '--notice-root', str(self.notices)]
        self.before = preview.tree(self.app)

    def invoke(self, args):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = preview.main(args, self.tools)
        return code, json.loads(output.getvalue())

    def package(self):
        destination = self.root / 'package'
        code, result = self.invoke(['package', *self.common, '--output', str(destination)])
        return code, result, destination

    def package_dmg(self):
        destination = self.root / 'dmg-package'
        code, result = self.invoke(['package-dmg', *self.common, '--output', str(destination)])
        return code, result, destination

    def test_default_preflight_does_not_write_sign_upload_or_use_credentials(self):
        before = preview.tree(self.root)
        code, result = self.invoke(self.common)
        self.assertEqual(code, 0, result)
        self.assertEqual(preview.tree(self.root), before)
        self.assertFalse(any('--sign' in command for command in self.tools.calls))
        self.assertTrue(all(pathlib.Path(command[0]).name in ('codesign', 'lipo', 'git') for command in self.tools.calls))
        self.assertEqual(result['notarization'], 'not-performed')
        self.assertFalse(result['readyForPublication'])
        self.assertFalse(result['source']['appBuildProvenanceVerified'])
        self.assertFalse(result['source']['worktreeClean'])

    def test_old_unknown_certificate_is_not_called_adhoc(self):
        self.tools.adhoc = False
        code, result, destination = self.package()
        self.assertEqual(code, 1)
        self.assertIn('ad-hoc', result['error'])
        self.assertFalse(destination.exists())

    def test_untrusted_signature_is_rejected_before_copy_or_sign(self):
        self.tools.invalid_signature = True
        code, result = self.invoke(['prepare-adhoc', *self.common, '--output', str(self.root / 'prepared')])
        self.assertEqual(code, 1)
        self.assertFalse(any(pathlib.Path(command[0]).name == 'ditto' or '--sign' in command for command in self.tools.calls))
        self.assertEqual(preview.tree(self.app), self.before)

    def test_explicit_adhoc_preparation_preserves_input_and_entitlements(self):
        self.tools.adhoc = False
        code, result = self.invoke(['prepare-adhoc', *self.common, '--output', str(self.root / 'prepared')])
        self.assertEqual(code, 0, result)
        self.assertTrue(result['embeddedEntitlementsPreserved'])
        self.assertEqual(preview.tree(self.app), self.before)
        self.assertTrue(any('--sign' in command for command in self.tools.calls))
        self.assertFalse(any('security' in command[0] or 'xcrun' in command[0] for command in self.tools.calls))

    def test_debug_or_invalid_entitlements_are_not_silently_dropped(self):
        for invalid in ('debug', 'malformed'):
            with self.subTest(invalid=invalid):
                self.tools.entitlements = {'com.apple.security.get-task-allow': True} if invalid == 'debug' else {}
                self.tools.invalid_entitlements = invalid == 'malformed'
                code, _ = self.invoke(self.common)
                self.assertEqual(code, 1)

    def test_metadata_architecture_and_path_injection_are_rejected(self):
        for extra in (['--version', '../outside'], ['--build', '1/../../outside'], ['--bundle-id', 'unexpected.id'], ['--version', '0.2.0'], ['--source', 'short']):
            with self.subTest(extra=extra):
                code, _ = self.invoke([*self.common, *extra])
                self.assertEqual(code, 1)
        self.tools.architecture = 'x86_64 arm64'
        code, _ = self.invoke(self.common)
        self.assertEqual(code, 1)

    def test_main_requires_executable_permission(self):
        self.binary.chmod(0o644)
        code, result = self.invoke(self.common)
        self.assertEqual(code, 1)
        self.assertIn('executable permission', result['error'])

    def test_existing_or_input_nested_output_is_preserved(self):
        existing = self.root / 'existing'
        existing.mkdir()
        (existing / 'retain.txt').write_text('retain')
        for destination in (existing, self.app / 'nested'):
            with self.subTest(destination=destination):
                code, _ = self.invoke(['package', *self.common, '--output', str(destination)])
                self.assertEqual(code, 1)
        self.assertEqual((existing / 'retain.txt').read_text(), 'retain')
        self.assertEqual(preview.tree(self.app), self.before)

    def test_symlinks_cannot_escape_or_enter_payload(self):
        (self.app / 'Contents/link').symlink_to(self.root)
        code, _ = self.invoke(self.common)
        self.assertEqual(code, 1)

    def test_signed_inputs_with_generated_caches_or_metadata_are_rejected_without_mutation(self):
        resources = self.app / 'Contents/Resources'
        for name in ('__pycache__', '__MACOSX', '.DS_Store', '._example', 'bridge.pyc', 'bridge.pyo'):
            with self.subTest(name=name):
                extra = resources / name
                extra.write_bytes(b'synthetic forbidden input')
                code, result = self.invoke(self.common)
                self.assertEqual(code, 1)
                self.assertIn('Generated cache or metadata', result['error'])
                self.assertEqual(extra.read_bytes(), b'synthetic forbidden input')
                extra.unlink()
        self.assertFalse(any('--sign' in c for c in self.tools.calls))

    def test_missing_notice_cannot_produce_package(self):
        (self.notices / 'LICENSE').unlink()
        code, _, destination = self.package()
        self.assertEqual(code, 1)
        self.assertFalse(destination.exists())

    def test_whole_app_and_external_notices_roundtrip(self):
        code, result, destination = self.package()
        self.assertEqual(code, 0, result)
        self.assertTrue(result['fullInputAppUnchanged'])
        self.assertTrue(result['fullExtractedAppMatches'])
        self.assertTrue(result['fullExtractedPayloadMatches'])
        self.assertEqual(preview.tree(self.app), self.before)
        self.assertEqual((destination / 'APP-MANIFEST.tsv').read_text(), self.before)
        self.assertEqual(set(result['externalNotices']), set(preview.NOTICES))
        self.assertEqual(result['cleanMacInstallation'], 'not-run')
        self.assertEqual(result['developerIDSigning'], 'not-performed')
        self.assertEqual(result['notarization'], 'not-performed')
        self.assertFalse(result['readyForPublication'])

    def test_packaging_commands_request_metadata_omission_and_quarantine_preservation(self):
        code, result, _ = self.package()
        self.assertEqual(code, 0, result)
        command = next(c for c in self.tools.calls if pathlib.Path(c[0]).name == 'ditto' and '-c' in c)
        for flag in ('--norsrc', '--noextattr', '--qtn', '--noacl'):
            self.assertIn(flag, command)
        self.assertNotIn('--sequesterRsrc', command)
        self.assertNotIn('--noqtn', command)
        self.assertEqual(preview.tree(self.app), self.before)

    def test_archive_metadata_sidecar_is_rejected(self):
        self.tools.add_metadata_sidecar = True
        code, result, destination = self.package()
        self.assertEqual(code, 1)
        self.assertIn('metadata sidecar', result['error'])
        self.assertFalse((destination / 'preview.json').exists())

    def test_non_executable_resource_tampering_in_extract_is_failure(self):
        self.tools.change_extracted_file = True
        code, result, destination = self.package()
        self.assertEqual(code, 1)
        self.assertIn('payload tree differs', result['error'])
        self.assertTrue((destination / 'failure.json').is_file())
        self.assertFalse((destination / 'preview.json').exists())

    def test_input_change_during_zip_is_failure(self):
        self.tools.change_source_at_zip = self.resource
        code, result, destination = self.package()
        self.assertEqual(code, 1)
        self.assertIn('Input or staged App changed', result['error'])
        self.assertTrue((destination / 'failure.json').is_file())

    def test_dmg_roundtrip_preserves_input_notices_modes_and_adhoc_signature(self):
        code, result, destination = self.package_dmg()
        self.assertEqual(code, 0, result)
        self.assertEqual(result['stage'], 'package-dmg')
        self.assertTrue(result['archive'].endswith('.dmg'))
        self.assertTrue(result['fullMountedPayloadMatches'])
        self.assertTrue(result['fullCopiedAppMatches'])
        self.assertTrue(result['imageDetached'])
        self.assertFalse(self.tools.active_mounts)
        self.assertEqual(preview.tree(self.app), self.before)
        self.assertEqual(preview.tree(destination / 'copied' / self.app.name), self.before)
        self.assertEqual(set(result['externalNotices']), set(preview.NOTICES))
        self.assertEqual(result['notarization'], 'not-performed')
        self.assertEqual(result['developerIDSigning'], 'not-performed')
        self.assertFalse(result['readyForPublication'])
        self.assertFalse(any('--sign' in command for command in self.tools.calls))
        create = next(c for c in self.tools.calls if c[1] == 'create')
        self.assertEqual(create[create.index('-format') + 1], 'UDZO')
        attach = next(c for c in self.tools.calls if c[1] == 'attach')
        for flag in ('-readonly', '-nobrowse', '-noautoopen'):
            self.assertIn(flag, attach)
        mounted_verifies = [c for c in self.tools.calls if '--verify' in c and 'mounted' in pathlib.Path(c[-1]).parts]
        copied_verifies = [c for c in self.tools.calls if '--verify' in c and 'copied' in pathlib.Path(c[-1]).parts]
        self.assertTrue(mounted_verifies and copied_verifies)

    def test_dmg_applications_link_is_the_only_symlink_exception(self):
        payload = self.root / 'payload'
        payload.mkdir()
        (payload / 'Applications').symlink_to('/Applications')
        self.assertIn('/Applications', preview.dmg_tree(payload))
        with self.assertRaises(preview.PreviewError):
            preview.tree(payload)
        (payload / 'extra').symlink_to('/Applications')
        with self.assertRaises(preview.PreviewError):
            preview.dmg_tree(payload)
        (payload / 'extra').unlink()
        (payload / 'Applications').unlink()
        (payload / 'Applications').symlink_to('/tmp')
        with self.assertRaises(preview.PreviewError):
            preview.dmg_tree(payload)

    def test_dmg_mounted_payload_mismatches_always_detach_and_preserve_input(self):
        def wrong_link(root):
            (root / 'Applications').unlink()
            (root / 'Applications').symlink_to('/tmp')

        mutations = {
            'file bytes': lambda root: (root / 'Input.app/Contents/Resources/example.txt').write_text('tampered'),
            'permission mode': lambda root: (root / 'Input.app/Contents/MacOS/TranslationWorkbench').chmod(0o644),
            'missing notice': lambda root: (root / 'LICENSE').unlink(),
            'extra member': lambda root: (root / 'unexpected.txt').write_text('unexpected'),
            'unsafe link': wrong_link,
        }
        for kind, mutate in mutations.items():
            with self.subTest(kind=kind):
                self.tools.mounted_mutation = mutate
                code, result, destination = self.package_dmg()
                self.assertEqual(code, 1, result)
                self.assertFalse(self.tools.active_mounts)
                self.assertEqual(preview.tree(self.app), self.before)
                self.assertTrue((destination / 'failure.json').is_file())
                self.assertFalse((destination / 'preview.json').exists())
                shutil.rmtree(destination)

    def test_dmg_partial_attach_failure_still_detaches(self):
        self.tools.fail_attach = True
        code, result, _ = self.package_dmg()
        self.assertEqual(code, 1, result)
        self.assertFalse(self.tools.active_mounts)
        self.assertTrue(any(c[1] == 'detach' for c in self.tools.calls))
        self.assertEqual(preview.tree(self.app), self.before)

    def test_dmg_detach_failure_retries_with_force(self):
        self.tools.fail_detaches = 1
        code, result, _ = self.package_dmg()
        self.assertEqual(code, 0, result)
        self.assertFalse(self.tools.active_mounts)
        detaches = [c for c in self.tools.calls if c[1] == 'detach']
        self.assertEqual(len(detaches), 2)
        self.assertIn('-force', detaches[-1])

    def test_dmg_detach_failure_is_not_reported_as_success(self):
        self.tools.fail_detaches = 2
        self.tools.mounted_mutation = lambda root: (root / 'LICENSE').unlink()
        code, result, destination = self.package_dmg()
        self.assertEqual(code, 1, result)
        self.assertIn('detach also failed', result['error'])
        self.assertFalse((destination / 'preview.json').exists())
        self.assertEqual(preview.tree(self.app), self.before)

    def test_dmg_invalid_mounted_signature_detaches(self):
        self.tools.invalid_mounted_signature = True
        code, result, _ = self.package_dmg()
        self.assertEqual(code, 1, result)
        self.assertFalse(self.tools.active_mounts)
        self.assertEqual(preview.tree(self.app), self.before)

    def test_dmg_copy_mismatch_detaches(self):
        self.tools.change_copied_file = True
        code, result, _ = self.package_dmg()
        self.assertEqual(code, 1, result)
        self.assertIn('App copied from DMG differs', result['error'])
        self.assertFalse(self.tools.active_mounts)
        self.assertEqual(preview.tree(self.app), self.before)

    def test_dmg_image_verification_failure_never_mounts(self):
        self.tools.fail_image_verify = True
        code, result, _ = self.package_dmg()
        self.assertEqual(code, 1, result)
        self.assertFalse(any(c[1] == 'attach' for c in self.tools.calls))
        self.assertEqual(preview.tree(self.app), self.before)

    def test_dmg_input_change_during_creation_is_failure(self):
        self.tools.change_source_at_dmg = self.resource
        code, result, destination = self.package_dmg()
        self.assertEqual(code, 1, result)
        self.assertIn('Input or staged App changed', result['error'])
        self.assertFalse(self.tools.active_mounts)
        self.assertFalse((destination / 'preview.json').exists())


if __name__ == '__main__':
    unittest.main()
