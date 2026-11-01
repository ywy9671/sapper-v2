---
name: sapper
description: Use the local Sapper Pi service to create, list and inspect isolated operator-directed security assessment tasks, or open their native Commander terminal.
---

# Sapper task workflow

Use the Sapper MCP tools to list tasks, inspect a task or create a task explicitly
requested by the operator. Use `open_terminal` only when the operator asks to
start or open a Commander session. The user enters their prompt in native Pi.
Creation does not run a model. Do not invent targets or scope. Existing reports
and graphs are task-local; shared container and KB are not a security boundary.
Do not send credentials or private task data to a different task. Do not turn
unconfirmed observations into findings. Preserve old task records.

If the service is unavailable, explain that the local Sapper WebUI/API at
127.0.0.1:18790 and Docker are prerequisites. Do not treat the plugin as an
embedded replacement for the Pi runtime. Model calls happen in Pi after user
input and may consume tokens.
