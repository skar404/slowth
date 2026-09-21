#!/usr/bin/env python3
"""Run verify_webkit_localization.swift's executable in a new process per locale.
Usage: python3 scripts/verify_webkit_localizations.py /tmp/slowth-webkit-l10n /tmp/slowth-l10n-qa
This invokes real WebKit with process-local AppleLanguages; no system defaults change.
"""
import json
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
executable, output = sys.argv[1:3]
failures = []
for path in sorted((root / 'WebExt/_locales').glob('*/messages.json')):
    locale = json.loads(path.read_text())['locale']['message']
    proc = subprocess.run([executable, str(root / 'WebExt'), locale, output, '320', 'blocked', '-AppleLanguages', f'({locale})'], capture_output=True, text=True, timeout=45)
    print(f'{locale}: {proc.stdout.strip()} {proc.stderr.strip()}', flush=True)
    if proc.returncode:
        failures.append(locale)
proc = subprocess.run([executable, str(root / 'WebExt'), 'en', output, '320', 'blocked', '-AppleLanguages', '(zz)'], capture_output=True, text=True, timeout=45)
print('Fallback:', proc.stdout.strip(), proc.stderr.strip())
if proc.returncode:
    failures.append('English fallback')
if failures:
    raise SystemExit('Failed locale selections: ' + ', '.join(failures))
print('All 46 WebKit locale selections + English fallback passed')
