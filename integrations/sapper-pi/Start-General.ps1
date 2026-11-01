$ErrorActionPreference = 'Stop'
$containerName = 'sapper-general'
$imageName = 'sapper-agent:general'
$provider = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'provider.local.json') -Raw | ConvertFrom-Json
if (-not $provider.container_anthropic_base_url -or -not $provider.api_key -or -not $provider.model) { throw 'Provider configuration is incomplete.' }
& docker image inspect $imageName *> $null
if ($LASTEXITCODE -ne 0) { throw 'Build sapper-agent:general first.' }
$name = & docker ps -a --filter "name=^/$containerName`$" --format '{{.Names}}'
if ($name -eq $containerName) {
    & docker start $containerName *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Could not start sapper-general.' }
    $imageId = & docker inspect $containerName --format '{{.Image}}'
    $expectedId = & docker image inspect $imageName --format '{{.Id}}'
    if ($imageId -ne $expectedId) {
        foreach ($file in @('entrypoint.sh','worker.sh','watchdog.sh','pi-agent.py','create-task.sh','GENERAL.md')) {
            $expectedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $PSScriptRoot "general\commander\$file")).Hash.ToLowerInvariant()
            $actualLine = & docker exec $containerName sha256sum "/opt/sapper/docker/commander/$file"
            if ($LASTEXITCODE -ne 0 -or (($actualLine -split '\s+')[0] -ne $expectedHash)) {
                throw "Existing container has an older $file. Preserve its session and replace it to use the latest image."
            }
        }
        & docker exec $containerName ropper --version *> $null
        if ($LASTEXITCODE -ne 0) { throw 'Existing container does not have the required ropper installation.' }
        & docker exec $containerName bash -c 'command -v pi >/dev/null && ! command -v claude >/dev/null && ! command -v codex >/dev/null' *> $null
        if ($LASTEXITCODE -ne 0) { throw 'Existing container has not been migrated to Pi-only runtime.' }
    }
} else {
    $env:ANTHROPIC_BASE_URL = $provider.container_anthropic_base_url
    $env:ANTHROPIC_AUTH_TOKEN = $provider.api_key
    $env:SAPPER_MODEL = $provider.model
    $env:SAPPER_MODEL_FLASH = $provider.model
    $env:SAPPER_MODEL_DS = $provider.model
    $dataRoot = Join-Path $PSScriptRoot 'data'
    New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
    $argsList = @('run','-d','--name',$containerName,'--init','--mount',"type=bind,source=$dataRoot,target=/work",
      '-e','ANTHROPIC_BASE_URL','-e','ANTHROPIC_AUTH_TOKEN','-e','SAPPER_MODEL','-e','SAPPER_MODEL_FLASH','-e','SAPPER_MODEL_DS',
      '-e','SAPPER_MODE=general','-e','TZ=Asia/Shanghai','-e','HTTP_PROXY=','-e','HTTPS_PROXY=',
      '-e','ALL_PROXY=','-e','NO_PROXY=','-e','http_proxy=','-e','https_proxy=','-e','all_proxy=','-e','no_proxy=',
      '--entrypoint','sleep',$imageName,'infinity')
    & docker @argsList *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Could not create sapper-general.' }
}
# Only the task-root directory is changed; existing task file permissions are retained.
& docker exec --user root $containerName bash -c 'mkdir -p /work/runs && chown 1000:1000 /work/runs'
if ($LASTEXITCODE -ne 0) { throw 'Could not prepare task root.' }
& docker exec $containerName tmux has-session -t sapper-cmd *> $null
if ($LASTEXITCODE -eq 0) { Write-Host 'General Sapper commander session is running.' }
else { Write-Host 'General Sapper container is idle. No model call has been made.' }
