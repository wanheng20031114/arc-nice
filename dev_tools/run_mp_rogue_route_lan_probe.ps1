[CmdletBinding()]
param(
    [string]$GodotExe = "C:\Program Files\Godot\Godot_console.exe",
    [int]$Port = 29386,
    [int]$TimeoutSeconds = 30,
    [string]$ProjectPath = "",
    [string]$PeerScript = "res://dev_tools/mp_rogue_route_lan_probe_peer.gd",
    [string[]]$PeerExtraArguments = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lan_probe_truth_common.ps1")

$projectPath = if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
    (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}
else {
    (Resolve-Path -LiteralPath $ProjectPath).Path
}
$runId = [Guid]::NewGuid().ToString("N")
$runMarkerPrefix = "--arc-p3-lan-probe-run-id=$runId"
$logRoot = Join-Path $env:TEMP "arc-nice-p3-lan-$runId"
$context = New-LanProbeTruthContext $runId $runMarkerPrefix
$entries = @()
$failures = [Collections.Generic.List[string]]::new()


function Start-P3Peer {
    param([string]$Role)

    $stdout = Join-Path $logRoot "$Role.out.log"
    $stderr = Join-Path $logRoot "$Role.err.log"
    $engineLog = Join-Path $logRoot "$Role.godot.log"
    $peerRunMarker = "$runMarkerPrefix-$Role"
    $godotArguments = @(
        "--headless",
        "--path", $projectPath,
        "--log-file", $engineLog,
        "--script", $PeerScript,
        "--",
        $peerRunMarker,
        "--probe-role=$Role",
        "--probe-port=$Port"
    )
    foreach ($extraArgument in $PeerExtraArguments) {
        $godotArguments += [string]$extraArgument
    }
    $launched = Start-LanProbeManagedProcess `
        $context `
        $GodotExe `
        $projectPath `
        $godotArguments

    return [pscustomobject]@{
        Name = $Role
        Role = $Role
        Process = $launched.Process
        StdoutTask = $launched.StdoutTask
        StderrTask = $launched.StderrTask
        LogsCompleted = $false
        RunMarker = $peerRunMarker
        Stdout = $stdout
        Stderr = $stderr
        EngineLog = $engineLog
    }
}


try {
    if (-not (Test-Path -LiteralPath $GodotExe -PathType Leaf)) {
        throw "Godot console executable does not exist: $GodotExe"
    }
    if ($TimeoutSeconds -le 0) {
        throw "TimeoutSeconds must be positive."
    }
    New-Item -ItemType Directory -Path $logRoot -ErrorAction Stop | Out-Null

    $entries += Start-P3Peer -Role "host"
    Watch-LanProbeProcessOwnership $context 350
    $entries += Start-P3Peer -Role "client"

    Wait-LanProbePeerProcesses $context $entries $TimeoutSeconds
    foreach ($entry in $entries) {
        Complete-LanProbePeerLogs $entry
    }
    foreach ($entry in $entries) {
        $expectedMarker = "MP_ROGUE_ROUTE_LAN_$($entry.Role.ToUpper())_OK"
        try {
            $null = Assert-LanProbePeerTruth $entry $expectedMarker
            Write-Output (
                "[$($entry.Role)] $expectedMarker " +
                "(exit=0; owned launcher PID=$([int]$entry.Process.Id))"
            )
        }
        catch {
            $failures.Add($_.Exception.Message)
            Write-LanProbePeerLogs $entry
        }
    }
}
catch {
    $failures.Add($_.Exception.Message)
}
finally {
    try {
        Stop-LanProbeOwnedProcessTree $context
    }
    catch {
        $failures.Add($_.Exception.Message)
    }
    foreach ($entry in $entries) {
        try {
            Complete-LanProbePeerLogs $entry
        }
        catch {
            $failures.Add($_.Exception.Message)
        }
    }
    Close-LanProbeProcessHandles $context
}

if ($failures.Count -ne 0) {
    foreach ($failure in $failures) {
        [Console]::Error.WriteLine("MP_ROGUE_ROUTE_LAN_PROBE_FAILED: $failure")
    }
    [Console]::Error.WriteLine("P3 LAN probe logs preserved at: $logRoot")
    exit 1
}

Write-Output "MP_ROGUE_ROUTE_LAN_PROBE_OK logRoot=$logRoot"
exit 0
