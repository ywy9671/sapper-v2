"""Loopback-only observation UI for the running general Sapper container."""
import json
import os
import re
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

HERE = Path(__file__).resolve().parent
RUNS = HERE / 'data' / 'runs'
STATE = RUNS / '.general'
CONTAINER = 'sapper-general'
TASK = re.compile(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$')
NEW_TASK = re.compile(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$')
DEMO_TASKS = {'lab-hash', 'lab-health'}
LOCK = threading.Lock()
TASK_LOCK = threading.Lock()

def run(*args):
    try:
        p = subprocess.run(['docker', *args], capture_output=True, text=True, timeout=20,
                           encoding='utf-8', errors='replace', creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 1, '', str(exc)

def run_with_provider(provider, *args):
    env = os.environ.copy()
    env.update({'ANTHROPIC_BASE_URL': provider['container_anthropic_base_url'], 'ANTHROPIC_AUTH_TOKEN': provider['api_key'],
                'SAPPER_MODEL': provider['model'], 'SAPPER_MODEL_FLASH': provider['model'], 'SAPPER_MODEL_DS': provider['model']})
    try:
        p = subprocess.run(['docker', *args], env=env, capture_output=True, text=True, timeout=20,
                           encoding='utf-8', errors='replace', creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 1, '', str(exc)

def read_provider():
    try:
        data = json.loads((HERE / 'provider.local.json').read_text(encoding='utf-8'))
        if not all(isinstance(data.get(k), str) and data[k] for k in ('base_url', 'container_anthropic_base_url', 'api_key', 'model')):
            raise ValueError()
        return data
    except (OSError, ValueError, TypeError):
        raise RuntimeError('无法读取完整的供应商配置')

def save_provider(data):
    existing = read_provider()
    base, model, key = data.get('base_url'), data.get('model'), data.get('api_key', '')
    if not all(isinstance(v, str) for v in (base, model, key)):
        raise ValueError('供应商配置必须是文字')
    base, model = base.strip().rstrip('/'), model.strip()
    try:
        url = urlsplit(base)
        port = url.port
    except ValueError:
        raise ValueError('Base URL 无效')
    if len(base) > 2048 or url.scheme not in ('http', 'https') or not url.hostname or url.username or url.password or url.query or url.fragment or any(ord(c) < 33 for c in base):
        raise ValueError('请输入不含凭据、查询参数或片段的 HTTP(S) Base URL')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_./:\[\]-]{0,255}', model):
        raise ValueError('模型 ID 包含不支持的字符')
    if key and (len(key) > 4096 or any(ord(c) < 32 or ord(c) == 127 for c in key)):
        raise ValueError('API Key 格式无效')
    container_base = base
    if url.hostname.lower() in ('localhost', '127.0.0.1', '::1'):
        container_base = f'{url.scheme}://host.docker.internal' + (f':{port}' if port else '') + url.path.rstrip('/')
    existing.update({'base_url': base, 'container_anthropic_base_url': container_base, 'model': model, 'api_key': key or existing['api_key']})
    # Update the existing file in place so Windows retains its restricted ACL.
    with (HERE / 'provider.local.json').open('r+', encoding='utf-8') as f:
        f.seek(0)
        json.dump(existing, f, ensure_ascii=False, indent=2)
        f.write('\n')
        f.truncate()
        f.flush()
        os.fsync(f.fileno())

def redact(text):
    try:
        key = json.loads((HERE / 'provider.local.json').read_text(encoding='utf-8')).get('api_key', '')
        if key:
            text = text.replace(key, '[REDACTED]')
    except (OSError, ValueError):
        pass
    return text

def tasks():
    if not RUNS.exists():
        return []
    found = {p.name for p in RUNS.iterdir() if p.is_dir() and p.name not in DEMO_TASKS and TASK.fullmatch(p.name)
             and (p / '.sapper' / 'project.json').is_file()}
    return sorted(name for name in found if not (re.search(r'-w[0-9]+$', name)
                  and re.sub(r'-w[0-9]+$', '', name) in found
                  and not (RUNS / '.sessions' / name / 'bin' / 'tmux').is_file()))

def isolated_task(task):
    return bool(NEW_TASK.fullmatch(task) and (RUNS / '.sessions' / task / 'bin' / 'tmux').is_file())

def task_environment(task):
    session = f'/work/runs/.sessions/{task}'
    return ['-e', f'SAPPER_TASK_ID={task}', '-e', f'SAPPER_ROOT={session}/root',
            '-e', f'SAPPER_STATE_ROOT={session}/state', '-e',
            f'PATH={session}/bin:/home/agent/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin']

def task_tmux(task):
    return ['/usr/bin/tmux', '-L', f'sapper-{task}']

def task_running(task):
    code, _, _ = run('exec', CONTAINER, *task_tmux(task), 'has-session', '-t', 'sapper-cmd')
    return code == 0

def task_records():
    records = []
    online, _, _ = run('exec', CONTAINER, 'true')
    for name in tasks():
        try:
            data = json.loads((RUNS / name / '.sapper' / 'project.json').read_text(encoding='utf-8'))
        except (OSError, ValueError):
            data = {}
        isolated = isolated_task(name)
        records.append({'id': name, 'goal': data.get('goal', ''), 'graph_status': data.get('status', ''),
                        'created_at': data.get('created_at', ''), 'isolated': isolated,
                        'running': task_running(name) if isolated and online == 0 else None})
    return records

def container_ready():
    code, _, error = run('exec', CONTAINER, 'true')
    if code:
        raise RuntimeError('Sapper 容器未运行；请先启动 Docker 和 Sapper。' + (' ' + redact(error) if error else ''))
    provider = read_provider()
    code, _, _ = run('exec', CONTAINER, 'bash', '-c', 'command -v pi >/dev/null')
    if code:
        raise RuntimeError('Pi 或模型网关配置不可用。')
    return provider

def commander_ready(task, model):
    code, pane, _ = run('exec', CONTAINER, *task_tmux(task), 'capture-pane', '-p', '-t', 'sapper-cmd:commander')
    return code == 0 and 'DRIVE_PANE_EXITED' not in pane and model in pane

def start_task(task):
    if not isolated_task(task) or task not in tasks():
        raise ValueError('该任务没有独立会话，请新建独立任务。')
    if task_running(task):
        return 'running'
    provider = container_ready()
    if not task_running(task):
        code, _, error = run_with_provider(provider, 'exec', '-d', '-e', 'ANTHROPIC_BASE_URL', '-e', 'ANTHROPIC_AUTH_TOKEN',
                             '-e', 'SAPPER_MODEL', '-e', 'SAPPER_MODEL_FLASH', '-e', 'SAPPER_MODEL_DS', *task_environment(task), CONTAINER, 'bash', '-c',
                             'exec /opt/sapper/docker/commander/entrypoint.sh >> "$SAPPER_STATE_ROOT/entrypoint.log" 2>&1')
        if code:
            raise RuntimeError('启动会话失败：' + redact(error))
    for _ in range(60):
        time.sleep(.25)
        if task_running(task) and commander_ready(task, provider['model']):
            return 'ready'
    raise RuntimeError('会话已请求启动，但 Pi 未就绪；请稍后查看该任务的状态日志。')

def open_terminal(task):
    command = f'docker exec -it -e TERM=xterm-256color {CONTAINER} /usr/bin/tmux -L sapper-{task} attach-session -t sapper-cmd'
    try:
        subprocess.Popen(['powershell.exe', '-NoExit', '-Command', command],
                         creationflags=getattr(subprocess, 'CREATE_NEW_CONSOLE', 0))
    except OSError as exc:
        raise RuntimeError('打开终端失败：' + str(exc)) from exc

def finding_sections(text):
    sections = []
    current = None
    for line in text.splitlines():
        match = re.match(r'^###\s+((?:F|N)-\d+)\b(.*)$', line)
        if match:
            if current:
                current['body'] = '\n'.join(current.pop('_lines')).strip()
                sections.append(current)
            current = {'id': match.group(1), 'title': (match.group(1) + match.group(2)).strip(), '_lines': []}
        elif current:
            if re.match(r'^#{1,3}\s+', line):
                current['body'] = '\n'.join(current.pop('_lines')).strip()
                sections.append(current)
                current = None
            else:
                current['_lines'].append(line)
    if current:
        current['body'] = '\n'.join(current.pop('_lines')).strip()
        sections.append(current)
    return sections

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args): pass
    def reply(self, body, status=200, content='text/html; charset=utf-8'):
        raw = body.encode('utf-8') if isinstance(body, str) else body
        self.send_response(status)
        self.send_header('Content-Type', content)
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def json_reply(self, value, status=200):
        return self.reply(json.dumps(value, ensure_ascii=False), status, 'application/json; charset=utf-8')

    def do_POST(self):
        host = f'127.0.0.1:{self.server.server_port}'
        if self.headers.get('Host') != host or self.headers.get('Origin') != 'http://' + host:
            return self.json_reply({'error': '请求来源不受信任'}, 403)
        if self.headers.get_content_type() != 'application/json':
            return self.json_reply({'error': '请求格式错误'}, 415)
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= 131072:
                return self.json_reply({'error': '请求内容过大或为空'}, 413)
            data = json.loads(self.rfile.read(length).decode('utf-8'))
            if not isinstance(data, dict):
                raise ValueError('请求必须是对象')
            path = urlsplit(self.path).path
            with TASK_LOCK:
                if path == '/provider':
                    save_provider(data)
                    return self.json_reply({'saved': True})
                if path == '/tasks':
                    task = data.get('id', '')
                    goal = data.get('goal', '')
                    scope = data.get('scope', '')
                    excluded = data.get('excluded', '')
                    if not all(isinstance(x, str) for x in (task, goal, scope, excluded)):
                        raise ValueError('任务字段必须是文字')
                    if any('\x00' in x for x in (task, goal, scope, excluded)):
                        raise ValueError('任务字段包含不支持的字符')
                    if not NEW_TASK.fullmatch(task):
                        raise ValueError('任务 ID 只能包含字母、数字、下划线或连字符，最长 48 位')
                    if not goal.strip() or len(goal) > 4000 or len(scope) > 10000 or len(excluded) > 10000:
                        raise ValueError('请填写任务目标，并检查字段长度')
                    if (RUNS / task).exists() or (RUNS / '.sessions' / task).exists():
                        return self.json_reply({'error': '任务 ID 已存在，请使用新的 ID'}, 409)
                    code, _, error = run('exec', CONTAINER, 'true')
                    if code:
                        raise RuntimeError('Sapper 容器未运行；请先启动 Docker 和 Sapper。' + (' ' + redact(error) if error else ''))
                    code, _, error = run('exec', '-e', f'SAPPER_TASK_ID={task}', CONTAINER,
                                         'bash', '/opt/sapper/docker/commander/create-task.sh')
                    if code:
                        raise RuntimeError('创建任务目录失败：' + redact(error))
                    task_dir = RUNS / task
                    try:
                        text = f'# Task scope\n\n## Goal\n{goal}\n\n## Authorized targets and allowed methods\n{scope}\n\n## Exclusions\n{excluded}\n'
                        with (task_dir / 'scope.md').open('x', encoding='utf-8', newline='\n') as f:
                            f.write(text)
                        code, _, error = run('exec', CONTAINER, 'sapper', '--store', f'/work/runs/{task}/.sapper',
                                             'init', '--goal=' + goal)
                        if code:
                            raise RuntimeError('初始化事实图失败：' + redact(error))
                    except Exception as exc:
                        raise RuntimeError(f'任务目录已保留，但创建未完成（{task}）：{exc}') from exc
                    return self.json_reply({'id': task, 'created': True, 'running': False}, 201)
                match = re.fullmatch(r'/tasks/([A-Za-z0-9][A-Za-z0-9_-]{0,47})/(start|open)', path)
                if not match:
                    return self.json_reply({'error': '接口不存在'}, 404)
                task, action = match.groups()
                if action == 'start':
                    return self.json_reply({'id': task, 'state': start_task(task)})
                start_task(task)
                open_terminal(task)
                return self.json_reply({'id': task, 'opened': True})
        except (ValueError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            return self.json_reply({'error': str(exc)}, 400)
        except (OSError, RuntimeError) as exc:
            return self.json_reply({'error': redact(str(exc))}, 500)

    def do_GET(self):
        parsed = urlsplit(self.path)
        if parsed.path == '/provider':
            if self.headers.get('Host') != f'127.0.0.1:{self.server.server_port}':
                return self.json_reply({'error': '请求来源不受信任'}, 403)
            try:
                with TASK_LOCK:
                    provider = read_provider()
                return self.json_reply({'base_url': provider['base_url'], 'model': provider['model'], 'api_key_configured': bool(provider['api_key'])})
            except RuntimeError as exc:
                return self.json_reply({'error': str(exc)}, 500)
        if parsed.path == '/':
            return self.reply((HERE / 'general-webui.html').read_text(encoding='utf-8'))
        if parsed.path == '/tasks':
            return self.json_reply({'tasks': task_records()})
        if parsed.path == '/snapshot':
            task = parse_qs(parsed.query).get('task', [''])[0]
            if task and (not TASK.fullmatch(task) or task not in tasks()):
                return self.reply(json.dumps({'error': '任务不存在'}, ensure_ascii=False), 404,
                                  'application/json; charset=utf-8')
            isolated = bool(task and isolated_task(task))
            session = f'/work/runs/.sessions/{task}'
            env = []
            tmux = ['tmux']
            if isolated:
                env = task_environment(task)
                tmux = task_tmux(task)
            if not task:
                code, _out, error = run('exec', CONTAINER, 'true')
                board = '请选择任务'
            else:
                code, board, error = run('exec', *env, CONTAINER, '/opt/sapper/docker/commander/worker.sh', 'board', '--json')
            if code == 0:
                try:
                    parsed_board = json.loads(board)
                    parsed_board['codes'] = [x for x in parsed_board.get('codes', []) if x.get('code') not in DEMO_TASKS]
                    board = json.dumps(parsed_board, ensure_ascii=False)
                except (ValueError, AttributeError, TypeError):
                    pass
            pane_code, pane_names, _ = run('exec', CONTAINER, *tmux, 'list-windows', '-t', 'sapper-cmd', '-F', '#W') if task else (1, '', '')
            panes = {}
            if pane_code == 0:
                for name in pane_names.splitlines():
                    if TASK.fullmatch(name):
                        _, output, _ = run('exec', CONTAINER, *tmux, 'capture-pane', '-p', '-t', 'sapper-cmd:' + name, '-S', '-100')
                        panes[name] = redact(output)
            log = ((RUNS / '.sessions' / task / 'state' if isolated else STATE) / 'drive.log') if task else None
            payload = {'connected': code == 0, 'board': redact(board if code == 0 else error),
                       'panes': panes, 'tasks': tasks(), 'task': task,
                       'session_type': 'isolated' if isolated else ('legacy' if task else 'none'),
                       'log': redact(log.read_text(encoding='utf-8', errors='replace')[-12000:]) if log and log.exists() else ''}
            return self.reply(json.dumps(payload, ensure_ascii=False), content='application/json; charset=utf-8')
        if parsed.path == '/findings':
            task = parse_qs(parsed.query).get('task', [''])[0]
            if not TASK.fullmatch(task) or task not in tasks():
                return self.reply(json.dumps({'error': '任务不存在'}, ensure_ascii=False), 404,
                                  'application/json; charset=utf-8')
            report = RUNS / task / 'findings.md'
            if not report.is_file():
                return self.reply(json.dumps({'task': task, 'report': '', 'sections': [], 'updated_at': None},
                                             ensure_ascii=False), content='application/json; charset=utf-8')
            try:
                if report.stat().st_size > 4 * 1024 * 1024:
                    return self.reply(json.dumps({'error': 'Finding 报告超过 4 MiB，暂不载入'}, ensure_ascii=False), 413,
                                      'application/json; charset=utf-8')
                text = redact(report.read_text(encoding='utf-8', errors='replace'))
                updated = report.stat().st_mtime
                payload = {'task': task, 'report': text, 'report_name': report.name,
                           'updated_at': updated, 'sections': finding_sections(text)}
                return self.reply(json.dumps(payload, ensure_ascii=False), content='application/json; charset=utf-8')
            except OSError as exc:
                return self.reply(json.dumps({'error': '读取 Finding 报告失败：' + str(exc)}, ensure_ascii=False), 500,
                                  'application/json; charset=utf-8')
        if parsed.path == '/graph':
            task = parse_qs(parsed.query).get('task', [''])[0]
            if not TASK.fullmatch(task) or task not in tasks():
                return self.reply('任务不存在', 404)
            destination = STATE / 'graphs' / (task + '.html')
            with LOCK:
                code, _out, error = run('exec', CONTAINER, 'mkdir', '-p', '/work/runs/.general/graphs')
                if code != 0:
                    return self.reply('无法创建事实图目录：' + redact(error), 500)
                code, _out, error = run('exec', CONTAINER, 'sapper', '--store', f'/work/runs/{task}/.sapper',
                                        'view', '--out', f'/work/runs/.general/graphs/{task}.html')
                if code != 0 or not destination.is_file():
                    return self.reply('无法生成事实图：' + redact(error), 500)
                return self.reply(destination.read_bytes())
        self.reply('Not found', 404)

if __name__ == '__main__':
    ThreadingHTTPServer(('127.0.0.1', 18790), Handler).serve_forever()
