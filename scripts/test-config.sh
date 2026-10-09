#!/bin/bash

set -euo pipefail
umask 077
export LC_ALL=C

lane_name="test-config"

fail() {
    printf '%s: %s\n' "$lane_name" "$1" >&2
    exit 1
}

if [[ "$#" -ne 0 ]]; then
    fail "usage: scripts/test-config.sh (no arguments)"
fi

if ! dirname_bin="$(command -v dirname)" || [[ "$dirname_bin" != /* || ! -x "$dirname_bin" ]]; then
    fail "required executable is unavailable: dirname"
fi
if ! python3_bin="$(command -v python3)" || [[ "$python3_bin" != /* || ! -x "$python3_bin" ]]; then
    fail "required executable is unavailable: python3"
fi

script_dir="$(cd -- "$($dirname_bin "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/.." && pwd -P)"

# A temporary fixture root may mirror the bounded source paths below. The parser receives only
# this root, never a caller-supplied setting value or command, so negative probes cannot alter the
# tracked project.
fixture_root_input="${LOOPR_CONFIG_FIXTURE_ROOT:-$repo_root}"

exec "$python3_bin" - "$fixture_root_input" <<'PY'
import os
import plistlib
import stat
import sys
import xml.etree.ElementTree as ElementTree


APP_GROUP_ENTITLEMENT_KEY = "com.apple.security.application-groups"
APP_GROUP_IDENTIFIER = "group.com.loopr.shared"
APP_GROUP_SYSTEM_CAPABILITY_PREFIX = "com.apple.ApplicationGroups."
EXPECTED_BUNDLE_ID = "com.loopr.ios"
EXPECTED_ORIENTATION = "UIInterfaceOrientationPortrait"
EXPECTED_TARGETS = {
    "Loopr": {
        "product_type": "com.apple.product-type.application",
        "bundle_id": EXPECTED_BUNDLE_ID,
        "device_family": "1",
        "group_path": "Loopr",
        "app_group": True,
    },
    "LooprTests": {
        "product_type": "com.apple.product-type.bundle.unit-test",
        "bundle_id": EXPECTED_BUNDLE_ID,
        "device_family": "1",
        "group_path": "LooprTests",
        "app_group": False,
    },
    "LooprUITests": {
        "product_type": "com.apple.product-type.bundle.ui-testing",
        "bundle_id": EXPECTED_BUNDLE_ID,
        "device_family": "1",
        "group_path": "LooprUITests",
        "app_group": False,
    },
    "LooprWidgets": {
        "product_type": "com.apple.product-type.app-extension",
        "bundle_id": "com.loopr.ios.widgets",
        "device_family": "1,2",
        "group_path": None,
        "app_group": True,
    },
    "LooprWatch": {
        "product_type": "com.apple.product-type.application",
        "bundle_id": "com.loopr.ios.watchkitapp",
        "device_family": "4",
        "group_path": None,
        "app_group": True,
    },
    "LooprWatchWidgets": {
        "product_type": "com.apple.product-type.app-extension",
        "bundle_id": "com.loopr.ios.watchkitapp.widgets",
        "device_family": "4",
        "group_path": None,
        "app_group": True,
    },
}
TARGET_ORDER = tuple(EXPECTED_TARGETS)
CONFIG_ORDER = ("Debug", "Release")
ORIENTATION_BUILD_KEYS = {
    "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone",
    "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad",
}
INFO_ORIENTATION_KEYS = {
    "UISupportedInterfaceOrientations",
    "UISupportedInterfaceOrientations~iphone",
    "UISupportedInterfaceOrientations~ipad",
}
RELEVANT_PROJECT_SETTING_PREFIXES = (
    "INFOPLIST_KEY_UISupportedInterfaceOrientations",
)
RELEVANT_PROJECT_SETTINGS = {
    "PRODUCT_BUNDLE_IDENTIFIER",
    "TARGETED_DEVICE_FAMILY",
    "CODE_SIGN_ENTITLEMENTS",
    "INFOPLIST_FILE",
}


class ParseError(Exception):
    pass


class Token:
    __slots__ = ("kind", "value", "line", "column")

    def __init__(self, kind, value, line, column):
        self.kind = kind
        self.value = value
        self.line = line
        self.column = column

    def describe(self):
        if self.kind == "EOF":
            return "end of file"
        return repr(self.value)


class Scalar:
    __slots__ = ("value", "token")

    def __init__(self, value, token):
        self.value = value
        self.token = token


class Assignment:
    __slots__ = ("key", "value", "line", "column")

    def __init__(self, key, value, token):
        self.key = key
        self.value = value
        self.line = token.line
        self.column = token.column


class DictValue:
    __slots__ = ("assignments",)

    def __init__(self, assignments):
        self.assignments = assignments


class ArrayValue:
    __slots__ = ("values",)

    def __init__(self, values):
        self.values = values


class OpenStepLexer:
    """Lexer for the OpenStep subset used by Xcode project files.

    Comments are discarded as whitespace, but tokens and every dictionary assignment remain in
    source order. This is important because a later duplicate key must not mask an earlier value.
    """

    PUNCTUATION = set("{}()=;,")

    def __init__(self, source):
        self.source = source
        self.index = 0
        self.line = 1
        self.column = 1

    def _advance(self, count=1):
        for _ in range(count):
            if self.index >= len(self.source):
                return
            character = self.source[self.index]
            self.index += 1
            if character == "\n":
                self.line += 1
                self.column = 1
            else:
                self.column += 1

    def _skip_whitespace_and_comments(self):
        while self.index < len(self.source):
            if self.source[self.index].isspace():
                self._advance()
                continue
            if self.source.startswith("//", self.index):
                while self.index < len(self.source) and self.source[self.index] != "\n":
                    self._advance()
                continue
            if self.source.startswith("/*", self.index):
                start_line = self.line
                start_column = self.column
                self._advance(2)
                while self.index < len(self.source) and not self.source.startswith("*/", self.index):
                    self._advance()
                if self.index >= len(self.source):
                    raise ParseError(
                        "unterminated block comment starting at "
                        f"{start_line}:{start_column}"
                    )
                self._advance(2)
                continue
            break

    def _quoted(self, line, column):
        self._advance()
        characters = []
        while self.index < len(self.source):
            character = self.source[self.index]
            if character == '"':
                self._advance()
                return Token("STRING", "".join(characters), line, column)
            if character == "\\":
                self._advance()
                if self.index >= len(self.source):
                    raise ParseError(f"unterminated quoted string at {line}:{column}")
                escaped = self.source[self.index]
                self._advance()
                characters.append({"n": "\n", "r": "\r", "t": "\t"}.get(escaped, escaped))
                continue
            if character == "\n" or character == "\r":
                raise ParseError(f"newline in quoted string at {line}:{column}")
            characters.append(character)
            self._advance()
        raise ParseError(f"unterminated quoted string at {line}:{column}")

    def next_token(self):
        self._skip_whitespace_and_comments()
        if self.index >= len(self.source):
            return Token("EOF", "", self.line, self.column)

        line = self.line
        column = self.column
        character = self.source[self.index]
        if character in self.PUNCTUATION:
            self._advance()
            return Token(character, character, line, column)
        if character == '"':
            return self._quoted(line, column)

        start = self.index
        while self.index < len(self.source):
            character = self.source[self.index]
            if character == "$" and self.index + 1 < len(self.source) and self.source[self.index + 1] == "(":
                self._advance(2)
                while self.index < len(self.source) and self.source[self.index] != ")":
                    self._advance()
                if self.index >= len(self.source):
                    raise ParseError(f"unterminated build-setting variable at {line}:{column}")
                self._advance()
                continue
            if character.isspace() or character in self.PUNCTUATION or character == '"':
                break
            if character == "/" and self.index + 1 < len(self.source) and self.source[self.index + 1] in "/*":
                break
            self._advance()
        if self.index == start:
            raise ParseError(f"unsupported character {character!r} at {line}:{column}")
        return Token("ATOM", self.source[start:self.index], line, column)


class OpenStepParser:
    def __init__(self, source):
        self.lexer = OpenStepLexer(source)
        self.lookahead = None

    def _peek(self):
        if self.lookahead is None:
            self.lookahead = self.lexer.next_token()
        return self.lookahead

    def _consume(self):
        token = self._peek()
        self.lookahead = None
        return token

    def _expect(self, kind):
        token = self._consume()
        if token.kind != kind:
            raise ParseError(
                f"expected {kind!r} at {token.line}:{token.column}, found {token.describe()}"
            )
        return token

    def _key(self):
        token = self._consume()
        if token.kind not in ("ATOM", "STRING"):
            raise ParseError(
                f"expected dictionary key at {token.line}:{token.column}, found {token.describe()}"
            )
        return token

    def parse(self):
        value = self._value()
        token = self._peek()
        if token.kind != "EOF":
            raise ParseError(f"trailing token at {token.line}:{token.column}: {token.describe()}")
        return value

    def _value(self):
        token = self._peek()
        if token.kind in ("ATOM", "STRING"):
            self._consume()
            return Scalar(token.value, token)
        if token.kind == "{":
            return self._dictionary()
        if token.kind == "(":
            return self._array()
        raise ParseError(
            f"expected value at {token.line}:{token.column}, found {token.describe()}"
        )

    def _dictionary(self):
        self._expect("{")
        assignments = []
        while self._peek().kind != "}":
            key = self._key()
            self._expect("=")
            value = self._value()
            self._expect(";")
            assignments.append(Assignment(key.value, value, key))
        self._expect("}")
        return DictValue(assignments)

    def _array(self):
        self._expect("(")
        values = []
        if self._peek().kind == ")":
            self._consume()
            return ArrayValue(values)
        while True:
            values.append(self._value())
            token = self._peek()
            if token.kind == ",":
                self._consume()
                if self._peek().kind == ")":
                    self._consume()
                    return ArrayValue(values)
                continue
            if token.kind == ")":
                self._consume()
                return ArrayValue(values)
            raise ParseError(
                f"expected comma or closing parenthesis at {token.line}:{token.column}, found {token.describe()}"
            )


class Verifier:
    def __init__(self, fixture_root):
        self.errors = []
        self.fixture_root = fixture_root
        self.plists = {}
        self.entitlement_records = {}
        self.info_records = {}
        self.synchronized_group_path_by_id = {}
        self.synchronized_group_id_by_path = {}

    def error(self, context, message):
        self.errors.append(f"{context}: {message}")

    def finish(self):
        if self.errors:
            for message in self.errors:
                print(f"test-config: {message}", file=sys.stderr)
            print(f"test-config: static configuration verification failed ({len(self.errors)} finding(s))", file=sys.stderr)
            raise SystemExit(1)

    def existing(self, path, context, kind=None):
        absolute = os.path.normpath(os.path.abspath(path))
        if not os.path.exists(absolute):
            self.error(context, f"path does not exist: {absolute}")
            return None
        if os.path.realpath(absolute) != absolute or os.path.islink(absolute):
            self.error(context, f"symlink path component is forbidden: {absolute}")
            return None
        try:
            mode = os.lstat(absolute).st_mode
        except OSError as exception:
            self.error(context, f"could not inspect path: {exception}")
            return None
        if stat.S_ISLNK(mode):
            self.error(context, f"symlink path component is forbidden: {absolute}")
            return None
        if kind == "directory" and not stat.S_ISDIR(mode):
            self.error(context, f"expected a regular directory: {absolute}")
            return None
        if kind == "file" and not stat.S_ISREG(mode):
            self.error(context, f"expected a regular file: {absolute}")
            return None
        return absolute

    def contained(self, path, context, kind=None):
        absolute = os.path.normpath(os.path.abspath(path))
        try:
            common = os.path.commonpath((self.fixture_root, absolute))
        except ValueError:
            common = None
        if common != self.fixture_root:
            self.error(context, f"path escapes fixture root: {absolute}")
            return None
        return self.existing(absolute, context, kind)

    def relative_link(self, raw_value, base, context):
        return self.relative_path(raw_value, base, context, "file")

    def relative_path(self, raw_value, base, context, kind):
        if not isinstance(raw_value, str) or raw_value == "":
            self.error(context, "linked path must be a nonempty string literal")
            return None
        if "\x00" in raw_value:
            self.error(context, "linked path contains an unsupported NUL character")
            return None
        if "$(" in raw_value or "${" in raw_value:
            self.error(context, f"inherited or variable path is unsupported: {raw_value}")
            return None
        if os.path.isabs(raw_value):
            self.error(context, f"absolute linked path is unsupported: {raw_value}")
            return None
        candidate = os.path.normpath(os.path.join(base, raw_value))
        return self.contained(candidate, context, kind)

    def check_duplicate_keys(self, value, context):
        if isinstance(value, DictValue):
            counts = {}
            for assignment in value.assignments:
                counts[assignment.key] = counts.get(assignment.key, 0) + 1
            for key, count in counts.items():
                if count > 1:
                    self.error(context, f"duplicate assignment {key!r} occurs {count} times")
            for assignment in value.assignments:
                self.check_duplicate_keys(assignment.value, f"{context}.{assignment.key}")
        elif isinstance(value, ArrayValue):
            for index, child in enumerate(value.values):
                self.check_duplicate_keys(child, f"{context}[{index}]")

    def assignments(self, value, key, context, required=True):
        if not isinstance(value, DictValue):
            self.error(context, "expected a dictionary")
            return []
        matches = [assignment for assignment in value.assignments if assignment.key == key]
        if not matches and required:
            self.error(context, f"missing required assignment {key!r}")
        if len(matches) > 1:
            self.error(context, f"duplicate assignment {key!r} is ambiguous")
        return matches

    def single(self, value, key, context, required=True):
        matches = self.assignments(value, key, context, required)
        if len(matches) != 1:
            return None
        return matches[0].value

    def scalar(self, value, context):
        if not isinstance(value, Scalar):
            self.error(context, "expected a scalar literal")
            return None
        return value.value

    def single_scalar(self, value, key, context, required=True):
        assignment = self.single(value, key, context, required)
        if assignment is None:
            return None
        return self.scalar(assignment, f"{context}.{key}")

    def single_array(self, value, key, context, required=True):
        assignment = self.single(value, key, context, required)
        if assignment is None:
            return None
        if not isinstance(assignment, ArrayValue):
            self.error(f"{context}.{key}", "expected an array")
            return None
        return assignment.values

    def object_isa(self, object_id, objects, context):
        object_value = objects.get(object_id)
        if object_value is None:
            self.error(context, f"missing object {object_id}")
            return None
        return self.single_scalar(object_value, "isa", context)

    def build_settings(self, config_id, config_object):
        value = self.single(config_object, "buildSettings", f"XCBuildConfiguration {config_id}")
        if value is None:
            return None
        if not isinstance(value, DictValue):
            self.error(f"XCBuildConfiguration {config_id}.buildSettings", "expected a dictionary")
            return None
        return value

    def setting(self, settings, key, context, required=False):
        matches = self.assignments(settings, key, context, required)
        if len(matches) != 1:
            return None
        raw = self.scalar(matches[0].value, f"{context}.{key}")
        if raw is None:
            return None
        if "$(" in raw or "${" in raw:
            self.error(context, f"inherited or variable setting is unsupported for {key}: {raw}")
            return None
        return raw

    def relevant_setting(self, key):
        return key in RELEVANT_PROJECT_SETTINGS or any(
            key.startswith(prefix) for prefix in RELEVANT_PROJECT_SETTING_PREFIXES
        )

    def validate_plist(self, path, context):
        if path is None:
            return None
        if path in self.plists:
            return self.plists[path]
        self.validate_xml_plist_keys(path, context)
        try:
            with open(path, "rb") as plist_file:
                value = plistlib.load(plist_file)
        except (OSError, plistlib.InvalidFileException, ValueError) as exception:
            self.error(context, f"invalid property list {path}: {exception}")
            return None
        if not isinstance(value, dict):
            self.error(context, f"property list root must be a dictionary: {path}")
            return None
        self.plists[path] = value
        return value

    def validate_xml_plist_keys(self, path, context):
        try:
            with open(path, "rb") as plist_file:
                source = plist_file.read()
        except OSError as exception:
            self.error(context, f"could not read property list {path}: {exception}")
            return

        if not source.lstrip(b" \t\r\n\xef\xbb\xbf").startswith(b"<"):
            return
        try:
            root = ElementTree.fromstring(source)
        except ElementTree.ParseError as exception:
            self.error(context, f"invalid XML property list {path}: {exception}")
            return

        def local_name(tag):
            if not isinstance(tag, str):
                return ""
            return tag.rsplit("}", 1)[-1]

        def visit(element, element_context):
            if local_name(element.tag) == "dict":
                children = list(element)
                keys = []
                for index in range(0, len(children), 2):
                    key_element = children[index]
                    if local_name(key_element.tag) != "key":
                        self.error(element_context, "XML dictionary contains a non-key entry")
                        continue
                    key = key_element.text or ""
                    keys.append(key)
                    if keys.count(key) > 1:
                        self.error(element_context, f"duplicate XML plist dictionary key: {key!r}")
                if len(children) % 2 != 0:
                    self.error(element_context, "XML dictionary has an unpaired key/value entry")
            for index, child in enumerate(list(element)):
                visit(child, f"{element_context}/{local_name(child.tag)}[{index}]")

        visit(root, context)

    def has_forbidden_group(self, value):
        if isinstance(value, dict):
            for key, child in value.items():
                if self.is_forbidden_app_group_key(key) or key == APP_GROUP_IDENTIFIER:
                    return True
                if self.has_forbidden_group(child):
                    return True
        elif isinstance(value, (list, tuple)):
            return any(self.has_forbidden_group(child) for child in value)
        elif isinstance(value, str) and (
            value == APP_GROUP_IDENTIFIER
            or value.startswith(APP_GROUP_SYSTEM_CAPABILITY_PREFIX)
        ):
            return True
        return False

    def is_forbidden_app_group_key(self, key):
        return isinstance(key, str) and (
            key == APP_GROUP_ENTITLEMENT_KEY
            or key == APP_GROUP_IDENTIFIER
            or key == "com.apple.ApplicationGroups"
            or key.startswith(APP_GROUP_SYSTEM_CAPABILITY_PREFIX)
        )

    def validate_info_policy(self, plist, context, expected_bundle_id):
        if plist is None:
            return
        if "CFBundleIdentifier" in plist:
            value = plist["CFBundleIdentifier"]
            if not isinstance(value, str):
                self.error(context, "CFBundleIdentifier must be a string")
            elif value not in (expected_bundle_id, "$(PRODUCT_BUNDLE_IDENTIFIER)"):
                self.error(context, f"CFBundleIdentifier conflicts with target bundle ID: {value}")
            elif "$" in value and value != "$(PRODUCT_BUNDLE_IDENTIFIER)":
                self.error(context, f"unsupported CFBundleIdentifier substitution: {value}")

        if "UIDeviceFamily" in plist:
            value = plist["UIDeviceFamily"]
            if value != [1] or any(isinstance(item, bool) or not isinstance(item, int) for item in value):
                self.error(context, f"UIDeviceFamily must be the exact iPhone-only array [1], found {value!r}")

        for key, value in plist.items():
            if not isinstance(key, str) or not key.startswith("UISupportedInterfaceOrientations"):
                continue
            if key not in INFO_ORIENTATION_KEYS:
                self.error(context, f"unsupported interface-orientation plist key: {key}")
            elif value != [EXPECTED_ORIENTATION]:
                self.error(context, f"{key} must be exactly [{EXPECTED_ORIENTATION!r}], found {value!r}")

    def scan_source_entitlements(self, source_root):
        for directory, directories, files in os.walk(source_root, topdown=True, followlinks=False):
            directories.sort()
            files.sort()
            for name in list(directories) + list(files):
                path = os.path.join(directory, name)
                if os.path.islink(path) or os.path.realpath(path) != os.path.normpath(os.path.abspath(path)):
                    self.error("source tree", f"symlink path component is forbidden: {path}")
            for name in files:
                if not name.endswith(".entitlements"):
                    continue
                path = self.contained(os.path.join(directory, name), "source entitlement", "file")
                plist = self.validate_plist(path, f"source entitlement {name}")
                if plist is not None:
                    self.validate_app_group_policy(
                        plist,
                        f"source entitlement {name}",
                        name in {
                            "Loopr.entitlements",
                            "LooprWidgets.entitlements",
                            "LooprWatch.entitlements",
                            "LooprWatchWidgets.entitlements",
                        },
                    )

    def validate_app_group_policy(self, plist, context, required):
        value = plist.get(APP_GROUP_ENTITLEMENT_KEY)
        if required:
            if value != [APP_GROUP_IDENTIFIER]:
                self.error(
                    context,
                    f"app-group entitlement must be exactly [{APP_GROUP_IDENTIFIER!r}], found {value!r}",
                )
        elif value is not None:
            self.error(context, "this target must not carry the App Group entitlement")

    def validate_privacy_manifest(self, plist):
        context = "privacy manifest"
        if plist is None:
            return
        # NSPrivacyTrackingDomains is optional when NSPrivacyTracking is false.
        required_keys = {
            "NSPrivacyTracking",
            "NSPrivacyCollectedDataTypes",
            "NSPrivacyAccessedAPITypes",
        }
        allowed_keys = required_keys | {"NSPrivacyTrackingDomains"}
        if not required_keys <= set(plist) <= allowed_keys:
            self.error(context, f"root keys must be {sorted(required_keys)!r}, optionally with NSPrivacyTrackingDomains")
        if plist.get("NSPrivacyTracking") is not False:
            self.error(context, "NSPrivacyTracking must be false")
        if plist.get("NSPrivacyTrackingDomains", []) != []:
            self.error(context, "NSPrivacyTrackingDomains must be empty")
        if plist.get("NSPrivacyCollectedDataTypes") != []:
            self.error(context, "stable local-only composition must declare no collected data types")
        accessed = plist.get("NSPrivacyAccessedAPITypes")
        # SystemBootTime covers ProcessInfo.systemUptime in LooprDayNavigator.
        expected_accessed = [{
            "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
            "NSPrivacyAccessedAPITypeReasons": ["CA92.1", "1C8F.1"],
        }, {
            "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategorySystemBootTime",
            "NSPrivacyAccessedAPITypeReasons": ["35F9.1"],
        }]
        if accessed != expected_accessed:
            self.error(context, f"required-reason declarations must be exactly {expected_accessed!r}")

    def validate_repository_path_fields(self, objects, isa_by_id, project_object, source_root):
        synchronized_group_ids = {
            object_id
            for object_id, isa in isa_by_id.items()
            if isa == "PBXFileSystemSynchronizedRootGroup"
        }
        synchronized_paths = {}
        for object_id in sorted(synchronized_group_ids):
            context = f"PBXFileSystemSynchronizedRootGroup {object_id}"
            object_value = objects[object_id]
            path_value = self.single_scalar(object_value, "path", context)
            source_tree = self.single_scalar(object_value, "sourceTree", context)
            if source_tree not in ("<group>", "SOURCE_ROOT"):
                self.error(context, f"unsupported sourceTree for repository path: {source_tree!r}")
            if path_value is not None:
                resolved = self.relative_path(path_value, source_root, context, "directory")
                if resolved is not None:
                    relative_path = os.path.relpath(resolved, source_root)
                    synchronized_paths[object_id] = relative_path
                    self.synchronized_group_path_by_id[object_id] = relative_path
                    if relative_path in self.synchronized_group_id_by_path:
                        self.error(context, f"duplicate synchronized root-group path: {relative_path}")
                    else:
                        self.synchronized_group_id_by_path[relative_path] = object_id

        expected_synchronized_paths = {"Loopr", "LooprTests", "LooprUITests"}
        if set(synchronized_paths.values()) != expected_synchronized_paths:
            self.error(
                "PBXFileSystemSynchronizedRootGroup",
                "repository synchronized root-group paths must match the declared target inventory",
            )

        package_object_ids = {
            object_id
            for object_id, isa in isa_by_id.items()
            if isa == "XCLocalSwiftPackageReference"
        }
        package_reference_values = self.single_array(project_object, "packageReferences", "PBXProject")
        project_package_ids = []
        if package_reference_values is not None:
            for index, value in enumerate(package_reference_values):
                scalar = self.scalar(value, f"PBXProject.packageReferences[{index}]")
                if scalar is not None:
                    project_package_ids.append(scalar)
        if len(project_package_ids) != len(set(project_package_ids)):
            self.error("PBXProject.packageReferences", "duplicate package reference is not allowed")
        if set(project_package_ids) != package_object_ids or len(package_object_ids) != 1:
            self.error(
                "PBXProject.packageReferences",
                "package membership must contain exactly the accepted XCLocalSwiftPackageReference",
            )

        expected_package_path = self.contained(
            os.path.join(self.fixture_root, "LooprPackages"),
            "accepted LooprPackages package root",
            "directory",
        )
        for object_id in sorted(package_object_ids):
            context = f"XCLocalSwiftPackageReference {object_id}"
            relative_path = self.single_scalar(objects[object_id], "relativePath", context)
            if relative_path is None:
                continue
            resolved = self.relative_path(relative_path, source_root, context, "directory")
            if resolved is not None and expected_package_path is not None and resolved != expected_package_path:
                self.error(
                    context,
                    f"relativePath must resolve to the accepted LooprPackages root {expected_package_path}, found {resolved}",
                )

    def validate_target_synchronized_group_memberships(self, target_records, objects, isa_by_id):
        used_group_ids = {}
        for target_name in TARGET_ORDER:
            target_record = target_records.get(target_name)
            context = f"target {target_name}"
            if target_record is None:
                continue
            group_values = self.single_array(
                target_record["object"],
                "fileSystemSynchronizedGroups",
                context,
                required=False,
            )
            group_ids = []
            if group_values is not None:
                for index, value in enumerate(group_values):
                    scalar = self.scalar(value, f"{context}.fileSystemSynchronizedGroups[{index}]")
                    if scalar is not None:
                        group_ids.append(scalar)
            expected_group_path = EXPECTED_TARGETS[target_name]["group_path"]
            expected_group_count = 1 if expected_group_path is not None else 0
            if len(group_ids) != expected_group_count:
                self.error(
                    context,
                    f"fileSystemSynchronizedGroups must contain exactly {expected_group_count} root groups, found {len(group_ids)}",
                )
                continue

            if expected_group_path is None:
                continue

            group_id = group_ids[0]
            if group_id in used_group_ids:
                self.error(
                    context,
                    f"fileSystemSynchronizedGroups reuses group {group_id} already mapped to {used_group_ids[group_id]}",
                )
            used_group_ids[group_id] = target_name
            if isa_by_id.get(group_id) != "PBXFileSystemSynchronizedRootGroup":
                self.error(
                    context,
                    f"fileSystemSynchronizedGroups must reference PBXFileSystemSynchronizedRootGroup, found {isa_by_id.get(group_id)!r}",
                )
                continue

            group_path = self.synchronized_group_path_by_id.get(group_id)
            if group_path != expected_group_path:
                self.error(
                    context,
                    f"fileSystemSynchronizedGroups must map to path {expected_group_path!r}, found {group_path!r}",
                )

        expected_group_ids = set(self.synchronized_group_path_by_id)
        if set(used_group_ids) != expected_group_ids:
            self.error(
                "fileSystemSynchronizedGroups",
                "every synchronized root group must be mapped exactly once by its matching target",
            )

    def validate_watch_shared_surface_ownership(self, target_records, objects, isa_by_id):
        expected_source_path = "../../LooprPackages/Sources/SharedSurfaceKit/Placeholder.swift"
        for target_name in ("LooprWatch", "LooprWatchWidgets"):
            target_record = target_records.get(target_name)
            if target_record is None:
                continue
            target_object = target_record["object"]
            context = f"target {target_name}"

            package_values = self.single_array(
                target_object,
                "packageProductDependencies",
                context,
                required=False,
            )
            if package_values is not None:
                for index, value in enumerate(package_values):
                    product_id = self.scalar(
                        value,
                        f"{context}.packageProductDependencies[{index}]",
                    )
                    product = objects.get(product_id) if product_id is not None else None
                    if product is None or isa_by_id.get(product_id) != "XCSwiftPackageProductDependency":
                        self.error(context, "packageProductDependencies contains an invalid product link")
                        continue
                    product_name = self.single_scalar(
                        product,
                        "productName",
                        f"package product {product_id}",
                    )
                    if product_name == "SharedSurfaceKit":
                        self.error(
                            context,
                            "must compile the shared surface model source directly; linking the iOS package product breaks mixed iPhone/Watch Release Simulator builds",
                        )

            source_paths = []
            phase_values = self.single_array(target_object, "buildPhases", context)
            if phase_values is not None:
                for phase_index, phase_value in enumerate(phase_values):
                    phase_id = self.scalar(phase_value, f"{context}.buildPhases[{phase_index}]")
                    phase = objects.get(phase_id) if phase_id is not None else None
                    if phase is None or isa_by_id.get(phase_id) != "PBXSourcesBuildPhase":
                        continue
                    file_values = self.single_array(phase, "files", f"source phase {phase_id}")
                    if file_values is None:
                        continue
                    for file_index, file_value in enumerate(file_values):
                        build_file_id = self.scalar(
                            file_value,
                            f"source phase {phase_id}.files[{file_index}]",
                        )
                        build_file = objects.get(build_file_id) if build_file_id is not None else None
                        if build_file is None or isa_by_id.get(build_file_id) != "PBXBuildFile":
                            continue
                        file_ref_id = self.single_scalar(
                            build_file,
                            "fileRef",
                            f"build file {build_file_id}",
                        )
                        file_ref = objects.get(file_ref_id) if file_ref_id is not None else None
                        if file_ref is None or isa_by_id.get(file_ref_id) != "PBXFileReference":
                            continue
                        path = self.single_scalar(file_ref, "path", f"file reference {file_ref_id}")
                        if path is not None:
                            source_paths.append(path)

            if source_paths.count(expected_source_path) != 1:
                self.error(
                    context,
                    f"must compile exactly one shared surface model source at {expected_source_path!r}",
                )

    def run(self):
        root_input = os.path.normpath(os.path.abspath(sys.argv[1]))
        if not os.path.isdir(root_input):
            self.error("fixture root", f"not a directory: {root_input}")
            self.finish()
        if os.path.islink(root_input):
            self.error("fixture root", f"symlink path component is forbidden: {root_input}")
            self.finish()
        self.fixture_root = os.path.realpath(root_input)

        project_directory = self.contained(
            os.path.join(self.fixture_root, "Loopr", "Loopr.xcodeproj"),
            "Xcode project directory",
            "directory",
        )
        project_path = self.contained(
            os.path.join(self.fixture_root, "Loopr", "Loopr.xcodeproj", "project.pbxproj"),
            "Xcode project",
            "file",
        )
        source_root = self.contained(
            os.path.join(self.fixture_root, "Loopr"),
            "Xcode source root",
            "directory",
        )
        if project_directory is None or project_path is None or source_root is None:
            self.finish()

        try:
            with open(project_path, "r", encoding="utf-8") as project_file:
                project_source = project_file.read()
            if project_source.startswith("\ufeff"):
                project_source = project_source[1:]
            project_root = OpenStepParser(project_source).parse()
        except (OSError, UnicodeError, ParseError) as exception:
            print(f"test-config: project parser failed: {exception}", file=sys.stderr)
            raise SystemExit(1)

        if not isinstance(project_root, DictValue):
            self.error("project root", "expected a dictionary")
            self.finish()
        self.check_duplicate_keys(project_root, "project")

        objects_value = self.single(project_root, "objects", "project")
        if not isinstance(objects_value, DictValue):
            self.error("project.objects", "expected a dictionary")
            self.finish()

        objects = {}
        for assignment in objects_value.assignments:
            if assignment.key in objects:
                self.error("project.objects", f"duplicate object identifier is not allowed: {assignment.key}")
                continue
            if not isinstance(assignment.value, DictValue):
                self.error("project.objects", f"object {assignment.key} must be a dictionary")
                continue
            objects[assignment.key] = assignment.value

        root_object_id = self.single_scalar(project_root, "rootObject", "project")
        root_object = objects.get(root_object_id) if root_object_id is not None else None
        if root_object is None:
            self.error("project.rootObject", f"missing referenced object: {root_object_id}")
            self.finish()

        isa_by_id = {}
        for object_id, object_value in objects.items():
            isa_by_id[object_id] = self.object_isa(object_id, objects, "object " + object_id)

        if isa_by_id.get(root_object_id) != "PBXProject":
            self.error("project.rootObject", f"rootObject must reference a PBXProject, found {isa_by_id.get(root_object_id)!r}")
        project_object = root_object

        self.scan_project_for_app_group(project_root)
        self.validate_repository_path_fields(objects, isa_by_id, project_object, source_root)

        target_values = self.single_array(project_object, "targets", "PBXProject")
        target_ids = []
        if target_values is not None:
            for index, value in enumerate(target_values):
                scalar = self.scalar(value, f"PBXProject.targets[{index}]")
                if scalar is not None:
                    target_ids.append(scalar)
        if len(target_ids) != len(set(target_ids)):
            self.error("PBXProject.targets", "duplicate target membership is not allowed")
        if len(target_ids) != len(EXPECTED_TARGETS):
            self.error("PBXProject.targets", f"expected exactly {len(EXPECTED_TARGETS)} target memberships, found {len(target_ids)}")

        project_configuration_list_id = self.single_scalar(
            project_object, "buildConfigurationList", "PBXProject"
        )
        target_records = {}
        names_seen = {}
        target_configuration_list_ids = []
        for target_id in target_ids:
            target_object = objects.get(target_id)
            target_context = f"target {target_id}"
            if target_object is None:
                self.error(target_context, "membership references a missing object")
                continue
            if isa_by_id.get(target_id) != "PBXNativeTarget":
                self.error(target_context, f"membership must reference PBXNativeTarget, found {isa_by_id.get(target_id)!r}")
                continue
            name = self.single_scalar(target_object, "name", target_context)
            product_type = self.single_scalar(target_object, "productType", target_context)
            configuration_list_id = self.single_scalar(target_object, "buildConfigurationList", target_context)
            if name is not None:
                names_seen[name] = names_seen.get(name, 0) + 1
            if name not in EXPECTED_TARGETS:
                self.error(target_context, f"unexpected target name: {name!r}")
            else:
                expected = EXPECTED_TARGETS[name]
                if product_type != expected["product_type"]:
                    self.error(target_context, f"productType must be {expected['product_type']!r}, found {product_type!r}")
                target_records[name] = {
                    "id": target_id,
                    "object": target_object,
                    "configuration_list": configuration_list_id,
                }
            if configuration_list_id is not None:
                target_configuration_list_ids.append(configuration_list_id)

        native_target_ids = {object_id for object_id, isa in isa_by_id.items() if isa == "PBXNativeTarget"}
        if native_target_ids != set(target_ids):
            self.error("PBXProject.targets", "native target objects and project membership differ")
        if len(target_records) != len(EXPECTED_TARGETS):
            self.error("PBXProject.targets", f"expected exactly the declared {len(EXPECTED_TARGETS)}-target inventory")
        for target_name in TARGET_ORDER:
            if names_seen.get(target_name, 0) != 1:
                self.error("PBXProject.targets", f"expected exactly one target named {target_name}, found {names_seen.get(target_name, 0)}")
        self.validate_target_synchronized_group_memberships(target_records, objects, isa_by_id)
        self.validate_watch_shared_surface_ownership(target_records, objects, isa_by_id)
        if len(target_configuration_list_ids) != len(set(target_configuration_list_ids)):
            self.error("PBXProject.targets", "target configuration lists must not be shared")
        if project_configuration_list_id in target_configuration_list_ids:
            self.error("PBXProject", "project and target configuration lists must be distinct")

        all_configuration_list_ids = {
            object_id for object_id, isa in isa_by_id.items() if isa == "XCConfigurationList"
        }
        expected_configuration_list_ids = set(target_configuration_list_ids)
        if project_configuration_list_id is not None:
            expected_configuration_list_ids.add(project_configuration_list_id)
        if all_configuration_list_ids != expected_configuration_list_ids:
            self.error("configuration lists", "all XCConfigurationList objects must be exactly the project list plus the declared target lists")

        configuration_list_records = {}
        configuration_usage = {}
        for owner, list_id in [("project", project_configuration_list_id)] + [
            (name, record.get("configuration_list")) for name, record in target_records.items()
        ]:
            if list_id is None:
                continue
            list_object = objects.get(list_id)
            context = f"{owner} configuration list {list_id}"
            if list_object is None or isa_by_id.get(list_id) != "XCConfigurationList":
                self.error(context, "link must reference XCConfigurationList")
                continue
            if self.assignments(list_object, "baseConfigurationReference", context, required=False):
                self.error(context, "baseConfigurationReference is unsupported; inherited settings are ambiguous")
            config_values = self.single_array(list_object, "buildConfigurations", context)
            config_ids = []
            if config_values is not None:
                for index, value in enumerate(config_values):
                    scalar = self.scalar(value, f"{context}.buildConfigurations[{index}]")
                    if scalar is not None:
                        config_ids.append(scalar)
            if len(config_ids) != 2:
                self.error(context, f"expected exactly Debug and Release configuration links, found {len(config_ids)}")
            if len(config_ids) != len(set(config_ids)):
                self.error(context, "duplicate build configuration link is not allowed")
            configuration_list_records[owner] = config_ids
            for config_id in config_ids:
                configuration_usage[config_id] = configuration_usage.get(config_id, 0) + 1

        for config_id, usage in configuration_usage.items():
            if usage != 1:
                self.error("configuration links", f"build configuration {config_id} is linked {usage} times")

        all_build_configuration_ids = {
            object_id for object_id, isa in isa_by_id.items() if isa == "XCBuildConfiguration"
        }
        if all_build_configuration_ids != set(configuration_usage):
            self.error("build configurations", "all XCBuildConfiguration objects must be linked exactly once")

        config_records = {}
        for owner, config_ids in configuration_list_records.items():
            names = {}
            for config_id in config_ids:
                config_object = objects.get(config_id)
                context = f"{owner} build configuration {config_id}"
                if config_object is None or isa_by_id.get(config_id) != "XCBuildConfiguration":
                    self.error(context, "link must reference XCBuildConfiguration")
                    continue
                if self.assignments(config_object, "baseConfigurationReference", context, required=False):
                    self.error(context, "baseConfigurationReference is unsupported; inherited settings are ambiguous")
                config_name = self.single_scalar(config_object, "name", context)
                settings = self.build_settings(config_id, config_object)
                if config_name not in CONFIG_ORDER:
                    self.error(context, f"configuration name must be Debug or Release, found {config_name!r}")
                elif config_name in names:
                    self.error(f"{owner} configuration list", f"duplicate {config_name} mapping")
                else:
                    names[config_name] = {
                        "id": config_id,
                        "object": config_object,
                        "settings": settings,
                    }
            if set(names) != set(CONFIG_ORDER):
                self.error(f"{owner} configuration list", "must map exactly one Debug and one Release configuration")
            config_records[owner] = names

        project_config_records = config_records.get("project", {})
        project_settings_by_name = {
            name: record.get("settings") for name, record in project_config_records.items()
        }
        for config_name, settings in project_settings_by_name.items():
            if settings is None:
                continue
            for assignment in settings.assignments:
                if self.relevant_setting(assignment.key):
                    self.error(
                        f"project/{config_name}",
                        f"project-level {assignment.key} would be inherited/ambiguous; target-level exact assignment required",
                    )

        linked_info_paths = {}
        linked_entitlement_paths = {}
        for target_name in TARGET_ORDER:
            target_record = target_records.get(target_name)
            target_config_records = config_records.get(target_name, {})
            if target_record is None:
                continue
            for config_name in CONFIG_ORDER:
                config_record = target_config_records.get(config_name)
                context = f"{target_name}/{config_name}"
                if config_record is None:
                    self.entitlement_records[(target_name, config_name)] = "<invalid configuration>"
                    self.info_records[(target_name, config_name)] = "<invalid configuration>"
                    continue
                settings = config_record.get("settings")
                if settings is None:
                    self.entitlement_records[(target_name, config_name)] = "<invalid settings>"
                    self.info_records[(target_name, config_name)] = "<invalid settings>"
                    continue

                self.validate_target_settings(target_name, config_name, settings)

                project_settings = project_settings_by_name.get(config_name)
                entitlement_value = self.setting(settings, "CODE_SIGN_ENTITLEMENTS", context)
                if entitlement_value is None and project_settings is not None:
                    if self.assignments(project_settings, "CODE_SIGN_ENTITLEMENTS", context, required=False):
                        self.error(context, "CODE_SIGN_ENTITLEMENTS would be inherited from the project")
                if entitlement_value is None:
                    self.entitlement_records[(target_name, config_name)] = "<none>"
                else:
                    path = self.relative_link(
                        entitlement_value,
                        source_root,
                        f"{context} CODE_SIGN_ENTITLEMENTS",
                    )
                    if path is None:
                        self.entitlement_records[(target_name, config_name)] = "<invalid>"
                    else:
                        plist = self.validate_plist(path, f"{context} CODE_SIGN_ENTITLEMENTS")
                        self.entitlement_records[(target_name, config_name)] = path
                        linked_entitlement_paths[path] = plist
                        if plist is not None:
                            self.validate_app_group_policy(
                                plist,
                                context,
                                EXPECTED_TARGETS[target_name]["app_group"],
                            )

                info_value = self.setting(settings, "INFOPLIST_FILE", context)
                if info_value is None and project_settings is not None:
                    if self.assignments(project_settings, "INFOPLIST_FILE", context, required=False):
                        self.error(context, "INFOPLIST_FILE would be inherited from the project")
                if info_value is None:
                    self.info_records[(target_name, config_name)] = "<generated/no source plist>"
                else:
                    path = self.relative_link(info_value, source_root, f"{context} INFOPLIST_FILE")
                    if path is None:
                        self.info_records[(target_name, config_name)] = "<invalid>"
                    else:
                        plist = self.validate_plist(path, f"{context} INFOPLIST_FILE")
                        self.info_records[(target_name, config_name)] = path
                        linked_info_paths[path] = plist
                        self.validate_info_policy(plist, context, EXPECTED_TARGETS[target_name]["bundle_id"])

        default_info_path = self.contained(
            os.path.join(source_root, "Loopr", "Info.plist"),
            "source Info.plist",
            "file",
        )
        default_info = self.validate_plist(default_info_path, "source Info.plist")
        self.validate_info_policy(default_info, "source Info.plist", EXPECTED_BUNDLE_ID)
        self.scan_source_entitlements(source_root)

        privacy_path = self.contained(
            os.path.join(source_root, "Loopr", "Resources", "PrivacyInfo.xcprivacy"),
            "privacy manifest",
            "file",
        )
        privacy = self.validate_plist(privacy_path, "privacy manifest")
        self.validate_privacy_manifest(privacy)

        for path, plist in linked_info_paths.items():
            if plist is not None and self.has_forbidden_group(plist):
                self.error(f"linked plist {path}", "App Group key or identifier is forbidden project-wide")
        self.finish()

        print("PROJECT: rootObject resolves to PBXProject; target membership matches the declared six-target inventory")
        print("TARGETS: PBXNativeTarget names and product types match the current DEC-01 project")
        print("WATCH SHARED MODEL: Watch app and complication compile the canonical source directly without a cross-platform package-product link")
        print("PRODUCT_BUNDLE_IDENTIFIER: every target Debug/Release assignment matches its declared app, extension, or test identifier")
        print("TARGETED_DEVICE_FAMILY: every target Debug/Release assignment matches its iPhone, widget, or Watch platform")
        print("ORIENTATION: app Debug/Release iPhone and iPad build settings are exactly portrait")
        for target_name in TARGET_ORDER:
            for config_name in CONFIG_ORDER:
                entitlement = self.entitlement_records.get((target_name, config_name), "<missing>")
                info = self.info_records.get((target_name, config_name), "<missing>")
                print(f"PLISTS: {target_name}/{config_name} entitlements={self.display(entitlement)} Info.plist={self.display(info)}")
        print("ENTITLEMENTS: the app, phone widget, Watch app, and Watch complication share exactly the registered Loopr App Group; test targets have none")
        print("PRIVACY: manifest is non-tracking/non-collecting and declares app/App-Group UserDefaults reasons")
        print("RELEASE COMPOSITION: deferred to FND-05; no release-composition claim is made here")
        print("test-config: static configuration verification passed")

    def display(self, path):
        if path.startswith("<"):
            return path
        return os.path.relpath(path, self.fixture_root)

    def scan_project_for_app_group(self, value, context="project"):
        if isinstance(value, DictValue):
            for assignment in value.assignments:
                if self.is_forbidden_app_group_key(assignment.key):
                    self.error(context, f"App Group key or identifier is forbidden: {assignment.key}")
                self.scan_project_for_app_group(assignment.value, f"{context}.{assignment.key}")
        elif isinstance(value, ArrayValue):
            for index, child in enumerate(value.values):
                self.scan_project_for_app_group(child, f"{context}[{index}]")
        elif isinstance(value, Scalar):
            if value.value == APP_GROUP_IDENTIFIER or value.value.startswith(APP_GROUP_SYSTEM_CAPABILITY_PREFIX):
                self.error(context, f"App Group identifier or SystemCapabilities alias is forbidden: {value.value}")

    def validate_target_settings(self, target_name, config_name, settings):
        context = f"{target_name}/{config_name}"
        bundle_id = self.setting(settings, "PRODUCT_BUNDLE_IDENTIFIER", context, required=True)
        if bundle_id is not None and bundle_id != EXPECTED_TARGETS[target_name]["bundle_id"]:
            self.error(context, f"PRODUCT_BUNDLE_IDENTIFIER must be {EXPECTED_TARGETS[target_name]['bundle_id']!r}, found {bundle_id!r}")

        expected_device_family = EXPECTED_TARGETS[target_name]["device_family"]
        device_family = self.setting(settings, "TARGETED_DEVICE_FAMILY", context, required=True)
        if device_family is not None and device_family != expected_device_family:
            self.error(context, f"TARGETED_DEVICE_FAMILY must be exactly {expected_device_family!r}, found {device_family!r}")

        if target_name in ("LooprWatch", "LooprWatchWidgets"):
            sdk_root = self.setting(settings, "SDKROOT", context, required=True)
            if sdk_root is not None and sdk_root != "watchos":
                self.error(context, f"SDKROOT must be 'watchos', found {sdk_root!r}")
            supported_platforms = self.setting(settings, "SUPPORTED_PLATFORMS", context, required=True)
            if supported_platforms is not None and supported_platforms != "watchos watchsimulator":
                self.error(
                    context,
                    "SUPPORTED_PLATFORMS must be exactly 'watchos watchsimulator'",
                )
            deployment_target = self.setting(settings, "WATCHOS_DEPLOYMENT_TARGET", context, required=True)
            if deployment_target is not None and deployment_target != "26.0":
                self.error(context, f"WATCHOS_DEPLOYMENT_TARGET must be '26.0', found {deployment_target!r}")

        orientation_assignments = [
            assignment for assignment in settings.assignments
            if assignment.key.startswith("INFOPLIST_KEY_UISupportedInterfaceOrientations")
        ]
        if target_name == "Loopr":
            for key in ORIENTATION_BUILD_KEYS:
                value = self.setting(settings, key, context, required=True)
                if value is not None and value != EXPECTED_ORIENTATION:
                    self.error(context, f"{key} must be exactly {EXPECTED_ORIENTATION!r}, found {value!r}")
            for assignment in orientation_assignments:
                if assignment.key not in ORIENTATION_BUILD_KEYS:
                    self.error(context, f"unsupported orientation build setting: {assignment.key}")
                elif not isinstance(assignment.value, Scalar):
                    self.error(context, f"{assignment.key} must be a scalar literal")
        elif orientation_assignments:
            self.error(context, "non-app targets must not carry app orientation build settings")


def main():
    try:
        fixture_input = sys.argv[1]
    except IndexError:
        print("test-config: missing fixture root", file=sys.stderr)
        raise SystemExit(1)

    fixture_absolute = os.path.normpath(os.path.abspath(fixture_input))
    if not os.path.isdir(fixture_absolute):
        print(f"test-config: fixture root is not a directory: {fixture_absolute}", file=sys.stderr)
        raise SystemExit(1)
    if os.path.islink(fixture_absolute):
        print(f"test-config: symlink path component is forbidden in fixture root: {fixture_absolute}", file=sys.stderr)
        raise SystemExit(1)

    Verifier(os.path.realpath(fixture_absolute)).run()


if __name__ == "__main__":
    main()
PY
