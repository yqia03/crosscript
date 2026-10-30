"""Offline health verification and installed-file integrity inventory. No service calls."""
import hashlib
import importlib.metadata
import json
import pathlib
import os
import platform
import sys

IDENTIFIER = 'babeldoc-0.6.4-py312-20261029-arm64-crosscript-v3'
mode, root = sys.argv[1], pathlib.Path(sys.argv[2]).resolve()
os.environ['HOME'] = str(root / 'Home')
if mode == 'health':
    assert sys.version_info[:3] == (3, 12, 15)
    assert platform.machine() == 'arm64'
    assert pathlib.Path(sys.executable).resolve().is_relative_to(root)
    assert importlib.metadata.version('babeldoc') == '0.6.4'
    import babeldoc.const as const
    const.CACHE_FOLDER = root / 'assets'
    const.TIKTOKEN_CACHE_FOLDER = const.CACHE_FOLDER / 'tiktoken'
    os.environ['TIKTOKEN_CACHE_DIR'] = str(const.TIKTOKEN_CACHE_FOLDER)
    import babeldoc.format.pdf.high_level
    import pymupdf
    import onnxruntime
    model = root / 'assets/models/doclayout_yolo_docstructbench_imgsz1024.onnx'
    session = onnxruntime.InferenceSession(str(model), providers=['CPUExecutionProvider'])
    assert session.get_inputs() and session.get_outputs()
    print('verified Python 3.12.15, BabelDOC 0.6.4, PyMuPDF and real ONNX session')
elif mode == 'record':
    files, links = {}, {}
    for path in sorted(root.rglob('*')):
        if '__pycache__' in path.parts or path.name.startswith('cache.v1.db') or path.relative_to(root).parts[0] not in ('python', 'assets'):
            continue
        name = str(path.relative_to(root))
        if path.is_symlink():
            assert path.resolve().is_relative_to(root), name
            links[name] = str(path.readlink())
        elif path.is_file():
            with path.open('rb') as stream:
                files[name] = hashlib.file_digest(stream, 'sha256').hexdigest()
    (root / 'installed-files.json').write_text(json.dumps(dict(identifier=IDENTIFIER, files=files, links=links), sort_keys=True))
    print(f'verified inventory: {len(files)} files, {len(links)} internal links')
else:
    raise ValueError('unknown operation')
