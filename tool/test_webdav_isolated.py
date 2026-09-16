#!/usr/bin/env python3
"""Run backup and local identity regressions in fresh Flutter processes, retaining every assertion."""
import pathlib
import subprocess
import sys


def main():
    root = pathlib.Path(__file__).resolve().parents[1]
    tests = root / 'test'
    files = sorted(set([
        *tests.glob('webdav*_test.dart'),
        *tests.glob('*sync*_test.dart'),
        tests / 'txt_edit_reference_service_test.dart',
    ]))
    failed = []
    for file in files:
        name = str(file.relative_to(root))
        print(f'\nStateful widget tests / Core Flutter validation: {name}', flush=True)
        try:
            result = subprocess.run(
                ['flutter', 'test', '--no-pub', name, '--reporter', 'expanded'],
                cwd=root, timeout=180, check=False,
            )
            if result.returncode:
                failed.append(name)
        except subprocess.TimeoutExpired:
            failed.append(name)
            print(f'Test process timed out: {name}', flush=True)
    print(f'Isolated backup and local-data suites: {len(files)}, failed: {len(failed)}', flush=True)
    for name in failed:
        print(f'FAILED: {name}', flush=True)
    return bool(failed)


if __name__ == '__main__':
    sys.exit(main())
