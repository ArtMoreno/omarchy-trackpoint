"""Find the TrackPoint and edit its Hyprland device settings in input.lua.

An existing hl.device block for the TrackPoint is edited in place, so the
user's own settings stay where they wrote them. Without one, a marked block
is added at the end of input.lua and removed again once it holds nothing but
the device name. Every change is checked with hyprctl configerrors and put
back if Hyprland reports a problem.
"""
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

CONFIG = Path.home() / '.config/hypr/input.lua'
BEGIN = '-- BEGIN io.github.artmoreno.trackpoint device (managed by the TrackPoint bar widget)'
END = '-- END io.github.artmoreno.trackpoint device'
MANAGED = re.compile(r'\n*' + re.escape(BEGIN) + r'\n.*?' + re.escape(END) + r'\n?', re.S)
DEVICE_BLOCK = re.compile(r'hl\.device\s*\(\s*\{(?P<body>.*?)\}\s*\)', re.S)
VALUE = r'("(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?|true|false)'
_lock_depth = 0


@contextmanager
def transaction():
    """Serialize plugin reads, writes, validation and rollback across processes."""
    global _lock_depth
    if _lock_depth:
        _lock_depth += 1
        try:
            yield
        finally:
            _lock_depth -= 1
        return
    # Lock a stable sidecar, not input.lua's inode (atomic writes replace it).
    with (CONFIG.parent / '.trackpoint-config.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        _lock_depth = 1
        try:
            yield
        finally:
            _lock_depth = 0
            fcntl.flock(lock, fcntl.LOCK_UN)


def _without_comments(text, mask_strings=False):
    """Mask Lua comments (and optionally strings), preserving source offsets."""
    token = re.compile(r'''("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\[(=*)\[|--\[(=*)\[|--[^\n]*)''', re.S)
    result = list(text)
    pos = 0
    while match := token.search(text, pos):
        start, end = match.span()
        raw = match[0]
        if raw.startswith('--[') or raw.startswith('['):
            equals = match[3] if raw.startswith('--') else match[2]
            closing = ']' + equals + ']'
            close = text.find(closing, end)
            end = len(text) if close < 0 else close + len(closing)
        if raw.startswith('--') or mask_strings:
            result[start:end] = ['\n' if c == '\n' else ' ' for c in text[start:end]]
        pos = end
    return ''.join(result)


def detect_device():
    out = subprocess.run(['hyprctl', 'devices', '-j'], capture_output=True, text=True, check=True, timeout=5).stdout
    names = [mouse.get('name', '') for mouse in json.loads(out).get('mice', [])]
    matches = [name for name in names if 'trackpoint' in name.lower()]
    if not matches:
        raise RuntimeError('No TrackPoint found. This widget needs a ThinkPad-style TrackPoint.')
    return matches[0]


def _read():
    try:
        return CONFIG.read_text()
    except FileNotFoundError:
        raise RuntimeError(f'{CONFIG} not found.') from None


def _blocks(text, device):
    found = []
    # Structural matches must not see examples or punctuation inside strings.
    for match in DEVICE_BLOCK.finditer(_without_comments(text, mask_strings=True)):
        body = text[match.start('body'):match.end('body')]
        name = _find_field(body, 'name')
        if name and _parse(name[1]) == device:
            found.append(match)
    if len(found) > 1:
        raise RuntimeError(f'Found {len(found)} hl.device blocks for {device} in input.lua; expected one.')
    return found[0] if found else None


def _field(key):
    return re.compile(r'(?<![\w.])' + re.escape(key) + r'\s*=\s*' + VALUE + r'(?=\s*(?:,|$))')


def _find_field(body, key):
    code = _without_comments(body)
    structure = _without_comments(body, mask_strings=True)
    assignments = list(re.finditer(r'(?<![\w.])' + re.escape(key) + r'\s*=', structure))
    field = _field(key).match(code, assignments[0].start()) if assignments else None
    if len(assignments) > 1 or (assignments and field is None):
        raise RuntimeError(f'Cannot safely edit {key}: use one literal value in the TrackPoint block.')
    return field


def _parse(raw):
    if raw.startswith('"'):
        return json.loads(raw)
    if raw in ('true', 'false'):
        return raw == 'true'
    return float(raw)


def get_value(device, key):
    """Return the configured value for key, or None when it isn't set."""
    with transaction():
        text = _read()
        block = _blocks(text, device)
        if block is None:
            return None
        field = _find_field(text[block.start('body'):block.end('body')], key)
        return _parse(field[1]) if field else None


def _edit_body(body, key, literal):
    field = _find_field(body, key)
    if field:
        start, end = field.span()
        if literal is None:
            # A separator can follow an inline/long comment or a newline.
            tail = _without_comments(body[end:])
            separator = re.match(r'\s*,', tail)
            end += separator.end() if separator else re.match(r'[ \t]*', tail).end()
            removed = body[start:end]
            masked = _without_comments(removed)
            line_tail = body[end:].split('\n', 1)[0]
            if removed != masked or line_tail != _without_comments(line_tail):
                # Keep comments between the key, value and separator in place.
                comments = ''.join(c for i, c in enumerate(removed)
                                   if c.isspace() or c != masked[i])
                return body[:start] + comments + body[end:]
            start = re.search(r'\n?[ \t]*$', body[:start]).start()
            return body[:start] + body[end:]
        start, end = field.span(1)
        return body[:start] + literal + body[end:]
    if literal is None:
        return body
    # Add a missing separator before a trailing comment, not inside it.
    code = _without_comments(body).rstrip()
    if code and not code.endswith(','):
        body = body[:len(code)] + ',' + body[len(code):]
    stripped = body.rstrip()
    if '\n' in body:
        indent = re.search(r'\n([ \t]*)\S', body)
        return f'{stripped}\n{indent[1] if indent else "  "}{key} = {literal},\n'
    return f'{stripped} {key} = {literal} '


def set_values(device, values):
    """Set each key to a Lua literal, or remove it when the literal is None."""
    with transaction():
        _set_values(device, values)


def _set_values(device, values):
    original = _read()
    text = original
    for key, literal in values.items():
        block = _blocks(text, device)
        if block is None:
            if literal is None:
                continue
            text = (text.rstrip('\n') + f'\n\n{BEGIN}\nhl.device({{\n  name = {json.dumps(device)},\n'
                    f'  {key} = {literal},\n}})\n{END}\n')
            continue
        body = _edit_body(text[block.start('body'):block.end('body')], key, literal)
        text = text[:block.start('body')] + body + text[block.end('body'):]

    # Drop the plugin's own block once only the device name is left in it
    block = _blocks(text, device)
    if block:
        for managed in MANAGED.finditer(text):
            # Match against the full source so marker examples inside strings
            # cannot turn into a device block when their surrounding text is cut.
            if not managed.start() <= block.start() < block.end() <= managed.end():
                continue
            fields = re.findall(r'(?<![\w.])(\w+)\s*=', block['body'])
            if set(fields) <= {'name'}:
                text = text[:managed.start()] + '\n' + text[managed.end():]
                text = text.rstrip('\n') + '\n'
            break

    if text != original:
        _write_checked(text, original)


def _replace_config(text):
    # Preserve symlinks and file permissions; readers never see a partial file.
    path = CONFIG.resolve()
    mode = path.stat().st_mode & 0o777
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as out:
            temporary = Path(out.name)
            os.fchmod(out.fileno(), mode)
            out.write(text)
            out.flush()
            os.fsync(out.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def _write_checked(text, original):
    _replace_config(text)
    try:
        subprocess.run(['hyprctl', 'reload', 'config-only'], capture_output=True, text=True, check=True, timeout=5)
        errors = subprocess.run(['hyprctl', 'configerrors'], capture_output=True, text=True, check=True, timeout=5).stdout.strip()
        if errors:
            raise RuntimeError(errors)
    except Exception as exc:
        # Hyprland keeps running on a broken config, so put the file back.
        _replace_config(original)
        try:
            subprocess.run(['hyprctl', 'reload', 'config-only'], capture_output=True, text=True, check=True, timeout=5)
        except Exception as rollback:
            raise RuntimeError(f'{exc}; original config restored, but reload failed: {rollback}') from exc
        raise
