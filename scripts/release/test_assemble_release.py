#!/usr/bin/env python3
"""Offline byte-preservation and boundary tests; no Mac tools or services."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import pathlib
import tarfile
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location('assemble_release', pathlib.Path(__file__).with_name('assemble-release.py'))
assembly = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(assembly)


class AssemblyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name).resolve()
        self.dmg = self.root / 'original installer.dmg'
        self.zip = self.root / 'original App.zip'
        self.source = self.root / '原始-source.tar.gz'
        self.third = self.root / 'third-party.tar.gz'
        self.evidence = self.root / 'records'
        self.evidence.mkdir()
        (self.evidence / 'nested').mkdir()
        (self.evidence / 'nested/local.json').write_text('{"scope": "local packaging only"}')
        (self.evidence / 'test result.txt').write_text('Not a real installation or service test.\n')
        for index, path in enumerate((self.dmg, self.zip, self.source, self.third)):
            path.write_bytes(bytes(range(256)) + bytes([index]) * 500)
        self.output = self.root / 'assembled'
        self.args = ['--dmg', str(self.dmg), '--zip', str(self.zip),
                     '--source-archive', str(self.source), '--third-party-archive', str(self.third),
                     '--evidence-dir', str(self.evidence), '--version', '0.2.0', '--build', '6',
                     '--output', str(self.output)]

    def invoke(self, extra=()):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = assembly.main([*self.args, *extra])
        return code, json.loads(output.getvalue())

    def inputs(self):
        return {str(path): (path.read_bytes(), path.stat().st_mode, path.stat().st_mtime_ns)
                for path in self.root.rglob('*') if path.is_file() and not path.is_relative_to(self.output)}

    def assert_rejected(self, extra=()):
        code, report = self.invoke(extra)
        self.assertEqual(code, 1, report)
        self.assertEqual(report['status'], 'failed')
        self.assertFalse(self.output.exists())
        return report

    def test_three_assets_roundtrip_original_names_bytes_hashes_and_release_body(self):
        before = self.inputs()
        code, report = self.invoke(['--repo', 'example/release', '--tag', 'v0.2.0-preview.6',
                                    '--source-commit', 'a' * 40])
        self.assertEqual(code, 0, report)
        self.assertEqual(self.inputs(), before)
        self.assertEqual(report['manualUploadAssetCount'], 3)
        assets = self.output / 'assets'
        self.assertEqual({p.name for p in assets.iterdir()}, {
            'Crosscript-preview-0.2.0-6.dmg', 'Crosscript-preview-0.2.0-6.zip',
            'Crosscript-materials-0.2.0-6.tar.gz'})
        self.assertEqual((assets / 'Crosscript-preview-0.2.0-6.dmg').read_bytes(), self.dmg.read_bytes())
        self.assertEqual((assets / 'Crosscript-preview-0.2.0-6.zip').read_bytes(), self.zip.read_bytes())
        root = 'Crosscript-materials-0.2.0-6/'
        with tarfile.open(assets / 'Crosscript-materials-0.2.0-6.tar.gz') as archive:
            entries = archive.getmembers()
            self.assertTrue(all(entry.isfile() for entry in entries))
            self.assertEqual(len(entries), len({entry.name for entry in entries}))
            content = {entry.name.removeprefix(root): archive.extractfile(entry).read() for entry in entries}
        self.assertEqual(content['source/' + self.source.name], self.source.read_bytes())
        self.assertEqual(content['third-party/' + self.third.name], self.third.read_bytes())
        self.assertEqual(content['evidence/nested/local.json'], (self.evidence / 'nested/local.json').read_bytes())
        manifest = json.loads(content['manifest.json'])
        for row in manifest['files']:
            self.assertEqual(len(content[row['path']]), row['bytes'])
            self.assertEqual(hashlib.sha256(content[row['path']]).hexdigest(), row['sha256'])
        for line in content['SHA256SUMS.txt'].decode().splitlines():
            digest, name = line.split('  ', 1)
            self.assertEqual(hashlib.sha256(content[name]).hexdigest(), digest)
        body = (self.output / 'RELEASE.md').read_text()
        self.assertIn('完整材料', body)
        for asset in report['assets']:
            self.assertIn(asset['sha256'], body)
            self.assertIn('https://github.com/example/release/releases/download/v0.2.0-preview.6/' + asset['name'], body)
            data = (assets / asset['name']).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), asset['sha256'])
            self.assertEqual(len(data), asset['bytes'])
        self.assertEqual(report['verification']['cleanMacInstallation'], 'not-run')
        self.assertEqual(report['verification']['onlineServiceTests'], 'not-run')
        self.assertIn('does not perform or claim a real Mac install', body)
        self.assertIn('does not verify source-to-App binding', body)
        self.assertEqual(json.loads((self.output / 'release-manifest.json').read_text()), report)

    def test_default_links_and_deterministic_materials(self):
        code, report = self.invoke()
        self.assertEqual(code, 0, report)
        self.assertEqual(report['repository'], 'yqia03/crosscript')
        self.assertEqual(report['tag'], 'v0.2.0-preview.6')
        original = (self.output / 'assets/Crosscript-materials-0.2.0-6.tar.gz').read_bytes()
        second = self.root / 'assembled-again'
        code, report = self.invoke(['--output', str(second)])
        self.assertEqual(code, 0, report)
        self.assertEqual(original, (second / 'assets/Crosscript-materials-0.2.0-6.tar.gz').read_bytes())

    def test_metadata_path_and_link_injection(self):
        for options in (['--version', '../escape'], ['--build', '0'], ['--build', '6/escape'],
                        ['--repo', '../repo'], ['--repo', 'owner/repo?query'],
                        ['--tag', '../tag'], ['--tag', 'tag\nline'], ['--source-commit', 'short']):
            with self.subTest(options=options):
                self.assert_rejected(options)

    def test_existing_output_never_overwritten(self):
        self.output.mkdir()
        sentinel = self.output / 'retain'
        sentinel.write_text('retained')
        code, _ = self.invoke()
        self.assertEqual(code, 1)
        self.assertEqual(sentinel.read_text(), 'retained')

    def test_output_inside_evidence_is_rejected_without_writes(self):
        destination = self.evidence / 'new-output'
        before = self.inputs()
        self.assert_rejected(['--output', str(destination)])
        self.assertFalse(destination.exists())
        self.assertEqual(self.inputs(), before)

    def test_symlink_file_and_parent_are_rejected(self):
        link = self.root / 'linked.dmg'
        link.symlink_to(self.dmg)
        self.assert_rejected(['--dmg', str(link)])
        parent_link = self.root / 'linked-records'
        parent_link.symlink_to(self.evidence, target_is_directory=True)
        self.assert_rejected(['--evidence-dir', str(parent_link)])
        self.assert_rejected(['--dmg', str(parent_link / 'nested/local.json')])
        self.assert_rejected(['--output', str(parent_link / 'output')])

    def test_symlink_directory_and_special_evidence_rejected(self):
        path = self.evidence / 'unsafe'
        for kind in ('file-link', 'directory-link', 'fifo', 'hardlink'):
            with self.subTest(kind=kind):
                if kind == 'file-link':
                    path.symlink_to(self.source)
                elif kind == 'directory-link':
                    path.symlink_to(self.root, target_is_directory=True)
                elif kind == 'fifo':
                    os.mkfifo(path)
                else:
                    os.link(self.source, path)
                try:
                    self.assert_rejected()
                finally:
                    path.unlink()

    def test_unsafe_evidence_names(self):
        for name in ('control\nname', 'back\\slash', 'tab\tname'):
            with self.subTest(name=name):
                unsafe = self.evidence / name
                unsafe.write_text('reject')
                try:
                    self.assert_rejected()
                finally:
                    unsafe.unlink()

    def test_relative_dotdot_input_paths_are_rejected(self):
        self.assert_rejected(['--source-archive', str(self.evidence / '..' / self.source.name)])

    def test_empty_evidence_and_empty_packages_rejected(self):
        empty = self.root / 'empty'
        empty.mkdir()
        self.assert_rejected(['--evidence-dir', str(empty)])
        self.dmg.write_bytes(b'')
        self.assert_rejected()

    def test_github_limit_is_strict_for_dmg_zip_and_compressed_materials(self):
        for item in (self.dmg, self.zip):
            with self.subTest(item=item):
                with mock.patch.object(assembly, 'GITHUB_LIMIT', item.stat().st_size):
                    self.assert_rejected()
        self.dmg.write_bytes(b'dmg')
        self.zip.write_bytes(b'zip')
        with mock.patch.object(assembly, 'GITHUB_LIMIT', 100):
            report = self.assert_rejected()
        self.assertIn('2 GiB', report['error'])

    def test_input_replacement_during_copy_fails_and_cleans_owned_output(self):
        original_copy = assembly.Input.copy

        def mutate(item, destination):
            original_copy(item, destination)
            if item.path == self.dmg:
                replacement = self.root / 'replacement'
                replacement.write_bytes(self.zip.read_bytes())
                replacement.replace(self.source)

        with mock.patch.object(assembly.Input, 'copy', mutate):
            report = self.assert_rejected()
        self.assertIn('changed', report['error'])

    def test_parent_substitution_never_redirects_writes_or_cleanup(self):
        parent = self.root / 'output-parent'
        parent.mkdir()
        destination = parent / 'assembled'
        relocated = self.root / 'renamed-output-parent'
        victim = self.root / 'victim'
        (victim / 'assembled/assets').mkdir(parents=True)
        sentinel = victim / 'assembled/retain'
        sentinel.write_bytes(b'unrelated files must survive')
        original_copy = assembly.Input.copy

        def substitute(item, target):
            original_copy(item, target)
            if item.path == self.dmg:
                parent.rename(relocated)
                parent.symlink_to(victim, target_is_directory=True)

        with mock.patch.object(assembly.Input, 'copy', substitute):
            code, report = self.invoke(['--output', str(destination)])
        self.assertEqual(code, 1, report)
        self.assertEqual(sentinel.read_bytes(), b'unrelated files must survive')
        self.assertEqual(list((victim / 'assembled/assets').iterdir()), [])
        self.assertFalse((relocated / 'assembled').exists())

    def test_output_substitution_never_deletes_the_replacement(self):
        relocated = self.root / 'renamed-output'
        victim = self.root / 'victim'
        (victim / 'assets').mkdir(parents=True)
        sentinel = victim / 'retain'
        sentinel.write_bytes(b'unrelated files must survive')
        original_copy = assembly.Input.copy

        def substitute(item, target):
            original_copy(item, target)
            if item.path == self.dmg:
                self.output.rename(relocated)
                self.output.symlink_to(victim, target_is_directory=True)

        with mock.patch.object(assembly.Input, 'copy', substitute):
            code, report = self.invoke()
        self.assertEqual(code, 1, report)
        self.assertEqual(sentinel.read_bytes(), b'unrelated files must survive')
        self.assertEqual(list((victim / 'assets').iterdir()), [])

    def test_copied_app_package_tampering_is_rejected(self):
        original_copy = assembly.Input.copy

        def tamper(item, destination):
            original_copy(item, destination)
            if item.path == self.zip:
                (self.output / 'assets/Crosscript-preview-0.2.0-6.dmg').write_bytes(b'tampered')

        with mock.patch.object(assembly.Input, 'copy', tamper):
            report = self.assert_rejected()
        self.assertIn('differs from its selected input', report['error'])

    def test_new_evidence_during_copy_fails(self):
        original_copy = assembly.Input.copy

        def mutate(item, destination):
            original_copy(item, destination)
            (self.evidence / 'arrived-late').write_text('new evidence')

        with mock.patch.object(assembly.Input, 'copy', mutate):
            report = self.assert_rejected()
        self.assertIn('tree changed', report['error'])

    def test_input_truncation_while_reading_is_detected(self):
        item = assembly.Input(self.source)
        self.source.write_bytes(b'truncated')
        with self.assertRaises(assembly.AssemblyError):
            item.copy(self.root / 'copy')

    def test_bounded_file_count_and_total_bytes(self):
        with mock.patch.object(assembly, 'MAX_FILES', 2):
            self.assert_rejected()
        with mock.patch.object(assembly, 'MAX_INPUT_BYTES', 2000):
            self.assert_rejected()


if __name__ == '__main__':
    unittest.main()
