param(
    [string]$CurrentPath = (Split-Path -Parent $PSScriptRoot),
    [ValidateRange(3, 3)]
    [int]$Rounds = 3
)

$ErrorActionPreference = "Stop"
$ProbePath = Join-Path $CurrentPath (
    "dev_tools\tower_defense_fate_flow_coordinator_ab_probe.gd"
)
$GodotPath = (Get-Command Godot_console.exe).Source
if (-not (Test-Path -LiteralPath $ProbePath -PathType Leaf)) {
    throw "FateFlow A/B probe does not exist: $ProbePath"
}

$Output = & $GodotPath `
    --headless `
    --path $CurrentPath `
    --script $ProbePath 2>&1 | Out-String
if (
    $LASTEXITCODE -ne 0 -or
    $Output -match "SCRIPT ERROR|Parse Error|Failed to load script|(?m)^ERROR:" -or
    $Output -notmatch "TOWER_DEFENSE_FATE_FLOW_COORDINATOR_AB_PROBE_OK"
) {
    throw "Fate/Luoxi boundary legacy-current A/B failed:`n$Output"
}
$HashMatch = [regex]::Match(
    $Output,
    "TOWER_FATE_BOUNDARY_AB_HASH=([0-9a-f]{64})"
)
if (-not $HashMatch.Success) {
    throw "Fate/Luoxi boundary A/B did not emit a trace hash."
}
[ordered]@{
    rounds = $Rounds
    trajectory_hash = $HashMatch.Groups[1].Value
    scope = "boundary comparison; not a full-scene A/B"
    baseline_model = "removed TowerDefenseGame boundary semantics"
    current_model = "typed Fate/Home/Luoxi/Roster/Research coordinators"
} | ConvertTo-Json
