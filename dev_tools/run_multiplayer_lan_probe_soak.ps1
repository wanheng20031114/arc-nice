param(
    [string]$GodotExe = "C:\Program Files\Godot\Godot_console.exe",
    [int]$StartPort = 29400,
    [int]$Iterations = 2,
    [int]$TimeoutSeconds = 100,
    [switch]$GodotVerbose
)

$ErrorActionPreference = "Stop"

$probeScript = Join-Path $PSScriptRoot "run_multiplayer_lan_probe.ps1"
if (-not (Test-Path $probeScript)) {
    throw "Missing LAN probe runner: $probeScript"
}

$scenarios = @("full", "leave", "wave")
$results = @()
$port = $StartPort

for ($iteration = 1; $iteration -le $Iterations; $iteration++) {
    foreach ($scenario in $scenarios) {
        Write-Host "==== LAN_PROBE_SOAK iteration=$iteration scenario=$scenario port=$port ===="
        $probeArgs = @{
            GodotExe = $GodotExe
            Port = $port
            TimeoutSeconds = $TimeoutSeconds
            Scenario = $scenario
        }
        if ($GodotVerbose) {
            $probeArgs.GodotVerbose = $true
        }

        $startedAt = Get-Date
        & $probeScript @probeArgs
        $exitCode = $LASTEXITCODE
        $durationSeconds = [math]::Round(((Get-Date) - $startedAt).TotalSeconds, 2)
        $results += [pscustomobject]@{
            Iteration = $iteration
            Scenario = $scenario
            Port = $port
            ExitCode = $exitCode
            DurationSeconds = $durationSeconds
        }
        if ($exitCode -ne 0) {
            Write-Host "ERROR: LAN probe soak failed at iteration=$iteration scenario=$scenario port=$port."
            $results | Format-Table -AutoSize
            exit $exitCode
        }
        $port += 1
    }
}

$results | Format-Table -AutoSize
Write-Host "MULTIPLAYER_LAN_PROBE_SOAK_OK iterations=$Iterations scenarios=$($scenarios -join ',')"
exit 0
