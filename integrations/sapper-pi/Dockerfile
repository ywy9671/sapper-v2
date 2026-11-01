FROM sapper-agent:commander
USER root
RUN --mount=type=cache,target=/var/lib/apt/lists,sharing=locked --mount=type=cache,target=/var/cache/apt,sharing=locked \
    env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy -u ALL_PROXY -u all_proxy \
    apt-get update && env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy -u ALL_PROXY -u all_proxy \
    apt-get install -y --no-install-recommends ropper && rm -rf /var/lib/apt/lists/*
RUN env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy \
    npm install -g --ignore-scripts --no-audit --no-fund @earendil-works/pi-coding-agent@1.4.0 --registry=https://registry.npmjs.org/ \
    && npm uninstall -g @anthropic-ai/claude-code @openai/codex
RUN --mount=type=cache,target=/var/lib/apt/lists,sharing=locked --mount=type=cache,target=/var/cache/apt,sharing=locked \
    env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy apt-get update \
    && env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy apt-get install -y --no-install-recommends ripgrep fd-find \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd && rm -rf /var/lib/apt/lists/*
COPY commander/ /opt/sapper/docker/commander/
RUN rm -rf /opt/sapper/docker/commander/codex-home /opt/sapper/docker/commander/codex-gateway.sh \
    && chmod +x /opt/sapper/docker/commander/entrypoint.sh /opt/sapper/docker/commander/worker.sh /opt/sapper/docker/commander/watchdog.sh /opt/sapper/docker/commander/pi-agent.py \
    && chown -R agent:agent /opt/sapper/docker/commander
RUN python3 -c 'from pathlib import Path; p=Path("/opt/sapper/lib/sapper.py"); s=p.read_text(); a="os.environ.get(\"SAPPER_BIN\", \"claude\")"; b="os.environ.get(\"SAPPER_BIN\", \"/opt/sapper/docker/commander/pi-agent.py sapper\")"; assert s.count(a)==1; p.write_text(s.replace(a,b),encoding="utf-8")'
USER agent
ENV SAPPER_MODE=general SAPPER_BIN="/opt/sapper/docker/commander/pi-agent.py sapper"
