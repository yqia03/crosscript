#!/usr/bin/env python3
"""Run every Swift Testing function at one fixed source, isolating AppKit UI cases."""
import argparse, collections, datetime, hashlib, json, os, pathlib, re, signal, subprocess, time

parser = argparse.ArgumentParser()
parser.add_argument('--source', required=True)
parser.add_argument('--output', type=pathlib.Path, required=True)
parser.add_argument('--runtime', type=pathlib.Path, required=True)
parser.add_argument('--scratch-path', type=pathlib.Path, help='Dedicated SwiftPM build directory; defaults to OUTPUT/swift-build.')
args = parser.parse_args()
work = pathlib.Path(__file__).resolve().parents[2]
out = args.output.resolve()
assert not out.exists(), 'Keep previous regression evidence; choose a new output directory.'
out.mkdir(parents=True)
scratch = (args.scratch_path or out / 'swift-build').resolve()
policy = out / 'deny-network.sb'
policy.write_text('(version 1)\n(allow default)\n(deny network*)\n')
env = os.environ.copy()
env['WORKBENCH_PDF_RUNTIME'] = str(args.runtime.resolve())
env['CLANG_MODULE_CACHE_PATH'] = str(scratch / 'module-cache')
env['SWIFTPM_MODULECACHE_OVERRIDE'] = str(scratch / 'module-cache')
ui_suites = {'BilingualPendingEditingTests', 'BilingualViewTests', 'PDFReadingTests', 'TranscriptEditorTests', 'MenuCommandBarrierTests', 'LiveTranscriptReaderTests'}
# AppKit's shared application/window state requires a fresh process. Discover
# new native UI suites as well as the established list so a new workspace test
# cannot silently fall into the combined Native group.
ui_markers = re.compile(r'\b(?:NSHostingView|NSWindow|NSTextView|NSItemProvider|PDFReadingController|LiveReaderScrollView)\b|NSApplication\.shared|NSApp\.')
ui_sources = {}
for path in sorted((work / 'app/macos/Tests/NativeAudioTests').glob('*.swift')):
    content = path.read_text()
    if ui_markers.search(content):
        names = re.findall(r'\b(?:struct|class)\s+(\w+)', content)
        ui_suites.update(names)
        ui_sources[str(path.relative_to(work))] = names
(out / 'ui-isolation-discovery.json').write_text(json.dumps(dict(suites=sorted(ui_suites), sources=ui_sources), indent=2)+'\n')
results = []
source_manifest = None

def swift_test(*arguments):
    # SwiftPM's inner sandbox cannot nest inside our stronger process-tree
    # network boundary. Disable only that inner sandbox, retaining OS deny-all
    # network for compiler, test runner, and local engine descendants.
    return ['/usr/bin/sandbox-exec', '-f', str(policy), 'bash', 'app/macos/scripts/test.sh',
            '--disable-sandbox', '--scratch-path', str(scratch), *arguments]

def check_source():
    global source_manifest
    assert subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=work, text=True).strip() == args.source
    status = subprocess.check_output(['git', 'status', '--porcelain=v1', '--untracked-files=all', '--', 'app'], cwd=work, text=True)
    assert not status.strip(), 'Product/test source is modified, staged, or untracked during validation: ' + status
    files = subprocess.check_output(['git', 'ls-files', '-z', '--', 'app'], cwd=work).split(b'\0')
    manifest = {os.fsdecode(name): hashlib.sha256((work / os.fsdecode(name)).read_bytes()).hexdigest() for name in files if name}
    if source_manifest is None:
        source_manifest = manifest
        (out / 'source-manifest.json').write_text(json.dumps(dict(source=args.source, files=manifest,
            driverSHA256=hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest()), indent=2)+'\n')
    else:
        assert manifest == source_manifest, 'Product/test source contents changed during validation'

def save_results():
    (out / 'summary.json').write_text(json.dumps(dict(source=args.source, runtime=env['WORKBENCH_PDF_RUNTIME'], results=results), indent=2)+'\n')

def reconcile_functions(record, inventory):
    # Human-readable Swift Testing output omits the suite prefix. Compare the
    # complete function signatures as a multiset within each filtered group,
    # including argument labels and duplicate names from different suites.
    expected = collections.Counter(identifier.split('/', 1)[1] for identifier in inventory)
    actual = collections.Counter(re.sub(r' with \d+ test cases?$', '', name) for name in record['functions'])
    record['inventoryMatchesPassedFunctions'] = actual == expected
    record['missingFunctions'] = list((expected - actual).elements())
    record['unexpectedFunctions'] = list((actual - expected).elements())
    record['passed'] = record['passed'] and record['inventoryMatchesPassedFunctions']
    save_results()
    assert record['inventoryMatchesPassedFunctions'], 'Passed function signatures do not match inventory: ' + record['log']

def run(name, config, command, expected=None):
    check_source()
    log = out / (config + '-' + name + '.log')
    started = time.monotonic()
    run_env = env.copy()
    for key, folder in [('WORKBENCH_BILINGUAL_RENDER_OUTPUT', 'bilingual'),
                        ('WORKBENCH_GEMINI_RENDER_OUTPUT', 'gemini'),
                        ('WORKBENCH_BILINGUAL_REPAIR_RENDER_OUTPUT', 'repair')]:
        run_env[key] = str(out / 'renders' / config / folder)
    with log.open('w') as stream:
        stream.write('SOURCE ' + args.source + '\nCOMMAND ' + repr(command) + '\n')
        stream.write('WORKBENCH_PDF_RUNTIME ' + env['WORKBENCH_PDF_RUNTIME'] + '\n')
        stream.flush()
        child = subprocess.Popen(command, cwd=work, env=run_env, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        print('START', config, name, 'pid', child.pid, flush=True)
        try:
            code = child.wait(timeout=900)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGTERM)
            try: child.wait(timeout=8)
            except subprocess.TimeoutExpired: os.killpg(child.pid, signal.SIGKILL); child.wait()
            code = 124
    check_source()
    data = log.read_bytes(); content = data.decode(errors='replace')
    functions = re.findall(r'^✔ Test (?!run )(.+?) passed after', content, re.M)
    summaries = re.findall(r'^✔ Test run .+$', content, re.M)
    cases = sum(int(m.group(1)) for f in functions if (m := re.search(r' with (\d+) test cases?', f)))
    param_functions = sum(bool(re.search(r' with \d+ test cases?', f)) for f in functions)
    passed = code == 0 and not re.search(r'^✘', content, re.M) and bool(summaries) and (expected is None or len(functions) == len(expected))
    if name == 'native':
        passed = passed and '✔ Test pythonImportsLeaveBridgeResourcesUnchanged() passed after' in content
    record = dict(source=args.source, name=name, configuration=config, command=command, exit=code, passed=passed,
                  seconds=time.monotonic()-started, functions=functions, uniqueFunctions=len(functions), invocations=len(functions)-param_functions+cases,
                  summaries=summaries, log=log.name, sha256=hashlib.sha256(data).hexdigest())
    results.append(record)
    save_results()
    if expected is not None:
        reconcile_functions(record, expected)
    print('DONE', config, name, 'PASS' if passed else 'FAIL', len(functions), summaries, flush=True)
    assert passed, 'Failed group: ' + str(log)

for config in ['debug', 'release']:
    run('core', config, swift_test('-c',config,'--jobs','2','--no-parallel','--filter','WorkbenchCoreTests'))
    listing = subprocess.check_output(swift_test('list','-c',config,'--skip-build'), cwd=work, env=env, text=True)
    check_source()
    inventory = [line for line in listing.splitlines() if re.match(r'^(WorkbenchCoreTests|NativeAudioTests)\.', line)]
    assert inventory and len(inventory) == len(set(inventory)), 'Empty or duplicate test inventory'
    (out / (config+'-inventory.txt')).write_text('\n'.join(inventory)+'\n')
    core = [line for line in inventory if line.startswith('WorkbenchCoreTests.')]
    reconcile_functions(results[-1], core)
    native = [line for line in inventory if line.startswith('NativeAudioTests.')]
    ui = [line for line in native if line.split('.',1)[1].split('/',1)[0] in ui_suites]
    assert ui, 'No isolated native UI tests discovered'
    other = [line for line in native if line not in ui]
    suites = sorted({line.split('/',1)[0] for line in other})
    pattern = '^(' + '|'.join(re.escape(suite) for suite in suites) + ')/'
    run('native', config, swift_test('-c',config,'--skip-build','--no-parallel','--filter',pattern), other)
    for index, identifier in enumerate(ui):
        name = str(index+1).zfill(2)+'-'+identifier.split('.',1)[1].replace('/','-').split('(')[0]
        run(name, config, swift_test('-c',config,'--skip-build','--filter','^'+re.escape(identifier.split('(', 1)[0])), [identifier])
    assert sum(row['uniqueFunctions'] for row in results if row['configuration']==config) == len(inventory)
print('COMPLETE', len(results), 'processes', flush=True)
