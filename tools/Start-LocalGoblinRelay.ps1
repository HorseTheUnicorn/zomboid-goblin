[CmdletBinding()]
param(
    [string]$RemoteHost = "192.168.0.76",
    [string]$RemoteUser = "goblin",
    [string]$RemoteBridgeRoot = "/home/goblin/zomboid-goblin-local/bridge",
    [string]$BridgeRoot = "C:\Users\tomgr\Zomboid\Lua\goblin-bridge",
    [string]$SshKey = (Join-Path $env:USERPROFILE ".ssh\id_ed25519_goblin"),
    [string]$PythonExecutable = "python",
    [switch]$Once
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path

if (-not (Test-Path -LiteralPath $BridgeRoot -PathType Container)) {
    throw "The local PZ bridge root does not exist: $BridgeRoot"
}
if (-not (Test-Path -LiteralPath $SshKey -PathType Leaf)) {
    throw "The SSH private-key path does not exist: $SshKey"
}
if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    throw "OpenSSH 'ssh' is required for the .76 relay."
}
if (-not (Get-Command scp -ErrorAction SilentlyContinue)) {
    throw "OpenSSH 'scp' is required for the .76 relay."
}

# This process mirrors only the atomic Goblin bridge in the PZ -> .76
# direction. Qwen remains bound to 127.0.0.1:8000 on .76; the PZ server never
# receives a raw model endpoint.
$env:PYTHONPATH = $repoRoot
$env:GOBLIN_BRIDGE_ROOT = $BridgeRoot
$env:GOBLIN_PZ_HOST = $RemoteHost
$env:GOBLIN_PZ_SSH_USER = $RemoteUser
$env:GOBLIN_PZ_BRIDGE_ROOT = $RemoteBridgeRoot
$env:GOBLIN_PZ_SSH_KEY = (Resolve-Path -LiteralPath $SshKey).Path
$env:GOBLIN_RELAY_REMOTE_ROLE = "agent"

$relayArgs = @("-m", "goblin_zomboid.relay")
if ($Once) { $relayArgs += "--once" }
& $PythonExecutable @relayArgs
exit $LASTEXITCODE
