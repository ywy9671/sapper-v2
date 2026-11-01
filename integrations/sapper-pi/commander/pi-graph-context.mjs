// Pi adapter for the upstream Sapper UserPromptSubmit graph hook.
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { join } from 'node:path';

export default function sapperGraphContext(pi) {
  pi.on('before_agent_start', async (event, ctx) => {
    if (event.messageType !== 'user') return;
    const task = process.env.SAPPER_TASK_ID || '';
    if (!/^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$/.test(task)) return;
    const root = process.env.SAPPER_ROOT;
    if (!root) return;
    const cwd = join(root, task);
    if (!existsSync(join(cwd, '.sapper', 'project.json'))) return;
    const result = spawnSync('python3', ['/opt/sapper/lib/sapper-hook.py', 'userpromptsubmit'], {
      input: JSON.stringify({ cwd }), encoding: 'utf8', timeout: 5000, maxBuffer: 100000,
    });
    if (result.error || result.status !== 0 || !result.stdout) return;
    try {
      const content = JSON.parse(result.stdout).hookSpecificOutput?.contextForClaude;
      if (typeof content !== 'string' || !content) return;
      return { message: { customType: 'sapper-task-graph', content, display: false } };
    } catch { return; }
  });
}
