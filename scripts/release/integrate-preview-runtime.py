#!/usr/bin/env python3
"""Bind approved local rebuilt wheels and identity-renamed fonts to the preview.

The immutable upstream manifest remains an origin input. This script emits the
current manifest and copies exact verified payloads into signed App resources.
It never downloads, installs or launches the application.
"""
import argparse, hashlib, json, pathlib, shutil

RUNTIME_ID = 'babeldoc-0.6.4-py312-20261029-arm64-crosscript-v3'

def sha(path):
    with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()

def require(condition, message):
    if not condition:raise ValueError(message)

def regular_file(path):
    require(not path.is_symlink() and path.is_file(), 'Expected a non-symlink regular file: '+str(path))

def flat_filename(value):
    allowed='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-'
    return isinstance(value,str) and bool(value) and not value.startswith('.') and all(c in allowed for c in value)

def verify_bundle(bundle, expected, complete=False):
    require(not bundle.is_symlink() and bundle.is_dir(), 'Expected a non-symlink Bundled directory')
    actual=set()
    for path in bundle.iterdir():
        regular_file(path)
        require(path.name in expected, 'Unexpected bundled payload: '+path.name)
        actual.add(path.name)
    if complete:require(actual==expected, 'Missing bundled payload')

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--source',type=pathlib.Path,required=True)
    parser.add_argument('--upstream-manifest',type=pathlib.Path,required=True)
    parser.add_argument('--font-manifest',type=pathlib.Path,required=True)
    parser.add_argument('--font-directory',type=pathlib.Path,required=True)
    parser.add_argument('--babeldoc-wheel',type=pathlib.Path,required=True)
    parser.add_argument('--opencv-wheel',type=pathlib.Path,required=True)
    args=parser.parse_args()
    resources=args.source/'app/macos/Sources/TranslationWorkbench/Resources/PDF'
    bundle=resources/'Bundled'
    for path in [args.upstream_manifest,args.font_manifest]:regular_file(path)
    manifest=json.loads(args.upstream_manifest.read_text());manifest['id']=RUNTIME_ID
    fonts=json.loads(args.font_manifest.read_text())['fonts'];require(len(fonts)==20, 'Expected exactly 20 renamed fonts')
    for font in fonts:require(flat_filename(font['filename']), 'Invalid bundled font filename')
    expected={args.babeldoc_wheel.name,args.opencv_wheel.name}|{font['filename'] for font in fonts}
    require(len(expected)==22 and all(flat_filename(name) for name in expected), 'Bundled filenames must be distinct flat names')
    require(not bundle.is_symlink(), 'Bundled must not be a symlink')
    bundle.mkdir(exist_ok=True)
    verify_bundle(bundle,expected)
    records=[]
    def deliver(path, expected=None):
        regular_file(path)
        digest=sha(path)
        size=path.stat().st_size
        if expected:require(digest==expected,'Input hash differs: '+path.name)
        destination=bundle/path.name
        require(not destination.is_symlink(), 'Bundled target must not be a symlink: '+path.name)
        if destination.exists():
            regular_file(destination)
            require(sha(destination)==digest,'Refusing to replace different bundled bytes')
        else:shutil.copyfile(path,destination)
        regular_file(destination)
        require(sha(destination)==digest and destination.stat().st_size==size, 'Copied bundled bytes differ: '+path.name)
        record={'filename':path.name,'sha256':digest,'bytes':size,'url':'bundle://pdf/Bundled/'+path.name}
        records.append(record);return record
    for name,path in [('babeldoc',args.babeldoc_wheel),('opencv-python-headless',args.opencv_wheel)]:
        item=next(x for x in manifest['wheels'] if x['name']==name)
        parts=path.name.split('-')
        require(path.name.endswith('.whl') and len(parts)>1 and parts[1]==item['version'], 'Wheel filename/version mismatch: '+path.name)
        origin={key:item[key] for key in ['filename','url','sha256','bytes']}
        item.update(deliver(path));item['originArtifact']=origin
        item['modification']='Identity-renamed font registry and local failure handling' if name=='babeldoc' else 'Controlled same-version GMP, ZeroMQ and OpenSSL rebuilds only'
    for font in fonts:
        old='fonts/'+font['originalFilename']
        item=next(x for x in manifest['assets'] if x['path']==old)
        require(item['sha256']==font['originalSHA256'], 'Original font hash differs: '+font['originalFilename'])
        origin={key:item[key] for key in ['path','url','sha256','bytes']}
        payload=deliver(args.font_directory/font['filename'],font['sha256'])
        item.update({key:payload[key] for key in ['url','sha256','bytes']})
        item['path']='fonts/'+font['filename'];item['originArtifact']=origin
        item['modification']='Only font name IDs 1/3/4/6 and required checksum adjustment; glyphs and metrics retained'
    require(expected=={x['filename'] for x in records}, 'Bundled delivery records differ')
    verify_bundle(bundle,expected,complete=True)
    for record in records:
        destination=bundle/record['filename']
        regular_file(destination)
        require(sha(destination)==record['sha256'] and destination.stat().st_size==record['bytes'], 'Final bundled bytes differ: '+record['filename'])
    (resources/'runtime-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    record={'schema':'crosscript-bundled-runtime-v1','runtimeID':RUNTIME_ID,'originManifestSHA256':sha(args.upstream_manifest),'manifestSHA256':sha(resources/'runtime-manifest.json'),'bundledArtifacts':records,'artifactCount':len(manifest['wheels'])+len(manifest['assets'])+1,'networkArtifactCount':sum(x['url'].startswith('https:') for x in [manifest['python']]+manifest['wheels']+manifest['assets'])}
    (resources/'bundled-runtime-index.json').write_text(json.dumps(record,indent=2)+'\n')
    print(json.dumps({'bundledArtifacts':len(records),'runtimeID':RUNTIME_ID,'manifestSHA256':record['manifestSHA256']}))

if __name__=='__main__':main()
