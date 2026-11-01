# Sapper ZCode plugin

This plugin connects ZCode to an already-running local Sapper general WebUI/API
at `http://127.0.0.1:18790`. It requires Node.js on the ZCode host, Docker,
the Sapper Pi image and the local adapter service. It is not the Pi runtime and
does not install or start Docker, build the image, expose a graphical terminal,
or migrate existing tasks automatically. `open_terminal` opens the native host
terminal for the selected isolated task. The user interacts with Pi directly.

The plugin exposes `list_tasks`, `inspect_task`, `create_task`, and
`open_terminal`. Creation initializes a task but does not call a model. Model
settings, credentials and task data stay in the local Sapper installation and
must never be committed to the plugin repository. Existing sessions retain
their configuration; new sessions use the configured gateway.

Install the enclosing marketplace in ZCode, install Sapper, and start a new
ZCode session. Test with “List my Sapper tasks” before opening a real task.
