"""Regression checks for the CLI display parser; no account or network needed."""
import importlib.util
from pathlib import Path
import unittest
import tempfile
import time
import os

spec = importlib.util.spec_from_file_location('collector', Path(__file__).resolve().parents[1] / 'Scripts/claude-usage.py')
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)

DISPLAY = '''Session
Total cost: $0.0000
Current session
0% 0% used
Resets 1am (America/Chicago)
Current week (all models)
15% 15% used
Resets Sep 29 at 1:59am (America/Chicago)
Usage credits
Usage credits are off
Esc to cancel'''

class Checks(unittest.TestCase):
    def test_pty_refresh_and_timeout(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / 'fake-claude'
            executable.write_text('#!/usr/bin/python3\nimport sys,time\nprint("\\n$",flush=True)\nassert input().strip()=="/usage"\nprint("Refreshing…",flush=True)\ntime.sleep(.2)\nprint("\\x1b[2J\\x1b[H"+' + repr(DISPLAY) + ',flush=True)\ntime.sleep(20)\n')
            executable.chmod(0o700)
            result = c.fetch(Path(directory), str(executable), timeout=4)
            self.assertEqual(result['sevenDay']['utilization'], 15)
            executable.write_text('#!/usr/bin/python3\nimport time\ntime.sleep(20)\n')
            start = time.monotonic()
            with self.assertRaises(TimeoutError):
                c.fetch(Path(directory), str(executable), timeout=.3)
            self.assertLess(time.monotonic() - start, 5)

    def test_windows(self):
        result = c.parse_screen(DISPLAY, 1790211600)
        self.assertEqual(result['sevenDay']['utilization'], 15)
        self.assertEqual(result['fiveHour']['utilization'], 0)
        self.assertGreater(result['fiveHour']['resetsAt'], result['updatedAt'])
        self.assertEqual(set(result), {'updatedAt', 'fiveHour', 'sevenDay'})

    def test_reject_incomplete(self):
        for value in [DISPLAY + '\nRefreshing…', DISPLAY.replace('15% used','115% used'), DISPLAY.replace('Current session', 'Other'), DISPLAY.replace('1am', 'garbage')]:
            with self.assertRaises(ValueError): c.parse_screen(value, 1790211600)

    def test_terminal_redraw_and_split_sequences(self):
        screen = c.Screen()
        for part in ['Current week\r\n14% used\r\nRefreshing…', '\x1b[', '2K\rUsage credits', '\x1b[1A\r\x1b[2K15% used']:
            screen.feed(part)
        self.assertIn('15% used', screen.text())
        self.assertNotIn('14% used', screen.text())
        self.assertNotIn('Refreshing', screen.text())

    def test_control_sequences_not_saved(self):
        screen = c.Screen()
        for part in ['\x1b]0;private ', 'title\x07', '\x1b[31mhello\x1b[0m']:
            screen.feed(part)
        self.assertEqual(screen.text(), 'hello')

if __name__ == '__main__': unittest.main()
