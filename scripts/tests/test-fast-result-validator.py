#!/usr/bin/env python3
"""Exercise the fast lane's actual jq test-tree validator with small fixtures."""
import copy
import json
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[2]
script = (root / 'scripts/test-fast.sh').read_text()
start = script.index('# Keep destination matching exact')
end = script.index("\n' <<< \"$tests_json\"", start)
program = script[start:end]
fixture = {
    'testPlanConfigurations': [{'configurationId': '1', 'configurationName': 'Test Action'}],
    'devices': [{'deviceId': '01234567-89AB-CDEF-0123-456789ABCDEF', 'deviceName': 'iPhone 17',
                 'architecture': 'arm64', 'modelName': 'iPhone 17', 'platform': 'iOS Simulator', 'osVersion': '26.3'}],
    'testNodes': [{'name': 'Loopr', 'nodeType': 'Test Plan', 'result': 'Passed', 'children': [
        {'name': 'LooprTests', 'nodeType': 'Unit test bundle', 'result': 'Passed', 'children': [
            {'name': 'example()', 'nodeType': 'Test Case', 'result': 'Passed', 'children': [
                {'name': 'Priority inversion', 'nodeType': 'Runtime Warning'}]}]}]}]
}

def validate(tree, passes):
    command = [shutil.which('jq'), '-er']
    for key, value in {'expected_plan': 'Loopr', 'expected_targets': 'LooprTests',
                       'selected_udid': fixture['devices'][0]['deviceId'],
                       'selected_device': 'iPhone 17', 'selected_runtime': '26.3'}.items():
        command += ['--arg', key, value]
    result = subprocess.run(command + [program], input=json.dumps(tree), text=True, capture_output=True)
    assert (result.returncode == 0) == passes, result.stderr or result.stdout

def test_case(tree):
    return tree['testNodes'][0]['children'][0]['children'][0]

validate(fixture, True)
missing = copy.deepcopy(fixture)
del test_case(missing)['result']
validate(missing, False)
for result in ['Failed', 'Skipped', 'Expected Failure', 'unknown']:
    failed = copy.deepcopy(fixture)
    test_case(failed)['result'] = result
    validate(failed, False)
warning = copy.deepcopy(fixture)
test_case(warning)['children'][0]['result'] = 'Failed'
validate(warning, False)
wrong_device = copy.deepcopy(fixture)
wrong_device['devices'][0]['deviceId'] = 'wrong-device'
validate(wrong_device, False)
unknown = copy.deepcopy(fixture)
test_case(unknown)['children'][0]['nodeType'] = 'Future node type'
validate(unknown, False)
print('Fast result validator: 9 cases passed, including result-free runtime warnings and fail-closed test results.')
