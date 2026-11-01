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
import sys
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
        self.mount_images = {}
        self.fail_attach = False
        self.fail_readonly_attach = False
        self.fail_detaches = 0
        self.only_fail_readonly_detach = False
        self.fail_image_verify = False
        self.mounted_mutation = None
        self.change_source_at_dmg = None
        self.change_copied_file = False
        self.invalid_mounted_signature = False
        self.omit_background = False
        self.omit_layout = False
        self.empty_layout = False
        self.fail_layout = False
        self.fail_layout_verify = False
        self.layout_timeout = False
        self.fail_convert = False
        self.detach_timeouts = 0
        self.layout_mutation = None

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
        elif name == 'swift':
            if not self.omit_background:
                pathlib.Path(command[-1]).write_bytes(b'synthetic retina TIFF background')
        elif command[0] == sys.executable and pathlib.Path(command[2]).name == 'write-dmg-layout.py':
            if self.layout_timeout:
                raise subprocess.TimeoutExpired(command, 30)
            mountpoint = pathlib.Path(command[-2])
            action = command[3]
            if self.fail_layout or (action == 'verify' and self.fail_layout_verify):
                code, error = 1, 'Layout metadata generation/validation failed'
            else:
                if action == 'create':
                    if not self.omit_layout:
                        (mountpoint / '.DS_Store').write_bytes(b'' if self.empty_layout else b'synthetic Finder metadata')
                    if self.layout_mutation:
                        self.layout_mutation(mountpoint)
                output = json.dumps(dict(status='verified', implementation='vendored-ds_store-mac_alias'))
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
            elif command[1] == 'convert':
                if self.fail_convert:
                    code, error = 1, 'synthetic conversion failure'
                else:
                    source = self.images[pathlib.Path(command[2])]
                    archive = pathlib.Path(command[command.index('-o') + 1])
                    image = archive.with_suffix('.contents')
                    shutil.copytree(source, image, symlinks=True)
                    self.images[archive] = image
                    archive.write_bytes(b'synthetic final compressed image')
            elif command[1] == 'verify':
                code = 1 if self.fail_image_verify else 0
            elif command[1] == 'attach':
                mountpoint = pathlib.Path(command[command.index('-mountpoint') + 1])
                shutil.copytree(self.images[pathlib.Path(command[-1])], mountpoint, dirs_exist_ok=True, symlinks=True)
                self.active_mounts.add(mountpoint)
                self.mount_images[mountpoint] = (self.images[pathlib.Path(command[-1])], '-readwrite' in command)
                if self.mounted_mutation and '-readonly' in command:
                    self.mounted_mutation(mountpoint)
                output = plistlib.dumps({'system-entities': [{'dev-entry': '/dev/disk99s1', 'mount-point': str(mountpoint)}]}).decode()
                code = 1 if self.fail_attach or (self.fail_readonly_attach and '-readonly' in command) else 0
            elif command[1] == 'detach':
                mountpoint = pathlib.Path(command[-1])
                if self.detach_timeouts:
                    self.detach_timeouts -= 1
                    raise subprocess.TimeoutExpired(command, 20)
                if self.fail_detaches and (not self.only_fail_readonly_detach or not self.mount_images[mountpoint][1]):
                    self.fail_detaches -= 1
                    code = 1
                else:
                    mountpoint = pathlib.Path(command[-1])
                    self.active_mounts.discard(mountpoint)
                    image, writable = self.mount_images.pop(mountpoint)
                    if writable:
                        shutil.rmtree(image)
                        shutil.copytree(mountpoint, image, symlinks=True)
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
        self.assertEqual(create[create.index('-format') + 1], 'UDRW')
        convert = next(c for c in self.tools.calls if c[1] == 'convert')
        self.assertEqual(convert[convert.index('-format') + 1], 'UDZO')
        attach = next(c for c in self.tools.calls if c[1] == 'attach' and '-readonly' in c)
        for flag in ('-readonly', '-nobrowse', '-noautoopen'):
            self.assertIn(flag, attach)
        mounted_verifies = [c for c in self.tools.calls if '--verify' in c and 'mounted' in pathlib.Path(c[-1]).parts]
        copied_verifies = [c for c in self.tools.calls if '--verify' in c and 'copied' in pathlib.Path(c[-1]).parts]
        self.assertTrue(mounted_verifies and copied_verifies)
        contents = self.tools.images[destination / result['archive']]
        self.assertEqual({p.name for p in contents.iterdir() if not p.name.startswith('.')},
                         {self.app.name, 'Applications'})
        for notice in preview.NOTICES:
            self.assertEqual((contents / '.release-info' / notice).read_bytes(), (self.notices / notice).read_bytes())
        self.assertTrue((contents / '.DS_Store').stat().st_size)
        self.assertTrue((contents / '.background/installer.tiff').stat().st_size)
        self.assertEqual(result['finderPresentation']['layoutGeneration'], 'passed')
        self.assertFalse(result['finderPresentation']['requiresFinderGUI'])
        self.assertFalse(any(pathlib.Path(c[0]).name == 'osascript' for c in self.tools.calls))
        self.assertEqual(result['finderPresentation']['readOnlyLayoutValidation']['status'], 'verified')
        self.assertEqual(result['finderPresentation']['visualInspection'], 'not-run')
        self.assertIn('./.background/installer.tiff', (destination / 'DMG-PAYLOAD-MANIFEST.tsv').read_text())
        self.assertIn('./.DS_Store', (destination / 'DMG-PAYLOAD-MANIFEST.tsv').read_text())

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
            'missing notice': lambda root: (root / '.release-info/LICENSE').unlink(),
            'background changed': lambda root: (root / '.background/installer.tiff').write_bytes(b'tampered'),
            'background missing': lambda root: (root / '.background/installer.tiff').unlink(),
            'layout changed': lambda root: (root / '.DS_Store').write_bytes(b'tampered'),
            'layout missing': lambda root: (root / '.DS_Store').unlink(),
            'App metadata': lambda root: (root / 'Input.app/Contents/.DS_Store').write_bytes(b'forbidden'),
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
        for fault in ('fail_attach', 'fail_readonly_attach'):
            with self.subTest(fault=fault):
                setattr(self.tools, fault, True)
                code, result, destination = self.package_dmg()
                self.assertEqual(code, 1, result)
                self.assertFalse(self.tools.active_mounts)
                self.assertTrue(any(c[1] == 'detach' for c in self.tools.calls))
                self.assertEqual(preview.tree(self.app), self.before)
                setattr(self.tools, fault, False)
                shutil.rmtree(destination)

    def test_dmg_detach_failure_retries_with_force(self):
        for readonly in (False, True):
            with self.subTest(readonly=readonly):
                self.tools.calls.clear()
                self.tools.fail_detaches = 1
                self.tools.only_fail_readonly_detach = readonly
                code, result, destination = self.package_dmg()
                self.assertEqual(code, 0, result)
                self.assertFalse(self.tools.active_mounts)
                detaches = [c for c in self.tools.calls if c[1] == 'detach']
                self.assertEqual(len(detaches), 3)
                self.assertEqual(sum('-force' in c for c in detaches), 1)
                shutil.rmtree(destination)

    def test_dmg_detach_failure_is_not_reported_as_success(self):
        for readonly in (False, True):
            with self.subTest(readonly=readonly):
                self.tools = FakeTools()
                self.tools.fail_detaches = 2
                self.tools.only_fail_readonly_detach = readonly
                mutate = lambda root: (root / '.release-info/LICENSE').unlink()
                if readonly:
                    self.tools.mounted_mutation = mutate
                else:
                    self.tools.layout_mutation = mutate
                code, result, destination = self.package_dmg()
                self.assertEqual(code, 1, result)
                self.assertIn('detach also failed', result['error'])
                self.assertFalse((destination / 'preview.json').exists())
                self.assertEqual(preview.tree(self.app), self.before)
                shutil.rmtree(destination)

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

    def test_dmg_image_verification_failure_never_mounts_final_image(self):
        self.tools.fail_image_verify = True
        code, result, _ = self.package_dmg()
        self.assertEqual(code, 1, result)
        self.assertFalse(any(c[1] == 'attach' and '-readonly' in c for c in self.tools.calls))
        self.assertFalse(self.tools.active_mounts)
        self.assertEqual(preview.tree(self.app), self.before)

    def test_dmg_input_change_during_creation_is_failure(self):
        self.tools.change_source_at_dmg = self.resource
        code, result, destination = self.package_dmg()
        self.assertEqual(code, 1, result)
        self.assertIn('Input or staged App changed', result['error'])
        self.assertFalse(self.tools.active_mounts)
        self.assertFalse((destination / 'preview.json').exists())


    def test_dmg_missing_artwork_or_layout_cannot_succeed(self):
        for fault in ('omit_background', 'omit_layout', 'empty_layout'):
            with self.subTest(fault=fault):
                setattr(self.tools, fault, True)
                code, result, destination = self.package_dmg()
                self.assertEqual(code, 1, result)
                self.assertFalse(self.tools.active_mounts)
                self.assertFalse((destination / 'preview.json').exists())
                self.assertTrue((destination / 'failure.json').is_file())
                self.assertEqual(preview.tree(self.app), self.before)
                setattr(self.tools, fault, False)
                shutil.rmtree(destination)

    def test_dmg_layout_error_timeout_and_conversion_error_leave_no_active_mount(self):
        for fault in ('fail_layout', 'layout_timeout', 'fail_convert', 'fail_layout_verify'):
            with self.subTest(fault=fault):
                setattr(self.tools, fault, True)
                code, result, destination = self.package_dmg()
                self.assertEqual(code, 1, result)
                self.assertFalse(self.tools.active_mounts)
                self.assertFalse((destination / 'preview.json').exists())
                self.assertTrue((destination / 'failure.json').is_file())
                self.assertEqual(preview.tree(self.app), self.before)
                setattr(self.tools, fault, False)
                shutil.rmtree(destination)

    def test_dmg_layout_generator_cannot_add_unexpected_members_or_modify_payload(self):
        mutations = {
            'unknown hidden member': lambda root: (root / '.unexpected').write_text('unexpected'),
            'App metadata': lambda root: (root / 'Input.app/Contents/.DS_Store').write_bytes(b'forbidden'),
            'background': lambda root: (root / '.background/installer.tiff').write_bytes(b'tampered'),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                self.tools.layout_mutation = mutate
                code, result, destination = self.package_dmg()
                self.assertEqual(code, 1, result)
                self.assertFalse(self.tools.active_mounts)
                self.assertFalse((destination / 'preview.json').exists())
                self.assertEqual(preview.tree(self.app), self.before)
                shutil.rmtree(destination)

    def test_dmg_detach_timeout_retries_with_force(self):
        self.tools.detach_timeouts = 1
        code, result, _ = self.package_dmg()
        self.assertEqual(code, 0, result)
        self.assertFalse(self.tools.active_mounts)
        detaches = [c for c in self.tools.calls if c[1] == 'detach']
        self.assertIn('-force', detaches[1])

    def test_dmg_repeated_detach_timeouts_cannot_report_success(self):
        self.tools.detach_timeouts = 2
        self.tools.fail_layout = True
        code, result, destination = self.package_dmg()
        self.assertEqual(code, 1, result)
        self.assertIn('detach also failed', result['error'])
        self.assertFalse((destination / 'preview.json').exists())
        self.assertEqual(preview.tree(self.app), self.before)


    def test_headless_layout_cli_refuses_to_write_metadata_into_source_directory(self):
        source = self.root / 'source-folder'
        (source / self.app.name).mkdir(parents=True)
        (source / '.background').mkdir()
        (source / '.background/installer.tiff').write_bytes(b'synthetic background')
        (source / '.release-info').mkdir()
        (source / '.release-info/finder-layout.json').write_text(json.dumps(preview.DMG_LAYOUT))
        before = preview.tree(source)
        result = subprocess.run([sys.executable, '-B', str(pathlib.Path(__file__).with_name('write-dmg-layout.py')),
                                 'create', str(source), self.app.name], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('mounted image', json.loads(result.stdout)['error'])
        self.assertEqual(preview.tree(source), before)


    @unittest.skipUnless(sys.platform == 'darwin' and pathlib.Path('/usr/bin/swift').exists(),
                         'Native installer artwork verification requires macOS Swift/AppKit')
    def test_native_background_retina_arrow_and_instructions_fit_the_safe_area(self):
        artwork = self.root / 'installer.tiff'
        cache = self.root / 'swift-module-cache'
        drawing = pathlib.Path(__file__).with_name('draw-dmg-background.swift')
        generated = subprocess.run(['/usr/bin/swift', '-module-cache-path', str(cache), str(drawing), str(artwork)],
                                   capture_output=True, text=True, timeout=120)
        self.assertEqual(generated.returncode, 0, generated.stdout + generated.stderr)
        # Inspect the actual raster pixels in both representations through AppKit.
        # This catches a Retina-only double transform and text below Finder's
        # visible area even when all metadata dimensions and hashes look correct.
        check = r'''import AppKit
import Foundation
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let reps = NSBitmapImageRep.imageReps(with: data).compactMap { $0 as? NSBitmapImageRep }
guard reps.count == 2 else { fatalError("Expected standard and Retina representations") }
for rep in reps {
    let scale = rep.pixelsWide / 640
    guard [1, 2].contains(scale), rep.pixelsHigh == 400 * scale else { fatalError("Wrong raster size") }
    var arrowInk = 0
    var chineseInk = 0
    var englishInk = 0
    for y in stride(from: 0, to: rep.pixelsHigh, by: scale) {
        for x in stride(from: 0, to: rep.pixelsWide, by: scale) {
            let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
            if c.redComponent < 0.55 && c.greenComponent < 0.60 && c.blueComponent < 0.60 {
                let px = x / scale
                let py = y / scale
                guard (140...500).contains(px), (160...339).contains(py) else {
                    fatalError("Artwork ink falls outside the visible safe area: \(px),\(py) at scale \(scale)")
                }
                if (260...370).contains(px) && (160...225).contains(py) { arrowInk += 1 }
                if (295...323).contains(py) { chineseInk += 1 }
                if (324...339).contains(py) { englishInk += 1 }
            }
        }
    }
    guard arrowInk > 30, chineseInk > 50, englishInk > 20 else {
        fatalError("An arrow or instruction line is missing in scale \(scale)")
    }
}
print("Both artwork representations keep the arrow and complete instructions visible")
'''
        inspected = subprocess.run(['/usr/bin/swift', '-module-cache-path', str(cache), '-e', check, str(artwork)],
                                   capture_output=True, text=True, timeout=120)
        self.assertEqual(inspected.returncode, 0, inspected.stdout + inspected.stderr)


if __name__ == '__main__':
    unittest.main()
