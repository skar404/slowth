import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ci_scope', ROOT / 'scripts/ci_scope.py')
ci_scope = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci_scope)


def diff(*entries):
    return b''.join(status.encode() + b'\0' + name.encode() + b'\0' for status, name in entries)


class ScopeTests(unittest.TestCase):
    def test_website_changes_skip_app_tests_on_pr_and_push(self):
        changes = diff(('M', 'website/ru/index.html'), ('A', 'website/new page.html'),
                       ('D', 'website/old.html'), ('M', 'scripts/render_slowth.py'),
                       ('M', '.github/workflows/website.yml'))
        for event in ['pull_request', 'push']:
            self.assertEqual(ci_scope.classify(changes, event), {'readme_only': False, 'website_only': True})

    def test_mixed_app_and_ci_changes_always_require_full_checks(self):
        for path in ['Shared/Store.swift', 'WebExt/content.js', 'Localization/locales.json',
                     '.github/workflows/ci.yml', 'scripts/ci_scope.py', 'tests/test_ci_scope.py',
                     'scripts/future_slowth_app.py', 'README.md', 'website-other/page.html']:
            with self.subTest(path=path):
                self.assertFalse(ci_scope.classify(diff(('M', 'website/index.html'), ('M', path)), 'pull_request')['website_only'])

    def test_readme_exception_remains_pr_only_and_modification_only(self):
        self.assertTrue(ci_scope.classify(diff(('M', 'README.md')), 'pull_request')['readme_only'])
        for event, status in [('push', 'M'), ('pull_request', 'A'), ('pull_request', 'D')]:
            self.assertFalse(ci_scope.classify(diff((status, 'README.md')), event)['readme_only'])

    def test_uncertain_input_requires_full_checks(self):
        for raw in [b'', b'M\0website/index.html', b'R100\0website/a\0Shared/a\0', diff(('T', 'website/index.html'))]:
            self.assertEqual(ci_scope.classify(raw, 'pull_request'), {'readme_only': False, 'website_only': False})
        self.assertFalse(ci_scope.classify(diff(('M', 'website/index.html')), 'workflow_dispatch')['website_only'])
        self.assertFalse(ci_scope.detect('push', '0' * 40, 'a' * 40)['website_only'])

    def test_required_gate_rejects_failed_or_missing_checks(self):
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        gate = workflow.rsplit('        run: |\n', 1)[1]
        gate = '\n'.join(line[10:] for line in gate.splitlines())
        base = {'SCOPE': 'success', 'SOURCE': 'skipped', 'WEBKIT': 'skipped',
                'WEBSITE': 'success', 'WEBSITE_ONLY': 'true', 'README_ONLY': 'false'}
        cases = [({}, True), ({'WEBSITE': 'failure'}, False), ({'WEBSITE': 'skipped'}, False),
                 ({'SCOPE': 'failure'}, False), ({'SOURCE': 'failure'}, False),
                 ({'WEBSITE_ONLY': ''}, False),
                 ({'WEBSITE_ONLY': 'false', 'WEBSITE': 'skipped', 'SOURCE': 'success', 'WEBKIT': 'success'}, True),
                 ({'WEBSITE_ONLY': 'false', 'WEBSITE': 'skipped', 'SOURCE': 'success'}, False),
                 ({'WEBSITE_ONLY': 'false', 'WEBSITE': 'skipped', 'SOURCE': 'success', 'README_ONLY': 'true'}, True),
                 ({'WEBSITE_ONLY': 'false', 'WEBSITE': 'skipped', 'SOURCE': 'cancelled'}, False)]
        for changes, passes in cases:
            with self.subTest(changes=changes):
                result = subprocess.run(['/bin/bash', '-e', '-c', gate], env={**base, **changes}, capture_output=True)
                self.assertEqual(result.returncode == 0, passes, result.stdout.decode())

    def test_real_git_rename_out_of_website_cannot_skip_app_checks(self):
        with tempfile.TemporaryDirectory() as tmp:
            def git(*args):
                return subprocess.check_output(['git', '-C', tmp, '-c', 'user.name=CI Test',
                    '-c', 'user.email=ci@example.invalid', '-c', 'commit.gpgsign=false', *args], stderr=subprocess.DEVNULL).decode().strip()
            git('init')
            page = Path(tmp) / 'website' / 'page.html'
            page.parent.mkdir(); page.write_text('page')
            git('add', '.'); git('commit', '-m', 'base'); base = git('rev-parse', 'HEAD')
            page.write_text('changed page')
            git('add', '.'); git('commit', '-m', 'site'); head = git('rev-parse', 'HEAD')
            original_run = subprocess.run
            def run_in_repo(*args, **kwargs):
                return original_run(*args, cwd=tmp, **kwargs)
            with patch.object(ci_scope.subprocess, 'run', side_effect=run_in_repo):
                self.assertTrue(ci_scope.detect('push', base, head)['website_only'])
                target = Path(tmp) / 'Shared'; target.mkdir()
                page.rename(target / 'page.swift')
                git('add', '-A'); git('commit', '-m', 'move to app'); head = git('rev-parse', 'HEAD')
                self.assertFalse(ci_scope.detect('pull_request', base, head)['website_only'])


if __name__ == '__main__':
    unittest.main()
