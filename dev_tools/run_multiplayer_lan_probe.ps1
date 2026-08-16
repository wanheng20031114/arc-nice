[CmdletBinding()]
param(
    [string]$GodotExe = "C:\Program Files\Godot\Godot_console.exe",
    [int]$Port = 29270,
    [int]$TimeoutSeconds = 65,
    [ValidateSet("full", "leave", "wave", "boss", "tower_defense", "death_revive", "mode_contract")]
    [string]$Scenario = "full",
    [ValidateSet("standard", "tower_defense", "test_arena_p1", "test_arena_p1b", "test_arena_p1c", "test_arena_p1d", "test_arena_p2")]
    [string]$GameMode = "standard",
    [ValidateRange(2, 8)]
    [int]$PlayerCount = 4,
    [switch]$GodotVerbose,
    [string]$ProjectPath = "",
    [string]$PeerScript = "res://dev_tools/multiplayer_lan_probe_peer.gd",
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
$runMarkerPrefix = "--arc-lan-probe-run-id=$runId"
$logRoot = Join-Path $env:TEMP "arc-nice-lan-probe-$runId"
$context = New-LanProbeTruthContext $runId $runMarkerPrefix
$entries = @()
$failures = [Collections.Generic.List[string]]::new()


function Start-ProbePeer {
    param(
        [string]$Role,
        [string]$Name,
        [int]$StartDelayMs = 0,
        [double]$RunSeconds = 3.0,
        [double]$LingerSeconds = 0.0,
        [bool]$Events = $false
    )

    if ($StartDelayMs -gt 0) {
        Watch-LanProbeProcessOwnership $context $StartDelayMs
    }

    $stdout = Join-Path $logRoot "$Name.out.log"
    $stderr = Join-Path $logRoot "$Name.err.log"
    $engineLog = Join-Path $logRoot "$Name.godot.log"
    $peerRunMarker = "$runMarkerPrefix-$Name"
    $godotArguments = @()
    if ($GodotVerbose) {
        $godotArguments += "--verbose"
    }
    $godotArguments += @(
        "--headless",
        "--path", $projectPath,
        "--log-file", $engineLog,
        "--script", $PeerScript,
        "--",
        $peerRunMarker,
        "--probe-role=$Role",
        "--probe-name=$Name",
        "--probe-host=127.0.0.1",
        "--probe-port=$Port",
        "--probe-expected_players=$PlayerCount",
        "--probe-timeout_seconds=12",
        "--probe-run_seconds=$RunSeconds",
        "--probe-linger_seconds=$LingerSeconds",
        "--probe-events=$Events",
        "--probe-scenario=$Scenario",
        "--probe-game_mode=$GameMode"
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
        Name = $Name
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

    $entries += Start-ProbePeer -Role "host" -Name "host" -RunSeconds 3.0
    for ($clientIndex = 2; $clientIndex -le $PlayerCount; $clientIndex++) {
        $delayMs = if ($clientIndex -eq 2) { 350 } else { 150 }
        $entries += Start-ProbePeer `
            -Role "client" `
            -Name "client$clientIndex" `
            -StartDelayMs $delayMs `
            -RunSeconds 2.0 `
            -LingerSeconds 6.0 `
            -Events ($Scenario -eq "full" -and $clientIndex -eq 2)
    }

    Wait-LanProbePeerProcesses $context $entries $TimeoutSeconds
    foreach ($entry in $entries) {
        Complete-LanProbePeerLogs $entry
    }
    foreach ($entry in $entries) {
        try {
            $null = Assert-LanProbePeerTruth $entry "LAN_PROBE_OK"
            Write-Output (
                "[$($entry.Name)] LAN_PROBE_OK " +
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
        [Console]::Error.WriteLine("MULTIPLAYER_LAN_PROBE_FAILED: $failure")
    }
    [Console]::Error.WriteLine("LAN probe logs preserved at: $logRoot")
    exit 1
}

Write-Output (
    "MULTIPLAYER_LAN_PROBE_OK scenario=$Scenario gameMode=$GameMode " +
    "players=$PlayerCount logRoot=$logRoot"
)
exit 0
