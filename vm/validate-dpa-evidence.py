#!/usr/bin/env python3
"""Validate P1 DPA evidence files without external Python dependencies."""
import json, sys

def load(path):
    with open(path) as f: return json.load(f)

def main(paths):
    errors=[]
    for path in paths:
        try: doc=load(path)
        except Exception as e: errors.append(f'{path}: invalid JSON: {e}'); continue
        if doc.get('schema_version') == 2:
            # The v2 branch used to be "if status is valid: complain when status
            # is invalid", which cannot fire. Every v2 document passed,
            # including ones this directory's own schema rejects -- a missing
            # coverage object, a coverage that is not an object, an unreadable
            # status with nothing saying what was unreadable. Proved by feeding
            # it those three; all three were accepted.
            #
            # The conditions below are the schema's allOf, applied.
            status = doc.get('status')
            if status not in ('diagnostic', 'unreadable'):
                errors.append(f'{path}: status must be diagnostic or unreadable')
            elif status == 'unreadable':
                if not isinstance(doc.get('unreadable'), list) or not doc['unreadable']:
                    errors.append(f'{path}: unreadable status needs a non-empty unreadable list')
            else:
                if not isinstance(doc.get('coverage'), dict):
                    errors.append(f'{path}: diagnostic status needs a coverage object')
                for k in ('desired', 'programmed', 'matched'):
                    v = doc.get(k)
                    if v is not None and (not isinstance(v, int) or isinstance(v, bool) or v < 0):
                        errors.append(f'{path}: {k} must be a non-negative integer')
        elif isinstance(doc.get('coverage'), dict):
            if doc.get('schema_version') != 1: errors.append(f'{path}: schema_version')
            if not isinstance(doc.get('coverage'),dict): errors.append(f'{path}: coverage')
            if doc.get('read_only') is not True: errors.append(f'{path}: read_only')
        elif isinstance(doc.get('events'), list):
            if doc.get('schema_version') != 1: errors.append(f'{path}: schema_version')
            if doc.get('read_only') is not True: errors.append(f'{path}: read_only')
            if not isinstance(doc.get('events'),list): errors.append(f'{path}: events')
        else:
            if doc.get('status') not in ('diagnostic','unreadable'):
                errors.append(f'{path}: status')
    if errors:
        for e in errors: print('ERROR',e,file=sys.stderr)
        return 1
    print(f'validated {len(paths)} DPA evidence file(s)')
    return 0

if __name__ == '__main__':
    if len(sys.argv)<2: raise SystemExit('usage: validate-dpa-evidence.py FILE...')
    raise SystemExit(main(sys.argv[1:]))
