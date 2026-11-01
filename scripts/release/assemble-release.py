#!/usr/bin/env python3
"""Assemble three local Release assets without signing, installing or uploading."""
import argparse
import gzip
import hashlib
import io
import json
import os
import pathlib
import re
import shutil
import stat
import sys
import tarfile
from urllib.parse import quote


GITHUB_LIMIT = 2 * 1024 ** 3  # Published files must be strictly smaller.
BLOCK = 1024 * 1024
MAX_FILES = 100000
MAX_INPUT_BYTES = 16 * 1024 ** 3


class AssemblyError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise AssemblyError(message)


def safe_component(value):
    require(value not in ('', '.', '..') and not any(
        ord(c) < 32 or ord(c) == 127 or c in '/\\' for c in value),
        'Unsafe path component: ' + repr(value))


def absolute(value):
    path = pathlib.Path(value).expanduser().absolute()
    for part in path.parts[1:]:
        safe_component(part)
    return path


def open_safe(path, directory=False):
    """Walk every component with no-follow directory descriptors, including parents."""
    path = absolute(path)
    descriptor = os.open(path.anchor, os.O_RDONLY | os.O_DIRECTORY)
    try:
        for index, part in enumerate(path.parts[1:]):
            is_directory = directory or index < len(path.parts) - 2
            flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
            if is_directory:
                flags |= os.O_DIRECTORY
            child = os.open(part, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        info = os.fstat(descriptor)
        require(stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode),
                'Expected a regular file or directory: ' + str(path))
        if not directory:
            require(info.st_nlink == 1, 'Hard-linked inputs are unsupported: ' + str(path))
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def fingerprint(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns, info.st_nlink)


def identity(info):
    return info.st_dev, info.st_ino


class OutputFile:
    """A file relative to an owned directory descriptor, never a mutable parent path."""
    def __init__(self, owner, descriptor, name):
        safe_component(name)
        self.owner, self.descriptor, self.name = owner, descriptor, name

    def open(self, mode):
        self.owner.verify()
        flags = os.O_NOFOLLOW | os.O_NONBLOCK
        flags |= os.O_RDONLY if mode == 'rb' else os.O_WRONLY | os.O_CREAT | os.O_EXCL
        descriptor = os.open(self.name, flags, 0o644, dir_fd=self.descriptor)
        try:
            require(stat.S_ISREG(os.fstat(descriptor).st_mode), 'Output file is no longer regular.')
            return os.fdopen(descriptor, mode)
        except BaseException:
            os.close(descriptor)
            raise

    def stat(self):
        return os.stat(self.name, dir_fd=self.descriptor, follow_symlinks=False)

    def write_bytes(self, data):
        with self.open('xb') as stream:
            stream.write(data)

    def write_text(self, text, encoding='utf-8'):
        self.write_bytes(text.encode(encoding))


class Output:
    """Anchor creation, writes and rollback to the directories this task owns."""
    def __init__(self, path, expected_parent):
        self.path = path
        self.parent = open_safe(path.parent, directory=True)
        self.root = self.assets = None
        try:
            require(identity(os.fstat(self.parent)) == expected_parent, 'Output parent changed during assembly.')
            os.mkdir(path.name, 0o700, dir_fd=self.parent)
            self.root = os.open(path.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.parent)
            os.mkdir('assets', dir_fd=self.root)
            self.assets = os.open('assets', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.root)
        except BaseException:
            self.close()
            raise

    def verify(self):
        descriptor = open_safe(self.path.parent, directory=True)
        try:
            require(identity(os.fstat(descriptor)) == identity(os.fstat(self.parent)), 'Output parent changed during assembly.')
            require(identity(os.stat(self.path.name, dir_fd=self.parent, follow_symlinks=False)) == identity(os.fstat(self.root)),
                    'Output directory changed during assembly.')
            require(identity(os.stat('assets', dir_fd=self.root, follow_symlinks=False)) == identity(os.fstat(self.assets)),
                    'Output assets directory changed during assembly.')
        finally:
            os.close(descriptor)

    def file(self, name, asset=False):
        return OutputFile(self, self.assets if asset else self.root, name)

    def remove(self):
        # A renamed parent is safe: parent is still its original open descriptor.
        # If the output itself was replaced, refuse to touch the replacement.
        try:
            current = os.stat(self.path.name, dir_fd=self.parent, follow_symlinks=False)
        except FileNotFoundError:
            return
        if identity(current) == identity(os.fstat(self.root)):
            shutil.rmtree(self.path.name, dir_fd=self.parent)

    def close(self):
        for descriptor in (self.assets, self.root, self.parent):
            if descriptor is not None:
                os.close(descriptor)


class Input:
    def __init__(self, path, member=None, published=False, byte_budget=None):
        self.path = absolute(path)
        self.member = member
        with os.fdopen(open_safe(self.path), 'rb') as source:
            info = os.fstat(source.fileno())
            require(info.st_size < (MAX_INPUT_BYTES if byte_budget is None else byte_budget),
                    'Inputs exceed the bounded 16 GiB assembly total.')
            require(not published or info.st_size < GITHUB_LIMIT,
                    'Published DMG and ZIP must each be smaller than 2 GiB.')
            self.state = fingerprint(info)
            self.size = info.st_size
            self.sha256 = self.transfer(source)
        self.verify()

    def transfer(self, source, destination=None):
        digest = hashlib.sha256()
        remaining = self.size
        while remaining:
            data = source.read(min(BLOCK, remaining))
            require(data, 'Input truncated during assembly: ' + str(self.path))
            if destination is not None:
                destination.write(data)
            digest.update(data)
            remaining -= len(data)
        require(not source.read(1), 'Input grew during assembly: ' + str(self.path))
        require(fingerprint(os.fstat(source.fileno())) == self.state,
                'Input changed during assembly: ' + str(self.path))
        return digest.hexdigest()

    def verify(self, rehash=False):
        with os.fdopen(open_safe(self.path), 'rb') as source:
            require(fingerprint(os.fstat(source.fileno())) == self.state,
                    'Input changed during assembly: ' + str(self.path))
            if rehash:
                require(self.transfer(source) == self.sha256, 'Input hash changed during assembly.')

    def copy(self, destination):
        self.verify()
        with os.fdopen(open_safe(self.path), 'rb') as source, destination.open('xb') as target:
            require(self.transfer(source, target) == self.sha256, 'Copied input hash differs.')
        self.verify()

    def row(self):
        return dict(path=self.member, bytes=self.size, sha256=self.sha256)


def evidence_tree(root):
    """Return bounded regular files and directory identities without following links."""
    rows, directories = [], {}

    def visit(path):
        require(len(path.relative_to(root).parts) <= 64, 'Evidence paths exceed 64 directory levels.')
        descriptor = open_safe(path, directory=True)
        try:
            directories[str(path.relative_to(root))] = fingerprint(os.fstat(descriptor))
            # scandir by descriptor keeps enumeration within the verified directory.
            children = []
            with os.scandir(descriptor) as entries:
                for entry in entries:
                    require(len(rows) + len(directories) + len(children) < MAX_FILES,
                            'Too many evidence entries.')
                    children.append(entry)
            children.sort(key=lambda entry: entry.name)
            for entry in children:
                safe_component(entry.name)
                child = path / entry.name
                info = entry.stat(follow_symlinks=False)
                if stat.S_ISDIR(info.st_mode):
                    visit(child)
                else:
                    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1,
                            'Evidence must contain only directories and unlinked regular files: ' + str(child))
                    rows.append(child)
        finally:
            os.close(descriptor)

    visit(root)
    return sorted(rows), directories


class LimitedWriter:
    def __init__(self, stream):
        self.stream = stream
        self.count = 0

    def write(self, data):
        require(self.count + len(data) < GITHUB_LIMIT,
                'Materials archive reaches the GitHub 2 GiB per-file limit.')
        written = self.stream.write(data)
        self.count += written
        return written

    def flush(self):
        self.stream.flush()


def encoded_json(value):
    return (json.dumps(value, indent=2, ensure_ascii=False) + '\n').encode('utf-8')


def add_bytes(archive, name, data):
    info = tarfile.TarInfo(name)
    info.size, info.mode = len(data), 0o644
    archive.addfile(info, io.BytesIO(data))


def file_digest(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for data in iter(lambda: source.read(BLOCK), b''):
            digest.update(data)
    return dict(name=path.name, bytes=path.stat().st_size, sha256=digest.hexdigest())


def materials_readme(args):
    return f'''# Crosscript {args.version} (build {args.build}) — complete release materials / 完整发布材料

source/ retains the supplied source archive under its original filename.
third-party/ retains the supplied third-party source/build materials archive unchanged.
evidence/ retains the supplied validation records as regular files.
源码和第三方材料归档保留原文件名与原始字节；验证记录保存在 evidence/。
See manifest.json and SHA256SUMS.txt to verify these files after extraction.
解包后可使用 manifest.json 和 SHA256SUMS.txt 核对文件完整性。

This is a local packaging record. “Complete” describes this release's three supplied
material groups, not an independent audit of source completeness or license compliance.
The nested archives are retained as opaque bytes; this tool does not extract or audit them.
Ad-hoc / non-notarized preview is the declared release profile; this assembler does not
verify signatures, source-to-App provenance, DMG/ZIP contents, macOS installation,
Gatekeeper acceptance, product workflows or online services. Supplied evidence retains
its own scope and limitations. No signing, notarization or service calls are performed.
这是本地打包记录，不等于源码完备性、许可合规、真实 Mac 安装或在线服务测试结论。
请查阅各验证记录的范围及限制；本工具不执行签名、公证、安装或服务调用。
Third-party materials keep their own licenses; inclusion does not relicense them.
第三方材料继续适用各自许可证。
'''


def release_body(args, assets):
    base = f'https://github.com/{args.repo}/releases/download/{quote(args.tag, safe="")}'
    labels = ('DMG installer / DMG 安装包', 'App ZIP / App 压缩包', 'Complete materials / 完整材料')
    lines = [f'# Crosscript {args.version} · build {args.build}', '',
             'Apple Silicon · macOS 14.2+ · ad-hoc signed, non-notarized preview / 临时签名、未经公证的预览版。', '',
             'Download one App package: open the DMG and copy the App to Applications, or extract the ZIP.',
             '选择一种 App 包：打开 DMG 并将 App 拷贝到 Applications，或解压 ZIP。', '']
    for label, asset in zip(labels, assets):
        lines.append(f'- [{label}]({base}/{quote(asset["name"], safe="")}) — `{asset["name"]}`')
    lines.extend(['', 'Materials include the supplied source archive, third-party source/build materials, validation records and internal checksums. This assembler does not verify source-to-App binding; consult the supplied binding evidence.',
                  '完整材料包含提供的源码归档、第三方源码与构建材料、验证记录和内部校验清单。本组装工具不验证源码与 App 的对应关系；请查阅提供的绑定证据。', '',
                  'SHA-256 / 校验值（`shasum -a 256 <downloaded-file>`）：', '', '```text'])
    lines.extend(f'{asset["sha256"]}  {asset["name"]}' for asset in assets)
    lines.extend(['```', '', 'Checksums confirm matching bytes; they do not authenticate the publisher.',
                  '校验值用于核对文件字节，不证明发布者身份。', '',
                  'This local assembly does not perform or claim a real Mac install, Gatekeeper approval or online-service test. See the included validation records for their actual scope.',
                  '本次本地组装未执行或声称真实 Mac 安装、Gatekeeper 放行或在线服务测试；实际验证范围以材料内记录为准。', '',
                  f'[Installation and use / 安装与使用](https://github.com/{args.repo}/blob/{quote(args.tag, safe="")}/docs/getting-started.md)', ''])
    return '\n'.join(lines)


def assemble(args):
    require(re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', args.version), 'Use a numeric three-component version.')
    require(re.fullmatch(r'[1-9][0-9]{0,3}(?:\.[0-9]{1,2}){0,2}', args.build), 'Use a positive numeric build.')
    require(re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repo) and
            all(part not in ('.', '..') for part in args.repo.split('/')), 'Invalid owner/repository.')
    args.tag = args.tag or f'v{args.version}-preview.{args.build}'
    require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', args.tag) and '..' not in args.tag,
            'Use a simple release tag without path components.')
    require(args.source_commit is None or re.fullmatch(r'[0-9a-f]{40}', args.source_commit),
            'Source commit must be a full lowercase SHA.')
    output = absolute(args.output)
    require(not os.path.lexists(output), 'Output must be a new directory.')
    descriptor = open_safe(output.parent, directory=True)
    parent_identity = identity(os.fstat(descriptor))
    os.close(descriptor)
    evidence_root = absolute(args.evidence_dir)
    evidence_paths, directories = evidence_tree(evidence_root)
    require(evidence_paths, 'Evidence directory must contain at least one regular validation record.')
    name = f'Crosscript-preview-{args.version}-{args.build}'
    materials_name = f'Crosscript-materials-{args.version}-{args.build}'
    inputs = []
    remaining_bytes = MAX_INPUT_BYTES

    def select(path, member=None, published=False):
        nonlocal remaining_bytes
        item = Input(path, member, published, remaining_bytes)
        inputs.append(item)
        remaining_bytes -= item.size
        return item

    dmg, app_zip = select(args.dmg, published=True), select(args.zip, published=True)
    require(dmg.path.suffix.lower() == '.dmg' and app_zip.path.suffix.lower() == '.zip', 'Expected .dmg and .zip inputs.')
    require(dmg.size and app_zip.size, 'App package inputs must be nonempty.')
    source = select(args.source_archive, 'source/' + absolute(args.source_archive).name)
    third_party = select(args.third_party_archive, 'third-party/' + absolute(args.third_party_archive).name)
    require(source.size and third_party.size, 'Source/material archives must be nonempty.')
    materials = [source, third_party] + [select(path, 'evidence/' + path.relative_to(evidence_root).as_posix()) for path in evidence_paths]
    for path in [evidence_root, *(item.path for item in inputs)]:
        require(not output.is_relative_to(path) and not path.is_relative_to(output), 'Output must be independent of every input.')
    profile = dict(signatureKind='adhoc-declared-not-verified', notarization='not-performed',
                   cleanMacInstallation='not-run', gatekeeperAssessment='not-performed',
                   onlineServiceTests='not-run', sourceBuildBinding='not-verified-by-this-tool')
    material_manifest = dict(schema=1, version=args.version, build=args.build, sourceCommitDeclared=args.source_commit,
                             scope='Original archive bytes and supplied evidence; nested archives are not inspected.',
                             packagedAppInputs=[dict(name=name + suffix, bytes=item.size, sha256=item.sha256)
                                                for suffix, item in (('.dmg', dmg), ('.zip', app_zip))],
                             verification=profile, files=[item.row() for item in materials])
    owned_output = Output(output, parent_identity)
    try:
        dmg.copy(owned_output.file(name + '.dmg', asset=True))
        app_zip.copy(owned_output.file(name + '.zip', asset=True))
        manifest_data = encoded_json(material_manifest)
        readme_data = materials_readme(args).encode('utf-8')
        sums = ''.join(f'{item.sha256}  {item.member}\n' for item in materials)
        sums += f'{hashlib.sha256(manifest_data).hexdigest()}  manifest.json\n'
        sums += f'{hashlib.sha256(readme_data).hexdigest()}  README.md\n'
        with owned_output.file(materials_name + '.tar.gz', asset=True).open('xb') as raw:
            with gzip.GzipFile(filename='', fileobj=LimitedWriter(raw), mode='wb', mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode='w|', format=tarfile.PAX_FORMAT) as archive:
                    for item in materials:
                        item.verify()
                        with os.fdopen(open_safe(item.path), 'rb') as stream:
                            info = tarfile.TarInfo(materials_name + '/' + item.member)
                            info.size, info.mode = item.size, 0o644
                            archive.addfile(info, stream)
                        item.verify(rehash=True)
                    add_bytes(archive, materials_name + '/manifest.json', manifest_data)
                    add_bytes(archive, materials_name + '/README.md', readme_data)
                    add_bytes(archive, materials_name + '/SHA256SUMS.txt', sums.encode('utf-8'))
        for item in inputs:
            item.verify(rehash=True)
        require(evidence_tree(evidence_root) == (evidence_paths, directories), 'Evidence tree changed during assembly.')
        assets = [file_digest(owned_output.file(filename, asset=True)) for filename in
                  (name + '.dmg', name + '.zip', materials_name + '.tar.gz')]
        for asset, item in zip(assets, (dmg, app_zip)):
            require(asset['bytes'] == item.size and asset['sha256'] == item.sha256,
                    'Published App package differs from its selected input: ' + asset['name'])
        require(all(asset['bytes'] < GITHUB_LIMIT for asset in assets), 'Published asset reaches 2 GiB.')
        report = dict(schema=1, status='assembled-locally', version=args.version, build=args.build,
                      repository=args.repo, tag=args.tag, manualUploadAssetCount=3,
                      sourceCommitDeclared=args.source_commit, verification=profile,
                      inputsUnchanged=True, assets=assets,
                      inputFiles=[dict(role=role, originalName=item.path.name, bytes=item.size, sha256=item.sha256)
                                  for role, item in [('dmg', dmg), ('zip', app_zip), ('source', source), ('third-party', third_party)]],
                      uploadInstructions='Upload only the three files in assets/; paste RELEASE.md as the Release body. No upload performed.')
        owned_output.file('release-manifest.json').write_bytes(encoded_json(report))
        owned_output.file('SHA256SUMS.txt').write_text(''.join(f'{a["sha256"]}  {a["name"]}\n' for a in assets))
        owned_output.file('RELEASE.md').write_text(release_body(args, assets))
        owned_output.verify()
        return report
    except BaseException:
        owned_output.remove()
        raise
    finally:
        owned_output.close()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('dmg', 'zip', 'source-archive', 'third-party-archive', 'evidence-dir', 'version', 'build', 'output'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--repo', default='yqia03/crosscript')
    parser.add_argument('--tag', help='Defaults to vVERSION-preview.BUILD.')
    parser.add_argument('--source-commit', help='Optional declared SHA; not a provenance attestation.')
    args = parser.parse_args(argv)
    try:
        report = assemble(args)
    except (AssemblyError, OSError, ValueError, tarfile.TarError) as error:
        print(json.dumps(dict(status='failed', error=str(error)), ensure_ascii=False))
        return 1
    print(json.dumps(report, indent=2, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    sys.exit(main())
