#!/usr/bin/env python3
"""Build an isolated local candidate from a clean committed snapshot, without network."""
import argparse,datetime,gzip,hashlib,json,os,pathlib,plistlib,subprocess,tarfile

BASE_ENV={k:os.environ[k] for k in ('HOME','TMPDIR') if k in os.environ}
BASE_ENV.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin',LC_ALL='C')
def require(value, message):
 if not value: raise RuntimeError(message)
def sha(p):
 with p.open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()
def command(cmd,cwd,env=None):
 return subprocess.check_output(cmd,cwd=cwd,env=BASE_ENV if env is None else env,text=True,stderr=subprocess.STDOUT).strip()
def write(p,obj): p.write_text(json.dumps(obj,ensure_ascii=False,indent=2)+'\n')
p=argparse.ArgumentParser(); p.add_argument('--source',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True); a=p.parse_args();r=a.source.resolve();out=a.output.resolve()
require(not out.exists(), 'Output must be new'); require(not out.is_relative_to(r), 'Output must be outside source');out.mkdir(parents=True)
require(command(['/usr/bin/git','status','--porcelain','--untracked-files=all'],r)=='','Source must be clean')
revision=command(['/usr/bin/git','rev-parse','HEAD'],r)
files=command(['/usr/bin/git','ls-files'],r).splitlines()
require(files and all(not (r/f).is_symlink() for f in files), 'Source files required; symlinks unsupported')
before={f:{'sha256':sha(r/f),'bytes':(r/f).stat().st_size,'mode':oct((r/f).stat().st_mode&0o777)} for f in files}
info=plistlib.loads((r/'app/macos/Resources/Info.plist').read_bytes());version=info['CFBundleShortVersionString'];build=info['CFBundleVersion'];name=f'Crosscript-source-{version}-{build}'
archive=out/(name+'.tar.gz')
with archive.open('xb') as raw,gzip.GzipFile(filename='',mode='wb',fileobj=raw,mtime=0) as gz,tarfile.open(fileobj=gz,mode='w') as tar:
 for rel in sorted(files):
  path=r/rel; entry=tar.gettarinfo(str(path),arcname=name+'/'+rel);entry.uid=entry.gid=0;entry.uname=entry.gname='';entry.mtime=0;entry.pax_headers={}
  with path.open('rb') as stream: tar.addfile(entry,stream)
write(out/'SOURCE-FILES.json',before)
policy=out/'deny-network.sb';policy.write_text('(version 1)\n(allow default)\n(deny network*)\n')
work=out/'build';work.mkdir();app=work/'TranslationWorkbench.app';scratch=work/'swift-build'
env=BASE_ENV.copy(); env['SDKROOT']=command(['/usr/bin/xcrun','--sdk','macosx','--show-sdk-path'],r,env);env.update(WORKBENCH_SIGNING_IDENTITY='-',WORKBENCH_SIGNING_KEYCHAIN='',WORKBENCH_APP_BUNDLE=str(app),WORKBENCH_SWIFT_SCRATCH_PATH=str(scratch),WORKBENCH_OUTER_NETWORK_SANDBOX='1',WORKBENCH_SOURCE_REVISION=revision,WORKBENCH_SOURCE_ARCHIVE_SHA256=sha(archive),CLANG_MODULE_CACHE_PATH=str(work/'clang-module-cache'),SWIFTPM_MODULECACHE_OVERRIDE=str(work/'swift-module-cache'))
# No credential/service environment is recorded. The whole build process tree denies network.
record={'schema':1,'buildDriverSHA256':sha(pathlib.Path(__file__)),'candidate':f'{version}-{build}','startedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'sourceRevision':revision,'sourceArchive':archive.name,'sourceArchiveSHA256':sha(archive),'sourceManifestSHA256':sha(out/'SOURCE-FILES.json'),'sourceWasClean':True,'freshSwiftBuildDirectory':not scratch.exists(),'sourceRoot':str(r),'toolchain':{key:command(cmd,r,env) for key,cmd in {'swift':['/usr/bin/swift','--version'],'swiftPath':['/usr/bin/xcrun','--find','swift'],'sdkPath':['/usr/bin/xcrun','--sdk','macosx','--show-sdk-path'],'sdkVersion':['/usr/bin/xcrun','--sdk','macosx','--show-sdk-version'],'osVersion':['/usr/bin/sw_vers','-productVersion'],'osBuild':['/usr/bin/sw_vers','-buildVersion'],'architecture':['/usr/bin/uname','-m']}.items()},'environmentPolicy':'Allow only existing HOME and TMPDIR, fixed system PATH and C locale, explicit SDKROOT, task build controls and caches. CPATH, LIBRARY_PATH, BASH_ENV, ENV, Swift/toolchain overrides and service credentials are not inherited.','recordedEnvironment':{k:env[k] for k in ['PATH','LC_ALL','SDKROOT','WORKBENCH_SIGNING_IDENTITY','WORKBENCH_SIGNING_KEYCHAIN','WORKBENCH_APP_BUNDLE','WORKBENCH_SWIFT_SCRATCH_PATH','WORKBENCH_OUTER_NETWORK_SANDBOX','WORKBENCH_SOURCE_REVISION','WORKBENCH_SOURCE_ARCHIVE_SHA256','CLANG_MODULE_CACHE_PATH','SWIFTPM_MODULECACHE_OVERRIDE']},'readyForPublication':False,'appBuildProvenanceVerified':False,'thirdPartyCompliance':'pending-component-gates','secondMacInstallation':'not-run','publication':'not-authorized'}
cmd=['/usr/bin/sandbox-exec','-f',str(policy),'/bin/bash','app/macos/scripts/build-app.sh','release'];record['command']=cmd;write(out/'build-binding.json',record)
with (out/'build.log').open('x') as log:
 run=subprocess.run(cmd,cwd=r,env=env,stdout=log,stderr=subprocess.STDOUT)
record['exitCode']=run.returncode;record['finishedAt']=datetime.datetime.now(datetime.timezone.utc).isoformat();record['sourceFilesUnchanged']=all((r/f).is_file() and sha(r/f)==v['sha256'] and oct((r/f).stat().st_mode&0o777)==v['mode'] for f,v in before.items());record['sourceRemainsClean']=command(['/usr/bin/git','status','--porcelain','--untracked-files=all'],r)=='';record['buildLogSHA256']=sha(out/'build.log')
if run.returncode==0:
 appinfo=plistlib.loads((app/'Contents/Info.plist').read_bytes());record['embeddedSourceRevision']=appinfo.get('CrosscriptSourceRevision');record['embeddedSourceArchiveSHA256']=appinfo.get('CrosscriptSourceArchiveSHA256');record['executableSHA256']=sha(app/'Contents/MacOS/TranslationWorkbench');record['appBuildProvenanceVerified']=record['sourceFilesUnchanged'] and record['sourceRemainsClean'] and appinfo.get('CrosscriptSourceRevision')==revision and appinfo.get('CrosscriptSourceArchiveSHA256')==sha(archive)
write(out/'build-binding.json',record);print(json.dumps({'exitCode':run.returncode,'appBuildProvenanceVerified':record['appBuildProvenanceVerified'],'sourceRevision':revision,'output':str(out)}));raise SystemExit(run.returncode)
