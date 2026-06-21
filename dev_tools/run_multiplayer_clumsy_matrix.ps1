param(
    [string]$GodotExe = "C:\Users\wh\Downloads\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe",
    [string]$ClumsyExe = "",
    [int]$StartPort = 29500,
    [ValidateSet("full", "leave", "wave")]
    [string[]]$Scenarios = @("full", "wave", "leave"),
    [ValidateSet("100ms-2", "200ms-2", "200ms-5")]
    [string[]]$Profiles = @("100ms-2", "200ms-2", "200ms-5"),
    [int]$TimeoutSeconds = 150,
    [switch]$GodotVerbose
)

$ErrorActionPreference = "Stop"

$probeScript = Join-Path $PSScriptRoot "run_multiplayer_clumsy_probe.ps1"
if (-not (Test-Path $probeScript)) {
    throw "Missing clumsy probe runner: $probeScript"
}

$results = @()
$port = $StartPort

foreach ($profile in $Profiles) {
    foreach ($scenario in $Scenarios) {
        Write-Host "==== CLUMSY_MATRIX profile=$profile scenario=$scenario port=$port ===="
        $probeArgs = @{
            GodotExe = $GodotExe
            ClumsyExe = $ClumsyExe
            Port = $port
            TimeoutSeconds = $TimeoutSeconds
            Scenario = $scenario
            Profile = $profile
        }
        if ($GodotVerbose) {
            $probeArgs.GodotVerbose = $true
        }

        $startedAt = Get-Date
        & $probeScript @probeArgs
        $exitCode = $LASTEXITCODE
        $durationSeconds = [math]::Round(((Get-Date) - $startedAt).TotalSeconds, 2)
        $results += [pscustomobject]@{
            Profile = $profile
            Scenario = $scenario
            Port = $port
            ExitCode = $exitCode
            DurationSeconds = $durationSeconds
        }
        if ($exitCode -ne 0) {
            Write-Host "ERROR: Clumsy matrix failed profile=$profile scenario=$scenario port=$port."
            $results | Format-Table -AutoSize
            exit $exitCode
        }
        $port += 1
    }
}

$results | Format-Table -AutoSize
Write-Host "MULTIPLAYER_CLUMSY_MATRIX_OK profiles=$($Profiles -join ',') scenarios=$($Scenarios -join ',')"
exit 0
