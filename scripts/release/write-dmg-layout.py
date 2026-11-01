#!/usr/bin/env python3
"""Create/verify Finder metadata on an image without launching a GUI process."""
import argparse
import ctypes
import hashlib
import json
import os
import pathlib
import re
import sys

# These pinned MIT build tools are deliberately independent of site-packages.
sys.dont_write_bytecode = True
sys.path.insert(0, str(pathlib.Path(__file__).with_name('vendor')))
from ds_store import DSStore
from mac_alias import Alias

BACKGROUND = '.background/installer.tiff'
VOLUME_NAME = 'Crosscript Preview'


def require(value, message):
    if not value:
        raise ValueError(message)


def settings(root, app_name):
    require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*\.app', app_name), 'Unsafe App name.')
    require(root.is_dir() and not root.is_symlink(), 'Expected image directory.')
    require((root / app_name).is_dir() and not (root / app_name).is_symlink(), 'Missing real App.')
    background = root / BACKGROUND
    require(background.is_file() and not background.is_symlink() and background.stat().st_size,
            'Missing regular image background.')
    value = json.loads((root / '.release-info/finder-layout.json').read_text())
    require(value['schema'] == 1 and value['defaultView'] == 'icon', 'Unsupported Finder layout settings.')
    return value


def expected_records(value):
    x, y, width, height = value['windowBoundsPoints']
    window = dict(ShowStatusBar=False, WindowBounds=f'{{{{{x}, {y}}}, {{{width}, {height}}}}}',
                  ContainerShowSidebar=False, PreviewPaneVisibility=False,
                  SidebarWidth=0, ShowTabView=False, ShowToolbar=False,
                  ShowPathbar=False, ShowSidebar=False)
    icons = dict(viewOptionsVersion=1, backgroundType=2,
                 backgroundColorRed=1.0, backgroundColorGreen=1.0, backgroundColorBlue=1.0,
                 gridOffsetX=0.0, gridOffsetY=0.0, gridSpacing=80.0, arrangeBy='none',
                 showIconPreview=True, showItemInfo=False, labelOnBottom=True,
                 textSize=float(value['textSizePoints']), iconSize=float(value['iconSizePoints']),
                 scrollPositionX=0.0, scrollPositionY=0.0)
    return window, icons



def native_alias_target(alias_data, root):
    """Resolve with macOS itself, with UI and mounting explicitly disabled.

    Parsing our own record is insufficient: on macOS 26 an alias without the
    volume POSIX-path field parsed correctly yet resolved to its parent folder.
    """
    require(sys.platform == 'darwin', 'Native alias validation requires macOS.')
    cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    ptr, index, flag = ctypes.c_void_p, ctypes.c_long, ctypes.c_ubyte
    signatures = {
        'CFDataCreate': ([ptr, ctypes.c_char_p, index], ptr),
        'CFURLCreateBookmarkDataFromAliasRecord': ([ptr, ptr], ptr),
        'CFURLCreateFromFileSystemRepresentation': ([ptr, ctypes.c_char_p, index, flag], ptr),
        'CFURLCreateByResolvingBookmarkData':
            ([ptr, ptr, ctypes.c_ulong, ptr, ptr, ctypes.POINTER(flag), ctypes.POINTER(ptr)], ptr),
        'CFURLGetFileSystemRepresentation': ([ptr, flag, ptr, index], flag),
        'CFRelease': ([ptr], None),
    }
    for name, (arguments, result) in signatures.items():
        function = getattr(cf, name)
        function.argtypes, function.restype = arguments, result
    owned = []
    error = ptr()
    try:
        data = cf.CFDataCreate(None, alias_data, len(alias_data))
        require(data, 'Could not create native alias data.')
        owned.append(data)
        bookmark = cf.CFURLCreateBookmarkDataFromAliasRecord(None, data)
        require(bookmark, 'macOS could not interpret background alias.')
        owned.append(bookmark)
        root_bytes = os.fsencode(root)
        relative_to = cf.CFURLCreateFromFileSystemRepresentation(None, root_bytes, len(root_bytes), True)
        require(relative_to, 'Could not create image URL.')
        owned.append(relative_to)
        stale = flag()
        # kCFURLBookmarkResolutionWithoutUIMask | WithoutMountingMask.
        resolved = cf.CFURLCreateByResolvingBookmarkData(
            None, bookmark, (1 << 8) | (1 << 9), relative_to, None, ctypes.byref(stale), ctypes.byref(error))
        require(resolved, 'macOS could not resolve background alias without UI or mounting.')
        owned.append(resolved)
        path = ctypes.create_string_buffer(32768)
        require(cf.CFURLGetFileSystemRepresentation(resolved, True, path, len(path)),
                'Could not read resolved background path.')
        return pathlib.Path(os.fsdecode(path.value))
    finally:
        if error.value:
            cf.CFRelease(error.value)
        for value in reversed(owned):
            cf.CFRelease(value)


def verify(root, app_name):
    value = settings(root, app_name)
    layout = root / '.DS_Store'
    require(layout.is_file() and not layout.is_symlink() and layout.stat().st_size,
            'Missing regular root .DS_Store.')
    window, icons = expected_records(value)
    with DSStore.open(str(layout), 'r') as store:
        require(store['.']['bwsp'] == window, 'Finder window settings differ.')
        actual_icons = dict(store['.']['icvp'])
        alias_data = actual_icons.pop('backgroundImageAlias')
        require(actual_icons == icons, 'Finder icon view settings differ.')
        require(store['.']['icvl'] == (b'type', b'icnv') and
                store['.']['vstl'] == (b'type', b'icnv'), 'Finder does not default to icon view.')
        require(store[app_name]['Iloc'] == tuple(value['appPosition']), 'App icon position differs.')
        require(store['Applications']['Iloc'] == tuple(value['applicationsPosition']), 'Applications icon position differs.')
        expected_keys = {('.', code) for code in (b'bwsp', b'icvp', b'icvl', b'vstl', b'vSrn')}
        expected_keys.update({(app_name, b'Iloc'), ('Applications', b'Iloc')})
        require({(entry.filename, entry.code) for entry in store} == expected_keys,
                'Unexpected Finder metadata entry.')
    alias = Alias.from_bytes(alias_data)
    require(alias.volume.name == VOLUME_NAME, 'Background alias names the wrong volume.')
    require(alias.volume.fs_type == b'H+', 'Background alias is not for the HFS+ image.')
    require(alias.target.posix_path == '/' + BACKGROUND, 'Background alias is not relative to the image volume.')
    require(alias.target.filename == 'installer.tiff', 'Background alias names the wrong file.')
    require(alias.target.cnid == (root / BACKGROUND).stat().st_ino and
            alias.target.folder_cnid == (root / '.background').stat().st_ino,
            'Background alias does not identify this image file and parent.')
    require(alias.volume.posix_path == '/Volumes/' + VOLUME_NAME and not alias.volume.disk_image_alias,
            'Background alias has no canonical portable volume mount reference.')
    resolved = native_alias_target(alias_data, root)
    require(resolved == (root / BACKGROUND).resolve() and resolved.is_file(),
            'macOS background alias does not resolve to the image background file.')
    return dict(status='verified', implementation='vendored-ds_store-mac_alias',
                volumeName=alias.volume.name, backgroundRelativePath=alias.target.posix_path,
                backgroundCNID=alias.target.cnid, backgroundParentCNID=alias.target.folder_cnid,
                hostMountReferenceIncluded=False, canonicalVolumeMountPath=alias.volume.posix_path,
                nativeAliasResolution='passed', nativeResolvedPath=str(resolved),
                layoutSHA256=hashlib.sha256(layout.read_bytes()).hexdigest())


def create(root, app_name):
    value = settings(root, app_name)
    require(os.path.ismount(root), 'Generate layout only on a mounted image, never a source directory.')
    layout = root / '.DS_Store'
    require(not layout.exists() and not layout.is_symlink(), 'Refusing to overwrite existing Finder metadata.')
    # Use actual volume creation time, HFS CNIDs, names and paths from the image.
    # A canonical /Volumes/<name> field is required by modern native alias
    # resolution. It is independent of the temporary build mount path; actual
    # volume identity + volume-relative path/CNIDs resolve other mount locations.
    alias = Alias.for_file(str(root / BACKGROUND))
    require(alias.volume.name in (VOLUME_NAME, VOLUME_NAME.encode()) and alias.volume.fs_type == b'H+', 'Unexpected image volume.')
    alias.volume.posix_path = '/Volumes/' + VOLUME_NAME
    window, icons = expected_records(value)
    icons['backgroundImageAlias'] = alias.to_bytes()
    with DSStore.open(str(layout), 'w+') as store:
        store['.']['vSrn'] = ('long', 1)
        store['.']['bwsp'] = window
        store['.']['icvp'] = icons
        store['.']['icvl'] = ('type', b'icnv')
        store['.']['vstl'] = ('type', b'icnv')
        store[app_name]['Iloc'] = tuple(value['appPosition'])
        store['Applications']['Iloc'] = tuple(value['applicationsPosition'])
    with layout.open('r+b') as stream:
        os.fsync(stream.fileno())
    return verify(root, app_name)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('create', 'verify'))
    parser.add_argument('mountpoint')
    parser.add_argument('app_name')
    args = parser.parse_args(argv)
    try:
        root = pathlib.Path(args.mountpoint).absolute()
        result = create(root, args.app_name) if args.action == 'create' else verify(root, args.app_name)
    except Exception as error:
        print(json.dumps(dict(status='failed', error=str(error))))
        return 1
    print(json.dumps(result))
    return 0


if __name__ == '__main__':
    sys.exit(main())
