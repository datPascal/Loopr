#!/usr/bin/env python3
"""Check shared-Mac isolation without launching a test process or simulator."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
source = (root / 'scripts/test-fast.sh').read_text()
start = source.index('function has_action(')
end = source.index("\n' <<< \"$process_list\"", start)
program = source[start:end]
fixture_root = '/Users/example/Projects/Loopr'
fixture_dd = '/private/tmp/loopr-five-tabs/dd'
cases = [
    ('1 /usr/bin/xcodebuild xcodebuild -scheme Loopr test', True),
    ('2 /usr/bin/xcodebuild xcodebuild -scheme LooprPackages-Package test-without-building', True),
    ('3 /usr/bin/xcodebuild xcodebuild -scheme LooprCustom test', True),
    ('4 /usr/bin/xcodebuild xcodebuild -project Loopr.xcodeproj -scheme Custom test', True),
    (f'5 /usr/bin/xcodebuild xcodebuild -project {fixture_root}/Other.xcodeproj -scheme Custom test', True),
    (f'6 /usr/bin/xcodebuild xcodebuild -scheme AnotherApp -derivedDataPath {fixture_dd} test', True),
    ('7 /usr/bin/xcodebuild xcodebuild test', True),
    ('8 /usr/bin/xctest xctest SomeTests.xctest', True),
    ('9 /usr/bin/swift swift test', True),
    ('10 /usr/bin/xcodebuild xcodebuild -project /Projects/AnotherApp.xcodeproj -scheme AnotherApp -destination platform=iOS,id=foreign test', False),
    ('11 /usr/bin/xcodebuild xcodebuild -scheme Loopr build-for-testing', False),
    ('12 /bin/ps ps -axo pid=,comm=,args=', False),
]
for record, blocked in cases:
    result = subprocess.run(['/usr/bin/awk', '-v', f'repo_root={fixture_root}', '-v', f'derived_data_path={fixture_dd}', program],
                            input=record + '\n', text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    assert bool(result.stdout.strip()) == blocked, record
malformed = subprocess.run(['/usr/bin/awk', '-v', f'repo_root={fixture_root}', '-v', f'derived_data_path={fixture_dd}', program],
                           input='unreadable process record\n', text=True, capture_output=True)
assert malformed.returncode == 2
print('Fast process guard: 13 cases passed. Loopr stays serial; named foreign projects may use their own fleet leases.')
