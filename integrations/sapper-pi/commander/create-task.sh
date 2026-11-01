#!/usr/bin/env bash
set -eu
: "${SAPPER_TASK_ID:?task ID required}"
[[ "$SAPPER_TASK_ID" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$ ]] || exit 2
task="/work/runs/$SAPPER_TASK_ID"
session="/work/runs/.sessions/$SAPPER_TASK_ID"
mkdir "$task"
mkdir -p /work/runs/.sessions
mkdir "$session"
mkdir "$session/root" "$session/state" "$session/bin"
ln -s "$task" "$session/root/$SAPPER_TASK_ID"
cat > "$session/bin/tmux" <<'EOF'
#!/bin/sh
exec /usr/bin/tmux -L "sapper-$SAPPER_TASK_ID" "$@"
EOF
chmod 755 "$session/bin/tmux"
