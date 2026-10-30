#!/usr/bin/env python3
"""Guard/discovery self-check using a new synthetic repository, never App tests."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
output = args.output.resolve()
assert not output.exists(), 'Choose a fresh output directory.'
repo = output / 'fixture-repo'
(repo / 'scripts/dev').mkdir(parents=True)
(repo / 'app/macos/scripts').mkdir(parents=True)
(repo / 'app/macos/Tests/NativeAudioTests').mkdir(parents=True)
driver = Path(__file__).with_name('run-final-local-regression.py')
shutil.copyfile(driver, repo / 'scripts/dev/run-final-local-regression.py')
suite = repo / 'app/macos/Tests/NativeAudioTests/AddedWorkspaceTests.swift'
suite.write_text('struct AddedWorkspaceTests { let nativeBoundary = "NSItemProvider" }\n')
# Clearly fabricated output exercises the orchestration/counting contract only.
(repo / 'app/macos/scripts/test.sh').write_text('''#!/bin/bash
set -euo pipefail
if [[ " $* " == *" list "* ]]; then
  printf '%s\\n' 'WorkbenchCoreTests.CoreTests/core()' 'NativeAudioTests.ProtocolTests/pythonImportsLeaveBridgeResourcesUnchanged()' 'NativeAudioTests.AddedWorkspaceTests/addedDrop()'
elif [[ " $* " == *" WorkbenchCoreTests "* ]]; then
  printf '%s\\n' '✔ Test core() passed after 0.001 seconds.' '✔ Test run with 1 test passed after 0.001 seconds.'
elif [[ " $* " == *"ProtocolTests"* ]]; then
  printf '%s\\n' '✔ Test pythonImportsLeaveBridgeResourcesUnchanged() passed after 0.001 seconds.' '✔ Test run with 1 test passed after 0.001 seconds.'
else
  printf '%s\\n' '✔ Test addedDrop() passed after 0.001 seconds.' '✔ Test run with 1 test passed after 0.001 seconds.'
fi
''')

def git(*args):
    return subprocess.check_output(['git', '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false', *args], cwd=repo, text=True).strip()

git('init', '-q')
git('add', 'app', 'scripts')
git('-c', 'user.name=Local Driver Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'Synthetic driver fixture')
source = git('rev-parse', 'HEAD')
results = []

def run(name, should_pass):
    command = ['/usr/bin/python3', str(repo / 'scripts/dev/run-final-local-regression.py'),
               '--source', source, '--runtime', str(output / 'unused-runtime'), '--output', str(output / name)]
    completed = subprocess.run(command, cwd=repo, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (output / (name + '.log')).write_text(completed.stdout)
    success = completed.returncode == 0
    assert success == should_pass, (name, completed.stdout)
    results.append(dict(name=name, passed=True, driverExit=completed.returncode))

run('clean', True)
summary = json.loads((output / 'clean/summary.json').read_text())
assert len(summary['results']) == 6
for configuration in ['debug', 'release']:
    rows = [row for row in summary['results'] if row['configuration'] == configuration]
    assert [row['name'] for row in rows] == ['core', 'native', '01-AddedWorkspaceTests-addedDrop']
    for row in rows:
        assert row['command'][:2] == ['/usr/bin/sandbox-exec', '-f']
        assert '--scratch-path' in row['command'] and '--disable-sandbox' in row['command']
results.append(dict(name='new-native-ui-suite-isolated-both-configurations-with-network-policy', passed=True))
original = suite.read_text()
suite.write_text(original + '// uncommitted\n')
run('unstaged', False)
git('add', 'app')
run('staged', False)
suite.write_text(original)
git('add', 'app')
(repo / 'app/untracked.swift').write_text('// synthetic source\n')
run('untracked', False)
(repo / 'app/untracked.swift').unlink()
entry = repo / 'app/macos/scripts/test.sh'
original_entry = entry.read_text()
entry.write_text(original_entry.replace(" '✔ Test run with 1 test passed after 0.001 seconds.'", ''))
git('add', 'app')
git('commit', '-qm', 'Synthetic missing-summary fixture')
source = git('rev-parse', 'HEAD')
run('missing-final-summary', False)
entry.write_text(original_entry.replace("'WorkbenchCoreTests.CoreTests/core()'", "'WorkbenchCoreTests.CoreTests/core()' 'WorkbenchCoreTests.CoreTests/core()'"))
git('add', 'app')
git('commit', '-qm', 'Synthetic duplicate-inventory fixture')
source = git('rev-parse', 'HEAD')
run('duplicate-inventory', False)
entry.write_text(original_entry.replace('✔ Test core() passed', '✔ Test wrongCore() passed'))
git('add', 'app')
git('commit', '-qm', 'Synthetic wrong-function fixture with matching count')
source = git('rev-parse', 'HEAD')
run('wrong-function-same-count', False)
assert 'Passed function signatures do not match inventory' in (output / 'wrong-function-same-count.log').read_text()
(output / 'summary.json').write_text(json.dumps(dict(
    evidence='Synthetic driver guard/discovery self-check; not product test evidence.',
    driverSHA256=hashlib.sha256(driver.read_bytes()).hexdigest(), results=results), indent=2) + '\n')
print(json.dumps(results, indent=2))
