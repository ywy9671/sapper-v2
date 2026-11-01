#!/usr/bin/env python3
"""Run the official Pi CLI using Sapper's configured gateway and task state."""
import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit
from urllib.request import ProxyHandler, Request, build_opener

HERE = Path(__file__).resolve().parent
STATE = Path(os.environ.get('SAPPER_STATE_ROOT', '/work/runs/.general'))

def configure(model):
    for key in ('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy', 'NODE_USE_ENV_PROXY'):
        os.environ.pop(key, None)
    base = os.environ.get('ANTHROPIC_BASE_URL', '').rstrip('/')
    parsed = urlsplit(base)
    if parsed.scheme not in ('http', 'https') or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise RuntimeError('Invalid configured gateway URL')
    if not os.environ.get('ANTHROPIC_AUTH_TOKEN'):
        raise RuntimeError('Configured gateway token is missing')
    configured_model = os.environ.get('SAPPER_MODEL', '')
    if configured_model and model != configured_model:
        raise RuntimeError('Requested model differs from the configured Sapper model')
    if not base.endswith('/v1'):
        base += '/v1'
    context_window, max_tokens = 65536, 4096
    try:
        request = Request(base + '/models', headers={'Authorization': 'Bearer ' + os.environ['ANTHROPIC_AUTH_TOKEN']})
        with build_opener(ProxyHandler({})).open(request, timeout=3) as response:
            catalog = json.load(response)
        entry = next((item for item in catalog.get('data', []) if item.get('id') == model), {})
        context = entry.get('context_length')
        maximum = entry.get('max_output_tokens')
        if isinstance(context, int) and 4096 <= context <= 2000000:
            context_window = context
        if isinstance(maximum, int) and maximum > 0:
            max_tokens = min(maximum, 8192)
    except (OSError, ValueError, TypeError, AttributeError):
        pass
    config = STATE / 'pi-agent'
    config.mkdir(parents=True, exist_ok=True)
    models = {'providers': {'sapper': {'baseUrl': base, 'api': 'openai-completions',
        'apiKey': '$ANTHROPIC_AUTH_TOKEN', 'models': [{'id': model, 'name': model,
        'reasoning': False, 'input': ['text'], 'contextWindow': context_window, 'maxTokens': max_tokens}]}}}
    with tempfile.NamedTemporaryFile('w', encoding='utf-8', dir=config, delete=False) as f:
        json.dump(models, f, ensure_ascii=False)
        tmp = f.name
    os.chmod(tmp, 0o600)
    os.replace(tmp, config / 'models.json')
    os.environ['PI_CODING_AGENT_DIR'] = str(config)
    os.environ['PI_OFFLINE'] = '1'
    return ['pi', '--provider', 'sapper', '--model', model, '--no-extensions',
            '--extension', str(HERE / 'pi-graph-context.mjs'),
            '--no-skills', '--skill', str(HERE / 'pi-skills' / 'sapper' / 'SKILL.md'),
            '--no-prompt-templates', '--no-context-files', '--no-mcp']

def read_pane(pane):
    p = STATE / 'pane-env' / (pane + '.env')
    data = {}
    if p.is_file():
        for line in p.read_text(encoding='utf-8').splitlines():
            key, sep, value = line.partition('=')
            if sep:
                data[key] = value
    return data

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['tui', 'print', 'sapper'])
    parser.add_argument('rest', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.mode == 'sapper':
        compat = argparse.ArgumentParser()
        compat.add_argument('-p', action='store_true')
        compat.add_argument('--output-format')
        compat.add_argument('--model', required=True)
        compat.add_argument('--dangerously-skip-permissions', action='store_true')
        compat.add_argument('--append-system-prompt')
        opts = compat.parse_args(args.rest)
        cmd = configure(opts.model) + ['--print', '--no-session']
        if opts.append_system_prompt:
            cmd += ['--append-system-prompt', opts.append_system_prompt]
        result = subprocess.run(cmd, input=sys.stdin.read(), text=True, capture_output=True)
        if result.returncode:
            sys.stderr.write(result.stderr)
            return result.returncode
        print(json.dumps({'result': result.stdout.strip()}, ensure_ascii=False))
        return 0
    if len(args.rest) != 2:
        raise RuntimeError('Expected pane name and model')
    pane, model = args.rest
    if not pane or not all(c.isalnum() or c in '_.-' for c in pane):
        raise RuntimeError('Invalid pane name')
    data = read_pane(pane)
    cmd = configure(model)
    mission = base64.b64decode(data.get('MISSION_B64', ''), validate=True).decode('utf-8') if data.get('MISSION_B64') else ''
    if args.mode == 'print':
        cmd += ['--print', '--no-session']
        result = subprocess.run(cmd, input=mission, text=True)
        return result.returncode
    session = Path(data.get('PI_SESSION_DIR', str(STATE / 'pi-sessions' / pane)))
    session.mkdir(parents=True, exist_ok=True)
    cmd += ['--session-dir', str(session)]
    if pane == 'commander':
        cmd += ['--append-system-prompt', str(HERE / 'GENERAL.md')]
    if any(session.glob('*.jsonl')):
        cmd.append('--continue')
    elif mission:
        cmd += ['--', mission]
    os.execvp(cmd[0], cmd)

if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError) as exc:
        print(f'pi-agent: {exc}', file=sys.stderr)
        sys.exit(1)
