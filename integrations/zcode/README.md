# Sapper and ZCode integration

This branch adds a general-task Pi adapter and a separate ZCode harness plugin
to upstream Sapper. The ZCode plugin uses ZCode agents; it does not launch Pi.
Tasks share a container but have independent graphs, tmux servers and Pi state;
this is not filesystem or network isolation. Existing reports are preserved.

## Prerequisites and build

Windows instructions below require Docker Desktop with Linux containers, Python
3, Node.js, and a local OpenAI Chat Completions compatible endpoint. Build the
upstream images in the repository root in dependency order:

```powershell
docker build -f docker/Dockerfile -t sapper-agent:latest .
docker build -f docker/Dockerfile.tmux -t sapper-agent:tmux .
docker build -f docker/Dockerfile.commander -t sapper-agent:commander .
docker build -f integrations/sapper-pi/Dockerfile -t sapper-agent:general integrations/sapper-pi
```

Image builds need the package sources referenced by those Dockerfiles. They do
not use the local Windows Claude Code installation. Pi and Sapper run inside
the container. Copy `integrations/sapper-pi/provider.example.json` to
`integrations/sapper-pi/provider.local.json` and fill in your own gateway,
container-reachable URL, model ID and API key. Do not commit that file. The
WebUI accepts a host-local URL and derives the container address on later edits.
Protect the file using your OS permissions. Do not put credentials in prompts.

Start `integrations/sapper-pi/Start-General.ps1`, then run
`python integrations/sapper-pi/general-webui.py`. The WebUI binds to loopback
port 18790. Nothing creates or starts an assessment merely by starting the
service. `SAPPER_TOTAL_MINUTES` controls the upstream watchdog deadline.

## ZCode plugin

Add the `integrations/zcode` directory as a ZCode marketplace, then install
Sapper and start a fresh ZCode session. The plugin exposes MCP tools for task
listing, inspection, creation, graph facts and intents, and KB retrieval. ZCode
provides the agent harness. Ask ZCode to list Sapper tasks as a first check.
See `sapper/README.md` for limitations.

The adapter uses the upstream graph, templates, KB, Commander/worker/watchdog
scripts and explicitly loaded Pi-compatible Sapper skill. Its Pi extension
bridges the upstream per-prompt graph hook to the selected task. General-task
boundaries supersede competition-only platform and flag-submission guidance.
The existing Sapper CLI's other upstream options are preserved; Pi does not
load local Claude Code sessions, hooks or configuration.

Do not publish `provider.local.json`, API credentials, `data/`, task outputs,
logs, session files, or local assessments. Deployment on other machines and
ZCode marketplace installation require local verification.
