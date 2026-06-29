param()

# PostToolUse hook — runs `ruff check` against edited Python files in the
# workspace's two Python repos (ai-mcp-server-v1, ai-rag-llm-client-v1) after
# Edit/Write/MultiEdit.
# - Silent on success, and silent when ruff is not available on the host
#   (deps are Docker-resident here — this hook is best-effort).
# - On a real violation, emits {"systemMessage": "..."} so the user sees it.
# - Touches a marker file so the Stop hook can remind about running tests.

$ErrorActionPreference = "Stop"

$rawInput = [Console]::In.ReadToEnd()
if (-not $rawInput) { exit 0 }

try {
    $payload = $rawInput | ConvertFrom-Json
} catch {
    exit 0
}

$filePath = $null
if ($payload.tool_response -and $payload.tool_response.filePath) {
    $filePath = $payload.tool_response.filePath
} elseif ($payload.tool_input -and $payload.tool_input.file_path) {
    $filePath = $payload.tool_input.file_path
}

if (-not $filePath) { exit 0 }

$normalized = $filePath -replace '\\', '/'

# Only act on .py files inside the workspace's Python repos.
if ($normalized -notmatch '/(ai-mcp-server-v1|ai-rag-llm-client-v1)/.*\.py$') { exit 0 }

if (-not (Test-Path $filePath)) { exit 0 }

# Touch session marker (the Stop hook reads this to decide whether to remind).
$markerPath = "c:/projects/ai-projects/.claude/.python-edited-this-session"
try {
    Set-Content -Path $markerPath -Value "" -Encoding ASCII -ErrorAction Stop
} catch {
    # Marker is best-effort; do not fail the hook on filesystem errors.
}

# Resolve a ruff to run against the host file. Prefer a repo-local venv, then a
# global `python -m ruff`. If none is available (deps live in the containers),
# stay silent — linting still happens via the `lint` skill inside Docker.
$repoRoot = $null
if ($normalized -match '^(.*?/(?:ai-mcp-server-v1|ai-rag-llm-client-v1))/') {
    $repoRoot = $Matches[1]
}

$ruffExe = $null
$ruffArgs = $null

if ($repoRoot) {
    foreach ($cand in @("$repoRoot/.venv/Scripts/ruff.exe", "$repoRoot/backend/.venv/Scripts/ruff.exe")) {
        if (Test-Path $cand) { $ruffExe = $cand; break }
    }
}

if (-not $ruffExe) {
    # Fall back to `python -m ruff` only if it is actually importable.
    try {
        & python -m ruff --version *> $null
        if ($LASTEXITCODE -eq 0) { $ruffExe = "python"; $ruffArgs = @("-m", "ruff") }
    } catch {
        # python or ruff not available — nothing to do.
    }
}

if (-not $ruffExe) { exit 0 }

if ($ruffArgs) {
    $output = & $ruffExe @ruffArgs check $filePath 2>&1
} else {
    $output = & $ruffExe check $filePath 2>&1
}
$exitCode = $LASTEXITCODE

if ($exitCode -ne 0) {
    $joined = ($output | Out-String).TrimEnd()
    $msg = "ruff check failed for ${filePath}:`n${joined}"
    $obj = [ordered]@{ systemMessage = $msg } | ConvertTo-Json -Compress
    Write-Output $obj
}

exit 0
