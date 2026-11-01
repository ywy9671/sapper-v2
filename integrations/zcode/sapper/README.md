# Sapper for the ZCode harness

The installed ZCode session is the Commander. It may use ZCode's native Agent
and CreateWorkflow tools to coordinate workers under the host's normal rules.
This plugin does not start Pi or tmux and does not make its own model calls.
Models, permissions and token accounting follow ZCode's configuration.

The MCP server exposes task creation and listing, task graph/report inspection,
fact and intent recording, and read-only search/show of the upstream offline
knowledge base. It requires Node.js, Docker, the local Sapper container and the
loopback API at `http://127.0.0.1:18790`. Docker provides Sapper's storage/CLI,
not agent execution. Existing task reports remain on disk. Shared Docker access
is not an OS or network sandbox.

Install the enclosing marketplace in ZCode and start a new ZCode session. Ask
it to list Sapper tasks as a first check. Subagent routing, sharing the MCP tools
with ZCode agents, and the ZCode installation must be verified in that session.
Never publish local credentials, task graphs or reports with this plugin.
