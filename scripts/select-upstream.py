#!/usr/bin/env python3
"""Join public source snapshots to stable npm versions without passing latest."""
import json
import re
import subprocess
import sys
import tomllib


def version_key(value):
    return tuple(map(int, value.split('.'))) if re.fullmatch(r'\d+\.\d+\.\d+', value) else None


def select(candidates, published, latest):
    ceiling = version_key(latest)
    if ceiling is None:
        raise ValueError('npm latest must be a stable version')
    eligible = [(version_key(version), version, ref) for version, ref in candidates
                if version in published and version_key(version) is not None
                and version_key(version) <= ceiling]
    if not eligible:
        raise ValueError(f'no public source snapshot matches a published stable version at or below {latest}')
    # Candidates are newest-first; retain the newest sync for duplicate versions.
    _, version, ref = max(eligible, key=lambda item: item[0])
    return version, ref


def main():
    repo, latest = sys.argv[1:]
    published = set(json.load(sys.stdin))
    refs = subprocess.check_output(['git', '-C', repo, 'rev-list', 'FETCH_HEAD'], text=True).splitlines()
    candidates = []
    for ref in refs:
        result = subprocess.run(['git', '-C', repo, 'show', f'{ref}:crates/codegen/xai-grok-version/Cargo.toml'],
                                capture_output=True, text=True)
        if result.returncode == 0:
            candidates.append((tomllib.loads(result.stdout)['package']['version'], ref))
    print(*select(candidates, published, latest))


if __name__ == '__main__':
    main()
