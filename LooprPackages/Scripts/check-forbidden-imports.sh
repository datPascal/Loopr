#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"

exec python3 - "$REPO_ROOT" <<'PY'
from pathlib import Path
import errno
import os
import stat
import sys


class Token:
    def __init__(self, value, line, kind, parens, brackets, braces, escaped=False):
        self.value = value
        self.line = line
        self.kind = kind
        self.parens = parens
        self.brackets = brackets
        self.braces = braces
        self.escaped = escaped


def string_start(source, index):
    """Return (hash_count, multiline, opener_length), or None."""
    if source[index] == '"':
        if source.startswith('"""', index):
            return 0, True, 3
        return 0, False, 1
    if source[index] != '#':
        return None
    end = index
    while end < len(source) and source[end] == '#':
        end += 1
    if end == len(source) or source[end] != '"':
        return None
    hashes = end - index
    if source.startswith('"""', end):
        return hashes, True, hashes + 3
    return hashes, False, hashes + 1


def skip_string(source, index, line, hashes, multiline, opener_length):
    """Skip one Swift string and return (next_index, next_line)."""
    index += opener_length
    quote_count = 3 if multiline else 1
    closing = '"' * quote_count + '#' * hashes
    while index < len(source):
        if source.startswith(closing, index):
            return index + len(closing), line
        if source[index] == '\n':
            line += 1
            index += 1
        elif hashes == 0 and source[index] == '\\':
            index += 1
            if index < len(source):
                if source[index] == '\n':
                    line += 1
                index += 1
        else:
            index += 1
    return index, line


def scan_tokens(source):
    tokens = []
    index = 0
    line = 1
    parens = 0
    brackets = 0
    braces = 0

    while index < len(source):
        character = source[index]

        if character in ' \t\r\f\v':
            index += 1
            continue
        if character == '\n':
            line += 1
            index += 1
            continue

        if source.startswith('//', index):
            index += 2
            while index < len(source) and source[index] != '\n':
                index += 1
            continue

        if source.startswith('/*', index):
            index += 2
            comment_depth = 1
            while index < len(source) and comment_depth:
                if source.startswith('/*', index):
                    comment_depth += 1
                    index += 2
                elif source.startswith('*/', index):
                    comment_depth -= 1
                    index += 2
                else:
                    if source[index] == '\n':
                        line += 1
                    index += 1
            continue

        possible_string = string_start(source, index)
        if possible_string is not None:
            hashes, multiline, opener_length = possible_string
            index, line = skip_string(
                source, index, line, hashes, multiline, opener_length
            )
            continue

        if character == '`':
            start_line = line
            end = source.find('`', index + 1)
            if end == -1:
                end = len(source)
            value = source[index + 1:end]
            tokens.append(
                Token(value, start_line, 'identifier', parens, brackets, braces, True)
            )
            line += source[index:end + 1].count('\n')
            index = min(end + 1, len(source))
            continue

        if character.isascii() and (character.isalpha() or character == '_'):
            start = index
            start_line = line
            index += 1
            while index < len(source):
                next_character = source[index]
                if not (next_character.isascii() and (next_character.isalnum() or next_character == '_')):
                    break
                index += 1
            tokens.append(
                Token(source[start:index], start_line, 'identifier', parens, brackets, braces)
            )
            continue

        if character in '().[]{}':
            tokens.append(
                Token(character, line, 'symbol', parens, brackets, braces)
            )
            if character == '(':
                parens += 1
            elif character == ')':
                parens = max(0, parens - 1)
            elif character == '[':
                brackets += 1
            elif character == ']':
                brackets = max(0, brackets - 1)
            elif character == '{':
                braces += 1
            elif character == '}':
                braces = max(0, braces - 1)
            index += 1
            continue

        if character == '.':
            tokens.append(Token(character, line, 'symbol', parens, brackets, braces))
        index += 1

    return tokens


IMPORT_KINDS = {'typealias', 'struct', 'class', 'enum', 'protocol', 'var', 'let', 'func'}


def forbidden_imports(source, forbidden):
    tokens = scan_tokens(source)
    results = []
    for index, token in enumerate(tokens):
        if token.kind != 'identifier' or token.escaped or token.value != 'import':
            continue
        if token.parens or token.brackets or token.braces:
            continue

        module_index = index + 1
        if module_index < len(tokens) and tokens[module_index].kind == 'identifier':
            if not tokens[module_index].escaped and tokens[module_index].value in IMPORT_KINDS:
                module_index += 1
        if module_index >= len(tokens):
            continue
        module = tokens[module_index]
        if module.kind != 'identifier' or module.parens or module.brackets or module.braces:
            continue
        root_module = module.value
        if root_module in forbidden:
            results.append((token.line, root_module))
    return results


def access_problem(path, info, directory):
    mode = info.st_mode
    if directory:
        has_read_bits = bool(mode & (stat.S_IRUSR | stat.S_IRGRP | stat.S_IROTH))
        has_search_bits = bool(mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH))
        accessible = os.access(path, os.R_OK | os.X_OK)
        if not has_read_bits or not has_search_bits or not accessible:
            return f'inaccessible source directory: {path}'
    else:
        has_read_bits = bool(mode & (stat.S_IRUSR | stat.S_IRGRP | stat.S_IROTH))
        if not has_read_bits or not os.access(path, os.R_OK):
            return f'inaccessible source file: {path}'
    return None


def source_files(scope, root, findings):
    swift_files = []

    # Do not use recursive glob traversal here: it can silently omit a nested directory when
    # that directory cannot be read.  The explicit stack makes every directory
    # and entry observable, while lstat keeps symlinks out of traversal.
    pending = [root]
    while pending:
        current = pending.pop()
        try:
            current_info = os.lstat(current)
        except OSError as error:
            findings.append(
                f'inaccessible source path in {scope}: {current}: '
                f'{error.strerror or error}'
            )
            continue
        if stat.S_ISLNK(current_info.st_mode):
            findings.append(f'ambiguous source directory symlink in {scope}: {current}')
            continue
        if not stat.S_ISDIR(current_info.st_mode):
            findings.append(f'ambiguous source directory path in {scope}: {current}')
            continue
        problem = access_problem(current, current_info, directory=True)
        if problem is not None:
            findings.append(f'{problem} in {scope}')
            continue

        try:
            with os.scandir(current) as directory_entries:
                entries = sorted(directory_entries, key=lambda entry: entry.name)
        except OSError as error:
            findings.append(
                f'inaccessible source directory in {scope}: {current}: '
                f'{error.strerror or error}'
            )
            continue

        child_directories = []
        for entry in entries:
            path = Path(entry.path)
            try:
                info = os.lstat(path)
            except OSError as error:
                findings.append(
                    f'inaccessible source path in {scope}: {path}: '
                    f'{error.strerror or error}'
                )
                continue

            if stat.S_ISLNK(info.st_mode):
                try:
                    target_info = os.stat(path)
                except OSError:
                    findings.append(f'broken source symlink in {scope}: {path}')
                else:
                    if stat.S_ISDIR(target_info.st_mode):
                        findings.append(f'ambiguous source directory symlink in {scope}: {path}')
                    else:
                        findings.append(f'ambiguous source file symlink in {scope}: {path}')
                continue
            if stat.S_ISDIR(info.st_mode):
                child_directories.append((entry.name, path, info))
                continue
            if not entry.name.endswith('.swift'):
                continue
            if not stat.S_ISREG(info.st_mode):
                findings.append(f'ambiguous source file in {scope}: {path}')
                continue
            problem = access_problem(path, info, directory=False)
            if problem is not None:
                findings.append(f'{problem} in {scope}')
                continue
            swift_files.append((path, info))

        # The stack is LIFO, so reverse the sorted list to visit directories
        # in lexical order and keep findings/file processing deterministic.
        for _, path, _ in reversed(child_directories):
            pending.append(path)

    return sorted(swift_files, key=lambda item: str(item[0]))


def file_identity(info):
    """Return portable identity/content metadata for one discovered file."""
    return (
        info.st_dev,
        info.st_ino,
        info.st_mode,
        info.st_nlink,
        info.st_uid,
        info.st_gid,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


def matches_discovered_file(expected, actual):
    return stat.S_ISREG(actual.st_mode) and file_identity(expected) == file_identity(actual)


def changed_source_file(scope, path, findings):
    findings.append(f'source file changed or became ambiguous during scan in {scope}: {path}')


def read_source_file(scope, path, expected, findings):
    """Read only the same regular file that discovery recorded, fail closed."""
    fd = None
    source = None
    nofollow_available = hasattr(os, 'O_NOFOLLOW')

    try:
        try:
            before_open = os.lstat(path)
        except OSError as error:
            findings.append(
                f'inaccessible source file in {scope}: {path}: '
                f'{error.strerror or error}'
            )
            return None
        if stat.S_ISLNK(before_open.st_mode) or not matches_discovered_file(expected, before_open):
            changed_source_file(scope, path, findings)
            return None
        problem = access_problem(path, before_open, directory=False)
        if problem is not None:
            findings.append(f'{problem} in {scope}')
            return None

        flags = os.O_RDONLY
        if hasattr(os, 'O_CLOEXEC'):
            flags |= os.O_CLOEXEC
        if nofollow_available:
            flags |= os.O_NOFOLLOW
        try:
            fd = os.open(path, flags)
        except OSError as error:
            if nofollow_available and getattr(error, 'errno', None) == errno.ELOOP:
                changed_source_file(scope, path, findings)
            else:
                findings.append(
                    f'inaccessible source file in {scope}: {path}: '
                    f'{error.strerror or error}'
                )
            return None

        opened = os.fstat(fd)
        if not matches_discovered_file(expected, opened):
            changed_source_file(scope, path, findings)
            return None

        # O_NOFOLLOW prevents a final-component symlink on supporting systems.
        # The lstat checks are retained both as a post-open guard and as the
        # fallback protection on systems without O_NOFOLLOW.
        after_open = os.lstat(path)
        if not matches_discovered_file(expected, after_open):
            changed_source_file(scope, path, findings)
            return None

        chunks = []
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)

        after_read = os.fstat(fd)
        after_read_path = os.lstat(path)
        if (not matches_discovered_file(expected, after_read)
                or not matches_discovered_file(expected, after_read_path)):
            changed_source_file(scope, path, findings)
            return None
        problem = access_problem(path, after_read_path, directory=False)
        if problem is not None:
            findings.append(f'{problem} in {scope}')
            return None
        source = b''.join(chunks)
    except OSError as error:
        findings.append(
            f'inaccessible source file in {scope}: {path}: '
            f'{error.strerror or error}'
        )
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError as error:
                findings.append(
                    f'inaccessible source file in {scope}: {path}: '
                    f'could not close descriptor: {error.strerror or error}'
                )
                source = None

    if source is None:
        return None

    # Close before this final path check so a replacement during descriptor
    # teardown is also rejected before the bytes are consumed by the lexer.
    try:
        after_close_path = os.lstat(path)
    except OSError as error:
        findings.append(
            f'inaccessible source file in {scope}: {path}: '
            f'{error.strerror or error}'
        )
        return None
    if not matches_discovered_file(expected, after_close_path):
        changed_source_file(scope, path, findings)
        return None
    return source


def main():
    repo_root = Path(sys.argv[1])
    roots = (
        ('ProtocolKit', repo_root / 'LooprPackages/Sources/ProtocolKit',
         {'CoreBluetooth', 'SQLite', 'SQLite3', 'GRDB', 'HealthKit', 'SwiftUI'}),
        ('StorageKit', repo_root / 'LooprPackages/Sources/StorageKit',
         {'CoreBluetooth', 'SwiftUI'}),
        ('BluetoothKit', repo_root / 'LooprPackages/Sources/BluetoothKit',
         {'SwiftUI'}),
        ('Loopr/Loopr', repo_root / 'Loopr/Loopr',
         {'GRDB', 'SQLite', 'SQLite3'}),
    )

    findings = []
    for scope, root, forbidden in roots:
        try:
            root_info = os.lstat(root)
        except FileNotFoundError:
            findings.append(f'missing required root {scope}: {root}')
            continue
        except OSError as error:
            findings.append(
                f'inaccessible required root {scope}: {root}: '
                f'{error.strerror or error}'
            )
            continue
        if stat.S_ISLNK(root_info.st_mode):
            findings.append(f'ambiguous required root symlink {scope}: {root}')
            continue
        if not stat.S_ISDIR(root_info.st_mode):
            findings.append(f'missing required root {scope}: {root} (not a directory)')
            continue
        problem = access_problem(root, root_info, directory=True)
        if problem is not None:
            findings.append(f'{problem} for required root {scope}')
            continue
        swift_files = source_files(scope, root, findings)
        for swift_file, expected in swift_files:
            source_bytes = read_source_file(scope, swift_file, expected, findings)
            if source_bytes is None:
                continue
            source = source_bytes.decode('utf-8', errors='replace')
            for line, module in forbidden_imports(source, forbidden):
                findings.append(
                    f'{swift_file}:{line}: forbidden import {module} in {scope}'
                )

    if findings:
        for finding in findings:
            print(finding)
        return 1
    print('Forbidden-import check passed.')
    return 0


raise SystemExit(main())
PY
