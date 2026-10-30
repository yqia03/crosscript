#!/usr/bin/env python3
"""Regenerate the fixed runtime lock using the V4 verified asset cache. Developer tooling only."""
import sys,json,urllib.request,hashlib,concurrent.futures,argparse
from pathlib import Path
from packaging.tags import cpython_tags,compatible_tags,mac_platforms
from packaging.utils import parse_wheel_filename
root=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--assets-directory',type=Path,required=True,help='Pre-acquired asset tree; files must match the pinned SHA3-256 values.')
parser.add_argument('--asset-manifest',type=Path,default=Path(__file__).with_name('pins')/'assets-manifest.json')
parser.add_argument('--output',type=Path,required=True,help='New manifest path; compare before adopting. This command queries public PyPI metadata.')
args=parser.parse_args()
if args.output.exists():parser.error('Output already exists; choose a fresh path.')
platforms=list(mac_platforms((14,2),'arm64'))
tags=list(cpython_tags((3,12),platforms=platforms))+list(compatible_tags((3,12),interpreter='cp312',platforms=platforms))
rank={t:i for i,t in enumerate(tags)}
def get(u):return json.load(urllib.request.urlopen(u,timeout=45))
def wheel(line):
 name,version=line.split('=='); data=get(f'https://pypi.org/pypi/{name}/{version}/json'); options=[]
 for a in data['urls']:
  if not a['filename'].endswith('.whl'):continue
  _,_,_,ts=parse_wheel_filename(a['filename']); good=set(ts)&rank.keys()
  if good: options.append((min(rank[t] for t in good),a))
 if not options:raise Exception('No compatible wheel '+line)
 a=min(options,key=lambda x:x[0])[1]
 return dict(name=name,version=version,filename=a['filename'],url=a['url'],sha256=a['digests']['sha256'],bytes=a['size'],license=data['info'].get('license_expression') or data['info'].get('license') or 'See bundled wheel metadata')
lines=[l for l in (root/'scripts/pdf/runtime-requirements.txt').read_text().splitlines() if l and not l.startswith('reportlab==')]
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as e: wheels=list(e.map(wheel,lines))
# Keep official asset URL origin and content pin, regardless of mutable source branch.
assets=[]
for kind,items in json.loads(args.asset_manifest.read_text()).items():
 for item in items:
  p=args.assets_directory/kind/item['name']; data=p.read_bytes()
  assert hashlib.sha3_256(data).hexdigest()==item['sha3_256']
  if kind in ['fonts','cmap']:url='https://raw.githubusercontent.com/funstory-ai/BabelDOC-Assets/refs/heads/main/'+kind+'/'+item['name']
  elif kind=='models':url='https://huggingface.co/wybxc/DocLayout-YOLO-DocStructBench-onnx/resolve/main/'+item['name']+'?download=true'
  elif kind=='tiktoken':url='https://openaipublic.blob.core.windows.net/encodings/o200k_base.tiktoken'
  else:raise Exception(kind)
  assets.append(dict(path=kind+'/'+item['name'],url=url,sha256=hashlib.sha256(data).hexdigest(),bytes=len(data)))
manifest=dict(schema=1,id='babeldoc-0.6.4-py312-20261013-arm64-v1',engineVersion='0.6.4',pythonVersion='3.12.15',python=dict(filename='cpython-3.12.15+20261013-aarch64-apple-darwin-install_only.tar.gz',url='https://github.com/astral-sh/python-build-standalone/releases/download/20261013/cpython-3.12.15%2B20261013-aarch64-apple-darwin-install_only.tar.gz',sha256='ba32036ad8f4c434d97a1ee7feef8b7edc0fac16777639b97e39c74a108e4440',bytes=25180390),wheels=wheels,assets=assets)
args.output.write_text(json.dumps(manifest,indent=2)+'\n')
print(len(wheels),'wheels',len(assets),'assets',sum(x['bytes'] for x in wheels+assets)+25180390,'bytes')
