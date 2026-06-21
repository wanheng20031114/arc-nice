param(
    [string]$GodotExe = "C:\Users\wh\Downloads\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe",
    [string]$ClumsyExe = "",
    [int]$Port = 29500,
    [ValidateSet("full", "leave", "wave")]
    [string]$Scenario = "full",
    [ValidateSet("100ms-2", "200ms-2", "200ms-5")]
    [string]$Profile = "100ms-2",
    [int]$TimeoutSeconds = 120,
    [switch]$GodotVerbose
)

$ErrorActionPreference = "Stop"

function Resolve-ClumsyExe {
    param([string]$RequestedPath)
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        if (Test-Path $RequestedPath) {
            return (Resolve-Path $RequestedPath).Path
        }
        throw "Clumsy executable was not found: $RequestedPath"
    }

    $command = Get-Command "clumsy.exe" -ErrorAction SilentlyContinue
    if ($command -ne $null) {
        return $command.Source
    }
    return ""
}

$resolvedClumsyExe = Resolve-ClumsyExe $ClumsyExe
if ([string]::IsNullOrWhiteSpace($resolvedClumsyExe)) {
    Write-Host "ERROR: clumsy.exe was not found in PATH and -ClumsyExe was not provided."
    Write-Host "Install or download clumsy, then rerun with -ClumsyExe 'C:\path\to\clumsy.exe'."
    Write-Host "Reference: https://jagt.github.io/clumsy/"
    exit 2
}

$profileParts = $Profile -split "ms-"
$rttMs = [int]$profileParts[0]
$lossPercent = [double]$profileParts[1]
$lagMs = [math]::Max(1, [int][math]::Round($rttMs / 2.0))
$filter = "udp and (udp.SrcPort == $Port or udp.DstPort == $Port)"

$probeScript = Join-Path $PSScriptRoot "run_multiplayer_lan_probe.ps1"
if (-not (Test-Path $probeScript)) {
    throw "Missing LAN probe runner: $probeScript"
}

$clumsyArgs = @(
    "--filter", $filter,
    "--lag", "on",
    "--lag-outbound", "on",
    "--lag-inbound", "off",
    "--lag-time", $lagMs,
    "--drop", "on",
    "--drop-outbound", "on",
    "--drop-inbound", "off",
    "--drop-chance", $lossPercent
)

Write-Host "Starting clumsy profile=$Profile scenario=$Scenario port=$Port filter=`"$filter`" lagTimeMs=$lagMs dropChance=$lossPercent"
$clumsyProcess = Start-Process `
    -FilePath $resolvedClumsyExe `
    -ArgumentList $clumsyArgs `
    -WindowStyle Hidden `
    -PassThru

try {
    Start-Sleep -Seconds 2
    $probeArgs = @{
        GodotExe = $GodotExe
        Port = $Port
        TimeoutSeconds = $TimeoutSeconds
        Scenario = $Scenario
    }
    if ($GodotVerbose) {
        $probeArgs.GodotVerbose = $true
    }
    & $probeScript @probeArgs
    $probeExitCode = $LASTEXITCODE
    if ($probeExitCode -ne 0) {
        exit $probeExitCode
    }
    Write-Host "MULTIPLAYER_CLUMSY_PROBE_OK profile=$Profile scenario=$Scenario port=$Port"
    exit 0
}
finally {
    if ($clumsyProcess -ne $null -and -not $clumsyProcess.HasExited) {
        Stop-Process -Id $clumsyProcess.Id -Force
        $clumsyProcess.WaitForExit()
    }
}
