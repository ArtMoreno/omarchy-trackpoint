"""Exercise the real helpers against temporary configs and a fake compositor."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
DEVICE = 'tpps/2-elan-trackpoint'
spec = importlib.util.spec_from_file_location('hypr_input', ROOT / 'hypr_input.py')
hypr_input = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hypr_input)

FAKE_HYPRCTL = '''#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
if sys.argv[1] == 'devices':
    print(json.dumps({'mice': [{'name': 'tpps/2-elan-trackpoint'}]}))
elif sys.argv[1] == 'reload' and os.environ.get('RELOAD_GATE'):
    gate = Path(os.environ['RELOAD_GATE'])
    gate.with_suffix('.entered').touch()
    deadline = time.monotonic() + 4
    while not gate.exists():
        if time.monotonic() > deadline:
            sys.exit('test gate timed out')
        time.sleep(0.01)
elif sys.argv[1] == 'configerrors' and os.environ.get('FAIL_CONFIG'):
    print('injected validation error')
'''


class ControlTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.config = self.home / '.config/hypr/input.lua'
        self.config.parent.mkdir(parents=True)
        self.original = (f'hl.device({{\n  name = "{DEVICE}",\n'
                         '  sensitivity = 0.25,\n  scroll_method = "no_scroll",\n})\n')
        self.config.write_text(self.original)
        (self.config.parent / 'bindings.lua').write_text('-- bindings\n')
        binary = self.home / 'bin/hyprctl'
        binary.parent.mkdir()
        binary.write_text(FAKE_HYPRCTL)
        binary.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home),
                        XDG_STATE_HOME=str(self.home / 'state'),
                        PATH=str(binary.parent) + os.pathsep + os.environ['PATH'])
        self.addCleanup(patch.stopall)
        patch.object(hypr_input, 'CONFIG', self.config).start()

    def start(self, *args, script='control.py', **env):
        process = subprocess.Popen([sys.executable, str(ROOT / script), *args],
                                   env=dict(self.env, **env), text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        def cleanup():
            if process.poll() is None:
                process.kill()
            process.communicate()
        self.addCleanup(cleanup)
        return process

    def result(self, process, code=0):
        out, err = process.communicate(timeout=10)
        self.assertEqual(process.returncode, code, (out, err))
        return json.loads(out)

    def call(self, *args):
        return self.result(self.start(*args))

    def wait_for_gate(self, gate):
        deadline = time.monotonic() + 4
        while not gate.with_suffix('.entered').exists():
            if time.monotonic() > deadline:
                self.fail('first writer never reached validation')
            time.sleep(0.01)

    def test_off_on_preserves_existing_settings_and_json(self):
        self.assertEqual(self.call('off'), {'device': DEVICE, 'enabled': False, 'value': 0.25})
        self.assertTrue(self.call('on')['enabled'])
        self.assertEqual(self.config.read_text(), self.original)
        self.assertEqual(self.call('0.6')['value'], 0.6)
        self.assertEqual(self.call('0')['value'], 0)
        self.assertNotIn('sensitivity =', self.config.read_text())

    def test_managed_block_cleanup(self):
        self.config.write_text('-- base\n')
        self.assertFalse(self.call('off')['enabled'])
        self.assertIn(hypr_input.BEGIN, self.config.read_text())
        self.assertTrue(self.call('on')['enabled'])
        self.assertEqual(self.config.read_text(), '-- base\n')

    def test_toggle_reads_current_config(self):
        self.call('off')
        self.assertTrue(self.call('toggle')['enabled'])
        self.assertFalse(self.call('toggle')['enabled'])

    def test_invalid_sensitivity_does_not_write(self):
        for arg in ('nan', 'inf', '2', '-2', 'bad'):
            with self.subTest(arg=arg):
                self.assertIn('error', self.result(self.start(arg), code=1))
                self.assertEqual(self.config.read_text(), self.original)

    def test_rollback_restores_original(self):
        error = self.result(self.start('off', FAIL_CONFIG='1'), code=1)
        self.assertIn('injected validation error', error['error'])
        self.assertEqual(self.config.read_text(), self.original)

    def test_symlink_and_permissions_survive_write_and_rollback(self):
        target = self.home / 'real-input.lua'
        self.config.rename(target)
        self.config.symlink_to(target)
        target.chmod(0o640)
        self.call('off')
        self.result(self.start('on', FAIL_CONFIG='1'), code=1)
        self.assertTrue(self.config.is_symlink())
        self.assertEqual(target.stat().st_mode & 0o777, 0o640)
        self.assertFalse(self.call()['enabled'])

    def test_comments_are_preserved_and_never_treated_as_values(self):
        text = (f'-- hl.device({{ name = "{DEVICE}", enabled = false }})\n'
                f'hl.device({{\n  name = "{DEVICE}",\n'
                '  -- enabled = true,\n  --[=[ enabled = false, }) ]=]\n'
                '  sensitivity = 0.25 -- trailing comment\n})\n')
        self.config.write_text(text)
        self.assertTrue(self.call()['enabled'])
        self.assertFalse(self.call('off')['enabled'])
        self.assertIn('-- enabled = true,', self.config.read_text())
        self.assertIn('sensitivity = 0.25, -- trailing comment', self.config.read_text())
        self.assertTrue(self.call('on')['enabled'])
        self.assertIn('--[=[ enabled = false, }) ]=]', self.config.read_text())

    def test_strings_are_not_device_blocks_or_fields(self):
        example = (f"local example = 'hl.device({{ name = \"{DEVICE}\", enabled = false }})'\n"
                   f'local long_example = [=[hl.device({{ name = "{DEVICE}", enabled = false }})]=]\n')
        text = example + self.original
        self.config.write_text(text)
        self.assertTrue(self.call()['enabled'])
        self.assertFalse(self.call('off')['enabled'])
        self.assertTrue(self.call('on')['enabled'])
        self.assertEqual(self.config.read_text(), text)
        body = ' name = "example", note = "enabled = false, })", enabled = true, '
        field = hypr_input._find_field(body, 'enabled')
        self.assertEqual(field[1], 'true')
        self.assertEqual(hypr_input._edit_body(body, 'enabled', 'false'),
                         body.replace('enabled = true', 'enabled = false'))

    def test_managed_marker_examples_never_removed(self):
        example = (f'local example = [=[\n{hypr_input.BEGIN}\n'
                   f'hl.device({{ name = "{DEVICE}", enabled = false }})\n'
                   f'{hypr_input.END}\n]=]\n')
        self.config.write_text(example)
        self.assertTrue(self.call()['enabled'])
        self.assertFalse(self.call('off')['enabled'])
        self.assertTrue(self.call('on')['enabled'])
        self.assertEqual(self.config.read_text(), example)

    def test_comments_between_field_tokens_and_separator_survive(self):
        text = (f'hl.device({{\n  name = "{DEVICE}",\n'
                '  enabled -- keep key comment\n = --[[keep value comment]] true'
                ' -- keep trailing comment\n , sensitivity = 0.25,\n})\n')
        self.config.write_text(text)
        self.assertFalse(self.call('off')['enabled'])
        for comment in ('-- keep key comment', '--[[keep value comment]]',
                        '-- keep trailing comment'):
            self.assertIn(comment, self.config.read_text())
        self.assertTrue(self.call('on')['enabled'])
        updated = self.config.read_text()
        for comment in ('-- keep key comment', '--[[keep value comment]]',
                        '-- keep trailing comment'):
            self.assertIn(comment, updated)
        code = hypr_input._without_comments(updated)
        self.assertNotRegex(code, r',\s*,')
        self.assertNotIn('enabled', code)
        self.assertEqual(self.call()['value'], 0.25)

    def test_ambiguous_or_dynamic_enabled_is_rejected_without_write(self):
        for fields in ('enabled = enabled_elsewhere,', 'enabled = true, enabled = false,'):
            with self.subTest(fields=fields):
                text = f'hl.device({{ name = "{DEVICE}", {fields} }})\n'
                self.config.write_text(text)
                self.assertIn('Cannot safely edit enabled', self.result(self.start('off'), code=1)['error'])
                self.assertEqual(self.config.read_text(), text)

    def test_unreadable_sensitivity_fails_before_disabling(self):
        text = self.original.replace('sensitivity = 0.25', 'sensitivity = custom_value')
        self.config.write_text(text)
        self.assertIn('error', self.result(self.start('off'), code=1))
        self.assertEqual(self.config.read_text(), text)

    def test_concurrent_sensitivity_then_enable_preserves_both(self):
        self.call('off')
        gate = self.home / 'release'
        first = self.start('0.6', RELOAD_GATE=str(gate))
        self.wait_for_gate(gate)
        second = self.start('on')
        # The second process must wait while the first owns validation/rollback.
        with self.assertRaises(subprocess.TimeoutExpired):
            second.wait(timeout=0.15)
        gate.touch()
        self.result(first)
        self.assertTrue(self.result(second)['enabled'])
        self.assertEqual(self.call(), {'device': DEVICE, 'enabled': True, 'value': 0.6})

    def test_rollback_cannot_clobber_following_enable(self):
        self.call('off')
        gate = self.home / 'release'
        first = self.start('0.6', RELOAD_GATE=str(gate), FAIL_CONFIG='1')
        self.wait_for_gate(gate)
        second = self.start('on')
        with self.assertRaises(subprocess.TimeoutExpired):
            second.wait(timeout=0.15)
        gate.touch()
        self.result(first, code=1)
        self.result(second)
        self.assertEqual(self.call(), {'device': DEVICE, 'enabled': True, 'value': 0.25})

    def test_concurrent_toggles_cancel_each_other(self):
        gate = self.home / 'release'
        first = self.start('toggle', RELOAD_GATE=str(gate))
        self.wait_for_gate(gate)
        second = self.start('toggle')
        with self.assertRaises(subprocess.TimeoutExpired):
            second.wait(timeout=0.15)
        gate.touch()
        self.assertFalse(self.result(first)['enabled'])
        self.assertTrue(self.result(second)['enabled'])
        self.assertTrue(self.call()['enabled'])

    def test_middle_button_uses_same_transaction(self):
        self.config.write_text(self.original.replace('  scroll_method = "no_scroll",\n', ''))
        self.call('off')
        gate = self.home / 'release'
        first = self.start('enable', script='middle.py', RELOAD_GATE=str(gate))
        self.wait_for_gate(gate)
        second = self.start('on')
        with self.assertRaises(subprocess.TimeoutExpired):
            second.wait(timeout=0.15)
        gate.touch()
        self.assertTrue(self.result(first)['enabled'])
        self.assertTrue(self.result(second)['enabled'])
        self.assertIn('scroll_method = "no_scroll"', self.config.read_text())


if __name__ == '__main__':
    unittest.main()
