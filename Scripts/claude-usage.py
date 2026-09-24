#!/usr/bin/python3
"""Read Claude Code's interactive /usage display; never read its credentials."""
import codecs
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
from zoneinfo import ZoneInfo

EPOCH = 978307200


class Screen:
    """Small VT reader for Claude's flat --ax-screen-reader output."""
    def __init__(self):
        self.rows = [[]]
        self.row = self.col = 0
        self.pending = ''

    def feed(self, text):
        text = self.pending + text
        self.pending = ''
        i = 0
        while i < len(text):
            c = text[i]
            if c == '\x1b':
                rest = text[i:]
                if len(rest) < 2:
                    self.pending = rest
                    break
                if rest[1] == '[':
                    m = re.match(r'\x1b\[([0-?]*)([ -/]*)([@-~])', rest)
                    if not m:
                        self.pending = rest
                        break
                    args, _, op = m.groups()
                    n = int(args or '1') if (args or '1').isdigit() else 1
                    if op == 'A': self.row = max(0, self.row - n)
                    elif op == 'B': self.row += n
                    elif op == 'C': self.col += n
                    elif op == 'D': self.col = max(0, self.col - n)
                    elif op == 'G': self.col = max(0, n - 1)
                    elif op in ('H', 'f'):
                        values = (args or '1;1').split(';')
                        self.row = max(0, int(values[0] or 1) - 1)
                        self.col = max(0, int(values[1] or 1) - 1) if len(values) > 1 else 0
                    elif op == 'K':
                        self.ensure()
                        if args == '2': self.rows[self.row] = []
                        else: self.rows[self.row] = self.rows[self.row][:self.col]
                    elif op == 'J' and args == '2':
                        self.rows = [[]]
                        self.row = self.col = 0
                    i += len(m[0]); continue
                if rest[1] == ']':
                    m = re.search(r'\x07|\x1b\\', rest)
                    if not m:
                        self.pending = rest
                        break
                    i += m.end(); continue
                if rest[1] in '()':
                    if len(rest) < 3:
                        self.pending = rest
                        break
                    i += 3; continue
                i += 2; continue
            if c == '\r': self.col = 0
            elif c == '\n': self.row += 1; self.col = 0
            elif c >= ' ' and c != '\x7f':
                self.ensure()
                row = self.rows[self.row]
                while len(row) <= self.col: row.append(' ')
                row[self.col] = c
                self.col += 1
            i += 1
        if self.row > 4000 or self.col > 10000 or len(self.pending) > 65536:
            raise ValueError('Terminal output exceeded bounds')

    def ensure(self):
        while len(self.rows) <= self.row: self.rows.append([])

    def text(self):
        return '\n'.join(''.join(row).rstrip() for row in self.rows)


def reset_date(text, now):
    m = re.fullmatch(r'Resets (.+) \(([^)]+)\)', text.strip())
    if not m: raise ValueError('Unsupported reset date')
    value, zone = m.groups()
    local = dt.datetime.fromtimestamp(now, ZoneInfo(zone))
    day = local.date()
    if value.startswith('tomorrow '):
        day += dt.timedelta(days=1); value = value[9:]
    elif ' at ' in value:
        date, value = value.split(' at ', 1)
        day = dt.datetime.strptime(f'{date} {local.year}', '%b %d %Y').date()
        if day < local.date(): day = day.replace(year=day.year + 1)
    clock = None
    for fmt in ('%I:%M%p', '%I%p'):
        try: clock = dt.datetime.strptime(value.upper(), fmt).time(); break
        except ValueError: pass
    if clock is None: raise ValueError('Unsupported reset time')
    result = dt.datetime.combine(day, clock, tzinfo=local.tzinfo)
    if result.timestamp() <= now: result += dt.timedelta(days=1)
    return result.timestamp() - EPOCH


def parse_screen(text, now):
    if 'Refreshing' in text: raise ValueError('Still refreshing')
    result = {'updatedAt': now - EPOCH}
    for title, key in [('Current session', 'fiveHour'), ('Current week (all models)', 'sevenDay')]:
        m = re.search(re.escape(title) + r'\s*\n[^\n]*?([\d.]+)% used\s*\n(Resets [^\n]+)', text)
        if not m: raise ValueError('Missing usage window')
        percent = float(m[1])
        if not 0 <= percent <= 100: raise ValueError('Invalid percentage')
        result[key] = {'utilization': percent, 'resetsAt': reset_date(m[2], now)}
    return result


def fetch(workdir, executable, timeout=50):
    fd, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 80, 160, 0, 0))
    env = {k: v for k, v in os.environ.items() if not k.startswith(('ANTHROPIC_', 'CLAUDE_', 'AWS_', 'AZURE_', 'GOOGLE_'))}
    env.update(TERM='xterm-256color', LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8', DISABLE_AUTOUPDATER='1')
    try:
        process = subprocess.Popen([executable, '--safe-mode', '--tools', '', '--permission-mode', 'dontAsk', '--ax-screen-reader'],
                                   cwd=workdir, env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
    except Exception:
        os.close(fd)
        raise
    finally:
        os.close(slave)
    pid = process.pid
    screen = Screen()
    decoder = codecs.getincrementaldecoder('utf-8')('replace')
    deadline = time.monotonic() + timeout
    sent = refreshing = trusted = False
    total = 0
    recent = ''
    last_output = time.monotonic()
    try:
        while time.monotonic() < deadline:
            if select.select([fd], [], [], 0.2)[0]:
                data = os.read(fd, 65536)
                if not data: raise ValueError('CLI exited')
                total += len(data)
                if total > 1048576: raise ValueError('Too much output')
                chunk = decoder.decode(data)
                recent = (recent + chunk)[-65536:]
                if sent and 'Refreshing' in recent: refreshing = True
                screen.feed(chunk)
                last_output = time.monotonic()
                text = screen.text()
                if not trusted and 'Enter y/n:' in text and str(workdir) in text and 'Accessing workspace:' in text:
                    os.write(fd, b'y\r'); trusted = True
                if not sent and re.search(r'\n\$\s*$', text):
                    os.write(fd, b'/usage\r'); sent = True
                if sent and 'Refreshing' in text: refreshing = True
            text = screen.text()
            if sent and refreshing and 'Refreshing' not in text and 'Esc to cancel' in text and time.monotonic() - last_output > 1:
                return parse_screen(text, time.time())
        raise TimeoutError(f'Usage refresh did not complete (sent={sent}, refreshing={refreshing}, trusted={trusted})')
    finally:
        # Terminate the isolated CLI session and any children even on timeout.
        try: os.killpg(pid, signal.SIGTERM)
        except ProcessLookupError: pass
        try: process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            try: os.killpg(pid, signal.SIGKILL)
            except ProcessLookupError: pass
            try: process.wait(timeout=2)
            except subprocess.TimeoutExpired: pass
        os.close(fd)


def main():
    destination = Path(sys.argv[1])
    background = sys.argv[2] == 'poll'
    workdir = Path.home() / 'Library/Application Support/AI Usage/ClaudeUsage'
    workdir.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (workdir / 'usage.lock').open('a') as lock:
        try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: return
        try: previous = json.loads(destination.read_text())
        except (OSError, ValueError): previous = {}
        if background and previous.get('nextAttempt', 0) > time.time(): return
        try:
            executable = next((p for p in [str(Path.home()/'.local/bin/claude'), '/opt/homebrew/bin/claude', '/usr/local/bin/claude'] if os.access(p, os.X_OK)), None)
            if not executable: raise FileNotFoundError('Claude Code missing')
            result = fetch(workdir, executable)
        except Exception:
            result = {k: previous[k] for k in ('fiveHour', 'sevenDay', 'updatedAt') if k in previous}
            result.update(error='Claude usage could not refresh. Open Claude Code, check sign-in, then try Refresh.', nextAttempt=time.time() + 900)
        destination.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(dir=destination.parent, prefix='.claude-usage-')
        try:
            with os.fdopen(fd, 'w') as output: json.dump(result, output)
            os.replace(temporary, destination)
        finally:
            if os.path.exists(temporary): os.unlink(temporary)
        print('Claude usage updated.' if 'error' not in result else result['error'])
        return 1 if 'error' in result else 0


if __name__ == '__main__': sys.exit(main() or 0)
