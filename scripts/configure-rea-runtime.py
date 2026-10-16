"""Bind the installed REA server to the compatible Node runtime only."""
from pathlib import Path
import re
import tomllib

config = Path('/Users/gaoxs/.codex/config.toml')
text = config.read_text()
parsed = tomllib.loads(text)
server = parsed['mcp_servers']['rea']
launcher = '/Users/gaoxs/Documents/project/paste/.tools/rea/node_modules/rea-agents/scripts/rea.mjs'
runtime = '/Users/gaoxs/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node'
if server['command'] == runtime and server['args'] == [launcher, 'mcp']:
    print('REA already uses the compatible Node runtime.')
else:
    if server['command'] != launcher or server['args'] != ['mcp']:
        raise SystemExit('Unexpected REA registration; refusing to replace it.')
    match = re.search(r'(?ms)^\[mcp_servers\.rea\]\n.*?(?=^\[|\Z)', text)
    if match is None:
        raise SystemExit('REA section not found.')
    section = match.group(0)
    section = re.sub(r'(?m)^command\s*=.*$', f'command = "{runtime}"', section)
    section = re.sub(r'(?m)^args\s*=.*$', f'args = [ "{launcher}", "mcp" ]', section)
    updated = text[:match.start()] + section + text[match.end():]
    expected = {**parsed, 'mcp_servers': {**parsed['mcp_servers'], 'rea': {**server, 'command': runtime, 'args': [launcher, 'mcp']}}}
    if tomllib.loads(updated) != expected:
        raise SystemExit('Unexpected configuration difference.')
    backup = config.with_name(config.name + '.rea-runtime.backup')
    if not backup.exists():
        backup.write_text(text)
        backup.chmod(0o600)
    config.write_text(updated)
    if tomllib.loads(config.read_text()) != expected:
        raise SystemExit('Configuration readback failed.')
    print('REA runtime configured; all unrelated settings preserved.')
