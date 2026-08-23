param(
    [string]$RunnerPath = (
        Join-Path $PSScriptRoot "run_tower_defense_enemy_performance_matrix.ps1"
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $RunnerPath -PathType Leaf)) {
    throw "Matrix runner was not found: $RunnerPath"
}

$pwshCommand = Get-Command pwsh -ErrorAction Stop
$output = @(
    & $pwshCommand.Source -NoProfile -File $RunnerPath -SelfTest 2>&1 |
        ForEach-Object { $_.ToString() }
)
$runnerExitCode = $LASTEXITCODE
$jsonLine = $output |
    Where-Object { $_.StartsWith("{") } |
    Select-Object -Last 1
if ([string]::IsNullOrWhiteSpace($jsonLine)) {
    throw "Matrix runner self-test did not emit structured JSON."
}
$payload = $jsonLine | ConvertFrom-Json -Depth 100
if (
    $runnerExitCode -ne 0 -or
    -not [bool]$payload.valid -or
    [string]$payload.verdict -ne "passed"
) {
    Write-Output $jsonLine
    throw "Matrix runner self-test failed with exit code $runnerExitCode."
}

$requiredTests = @(
    "round_ordering",
    "two_of_three",
    "fingerprint_rejects_mixing"
)
$observedTests = @($payload.tests | ForEach-Object { [string]$_.name })
foreach ($requiredTest in $requiredTests) {
    if ($requiredTest -notin $observedTests) {
        throw "Matrix runner self-test omitted '$requiredTest'."
    }
}

Write-Output $jsonLine
