[CmdletBinding()]
param(
    [string]$GodotExe = "C:\Program Files\Godot\Godot_console.exe",
    [int]$Port = 40230,
    [int]$TimeoutSeconds = 130,
    [ValidateSet("handshake", "full", "leave", "wave", "tower_defense", "reconnect")]
    [string]$Scenario = "full",
    [ValidateSet("standard", "tower_defense")]
    [string]$GameMode = "standard",
    [ValidateRange(2, 8)]
    [int]$PlayerCount = 4,
    [switch]$GodotVerbose,
    [string]$ProjectPath = "",
    [string]$PeerScript = "res://dev_tools/multiplayer_lan_probe_peer.gd",
    [string[]]$PeerExtraArguments = @(),
    [string]$RelayProjectPath = "",
    [string[]]$RelayExtraArguments = @(),
    [ValidateRange(1, 120)]
    [int]$RelayStartupIdleTimeoutSeconds = 30,
    [ValidateRange(1, 30)]
    [int]$RelayEmptyIdleTimeoutSeconds = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lan_probe_truth_common.ps1")

if ($Scenario -eq "reconnect" -and $PlayerCount -ne 4) {
    throw "The reconnect probe currently requires -PlayerCount 4."
}

$reconnectToken = "44444444444444444444444444444444"
$resolvedProjectPath = if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
    (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}
else {
    (Resolve-Path -LiteralPath $ProjectPath).Path
}
$resolvedRelayProjectPath = if ([string]::IsNullOrWhiteSpace($RelayProjectPath)) {
    Join-Path $resolvedProjectPath "relay_servers\relay_godot_project"
}
else {
    (Resolve-Path -LiteralPath $RelayProjectPath).Path
}
$runId = [Guid]::NewGuid().ToString("N")
$runMarkerPrefix = "--arc-relay-probe-run-id=$runId"
$logRoot = Join-Path $env:TEMP "arc-nice-relay-probe-$runId"
$context = New-LanProbeTruthContext $runId $runMarkerPrefix
$entries = @()
$failures = [Collections.Generic.List[string]]::new()
$hostPeerId = 0
$script:relayProbeDeadlineUtc = [DateTime]::MinValue


function Format-RelayProbeSeconds {
    param([Parameter(Mandatory = $true)][double]$Value)

    return [string]::Format(
        [Globalization.CultureInfo]::InvariantCulture,
        "{0:F3}",
        $Value
    )
}


function Get-RelayProbeRemainingSeconds {
    $remaining = [Math]::Ceiling(
        ($script:relayProbeDeadlineUtc - [DateTime]::UtcNow).TotalSeconds
    )
    if ($remaining -le 0) {
        throw "Relay probe exceeded its $TimeoutSeconds-second global timeout."
    }
    return [int]$remaining
}


function Start-RelayProbeManagedEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $stdout = Join-Path $logRoot "$Name.out.log"
    $stderr = Join-Path $logRoot "$Name.err.log"
    $engineLog = Join-Path $logRoot "$Name.godot.log"
    $managedArguments = @("--log-file", $engineLog) + $Arguments
    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllLines(
        (Join-Path $logRoot "$Name.args.txt"),
        [string[]]$managedArguments,
        $utf8NoBom
    )

    $launched = Start-LanProbeManagedProcess `
        $context `
        $GodotExe `
        $WorkingDirectory `
        $managedArguments `
        -EnableLiveLineCapture
    return [pscustomobject]@{
        Name = $Name
        Role = $Role
        Process = $launched.Process
        StdoutTask = $launched.StdoutTask
        StderrTask = $launched.StderrTask
        LiveLineCapture = $launched.LiveLineCapture
        StdoutBuffer = $launched.StdoutBuffer
        StderrBuffer = $launched.StderrBuffer
        StdoutClosed = $launched.StdoutClosed
        StderrClosed = $launched.StderrClosed
        LogsCompleted = $false
        Stdout = $stdout
        Stderr = $stderr
        EngineLog = $engineLog
    }
}


function Start-RelayProbePeer {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][int]$RelayHostPeerId,
        [int]$StartDelayMs = 0,
        [bool]$Events = $false,
        [string]$ReconnectIdentity = "",
        [bool]$ReconnectAttempt = $false
    )

    if ($StartDelayMs -gt 0) {
        $null = Get-RelayProbeRemainingSeconds
        Watch-LanProbeProcessOwnership $context $StartDelayMs
    }
    $peerRunMarker = "$runMarkerPrefix-$Name"
    $arguments = @()
    if ($GodotVerbose) {
        $arguments += "--verbose"
    }
    $arguments += @(
        "--headless",
        "--path", $resolvedProjectPath,
        "--script", $PeerScript,
        "--",
        $peerRunMarker,
        "--probe-role=$Role",
        "--probe-mode=relay",
        "--probe-name=$($Name -replace '_rejoin$', '')",
        "--probe-host=127.0.0.1",
        "--probe-port=$Port",
        "--probe-relay_host_peer_id=$RelayHostPeerId",
        "--probe-expected_players=$PlayerCount",
        "--probe-timeout_seconds=20",
        "--probe-run_seconds=$(if ($Role -eq 'host') { 3 } else { 2 })",
        "--probe-linger_seconds=$(if ($Role -eq 'host') { 0 } else { 6 })",
        "--probe-events=$Events",
        "--probe-scenario=$Scenario",
        "--probe-game_mode=$GameMode"
    )
    if (-not [string]::IsNullOrEmpty($ReconnectIdentity)) {
        $arguments += @(
            "--probe-reconnect_token=$ReconnectIdentity",
            "--probe-reconnect_attempt=$ReconnectAttempt"
        )
    }
    foreach ($extraArgument in $PeerExtraArguments) {
        $arguments += [string]$extraArgument
    }
    return Start-RelayProbeManagedEntry `
        $Name `
        $Role `
        $resolvedProjectPath `
        $arguments
}


function Wait-RelayProbeStdoutPattern {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Description
    )

    do {
        $null = Update-LanProbeOwnedProcessRegistry $context
        Update-LanProbeLiveLineCapture $Entry
        $currentMatches = [regex]::Matches(
            $Entry.StdoutBuffer.ToString(),
            $Pattern
        )
        if ($currentMatches.Count -gt 0) {
            return $currentMatches
        }
        if ($Entry.Process.HasExited) {
            Complete-LanProbePeerLogs $Entry
            # 进程退出与异步逐行读取可能同帧发生；完成 drain 后必须复核最后一行。
            $finalMatches = [regex]::Matches(
                $Entry.StdoutBuffer.ToString(),
                $Pattern
            )
            if ($finalMatches.Count -gt 0) {
                return $finalMatches
            }
            throw (
                "$Description was not observed before $($Entry.Name) exited " +
                "with code $([int]$Entry.Process.ExitCode)."
            )
        }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $script:relayProbeDeadlineUtc)
    throw "$Description was not observed before the global timeout."
}


try {
    if (-not (Test-Path -LiteralPath $GodotExe -PathType Leaf)) {
        throw "Godot console executable does not exist: $GodotExe"
    }
    if ($TimeoutSeconds -le 0) {
        throw "TimeoutSeconds must be positive."
    }
    if (-not (Test-Path -LiteralPath $resolvedRelayProjectPath -PathType Container)) {
        throw "Relay project directory does not exist: $resolvedRelayProjectPath"
    }
    New-Item -ItemType Directory -Path $logRoot -ErrorAction Stop | Out-Null
    $script:relayProbeDeadlineUtc = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    $relayMaxLifetimeSeconds = [Math]::Max($TimeoutSeconds + 30, 60)
    $relayRunMarker = "$runMarkerPrefix-relay"
    $relayArguments = @(
        "--headless",
        "--path", $resolvedRelayProjectPath,
        "--",
        $relayRunMarker,
        "--port=$Port",
        "--max-clients=$PlayerCount",
        "--startup-idle-timeout=$RelayStartupIdleTimeoutSeconds",
        "--empty-idle-timeout=$RelayEmptyIdleTimeoutSeconds",
        "--max-lifetime=$relayMaxLifetimeSeconds"
    )
    foreach ($extraArgument in $RelayExtraArguments) {
        $relayArguments += [string]$extraArgument
    }
    $relayEntry = Start-RelayProbeManagedEntry `
        "relay" `
        "relay" `
        $resolvedRelayProjectPath `
        $relayArguments
    $entries += $relayEntry

    $relayReadyMarker = (
        "[Relay] 服务器已启动, port=$Port, max_clients=$PlayerCount, " +
        "protocol=v81, " +
        "startup_idle=$(Format-RelayProbeSeconds $RelayStartupIdleTimeoutSeconds), " +
        "empty_idle=$(Format-RelayProbeSeconds $RelayEmptyIdleTimeoutSeconds), " +
        "max_lifetime=$(Format-RelayProbeSeconds $relayMaxLifetimeSeconds), " +
        "server_relay=true"
    )
    $relayReadyPattern = "(?m)^$([regex]::Escape($relayReadyMarker))`r?$"
    $null = Wait-RelayProbeStdoutPattern `
        $relayEntry `
        $relayReadyPattern `
        "Relay exact ready marker"
    # Windows 上 server-ready 日志可早于 UDP 监听线程完成一次调度；保留
    # 一次有所有权采样的短稳定窗，仍由同一全局 deadline 约束。
    Watch-LanProbeProcessOwnership $context 1000

    $hostEntry = Start-RelayProbePeer `
        -Name "host" `
        -Role "host" `
        -RelayHostPeerId 0
    $entries += $hostEntry
    $hostReadyPattern = '(?m)^RELAY_PROBE_HOST_READY host_peer_id=(\d+)\r?$'
    $hostReadyMatches = Wait-RelayProbeStdoutPattern `
        $hostEntry `
        $hostReadyPattern `
        "Host relay peer identity"
    $hostPeerId = [int]$hostReadyMatches[0].Groups[1].Value
    if ($hostPeerId -le 1) {
        throw "Relay host peer id must be greater than 1; saw $hostPeerId."
    }
    Write-Output "Relay host peer id: $hostPeerId"

    for ($clientIndex = 2; $clientIndex -le $PlayerCount; $clientIndex++) {
        $clientName = "client$clientIndex"
        $delayMs = if ($clientIndex -eq 2) { 0 } else { 150 }
        $clientReconnectToken = if (
            $Scenario -eq "reconnect" -and $clientName -eq "client4"
        ) {
            $reconnectToken
        }
        else {
            ""
        }
        $entries += Start-RelayProbePeer `
            -Name $clientName `
            -Role "client" `
            -RelayHostPeerId $hostPeerId `
            -StartDelayMs $delayMs `
            -Events ($clientIndex -eq 2) `
            -ReconnectIdentity $clientReconnectToken `
            -ReconnectAttempt $false
    }

    if ($Scenario -eq "reconnect") {
        $reconnectReadyPattern = (
            '(?m)^LAN_PROBE_EVENT reconnect_slot_open old_peer=\d+\r?$'
        )
        $null = Wait-RelayProbeStdoutPattern `
            $hostEntry `
            $reconnectReadyPattern `
            "Host reconnect slot marker"
        $entries += Start-RelayProbePeer `
            -Name "client4_rejoin" `
            -Role "client" `
            -RelayHostPeerId $hostPeerId `
            -Events $false `
            -ReconnectIdentity $reconnectToken `
            -ReconnectAttempt $true
    }

    $remainingTimeoutSeconds = Get-RelayProbeRemainingSeconds
    Wait-LanProbePeerProcesses `
        $context `
        $entries `
        $remainingTimeoutSeconds
    # Relay 与每个 peer 都由 Diagnostics.Process 直接托管，因此逐 entry
    # 证明真实退出码；console -> engine 后代只承担 PID 归属与零残留核实。
    Assert-LanProbeManagedEntryExitCodes $context $entries
    foreach ($entry in $entries) {
        Complete-LanProbePeerLogs $entry
    }

    $relayShutdownNoisePattern = Get-LanProbeRelayShutdownNoisePattern
    foreach ($entry in $entries) {
        try {
            if ($entry.Role -eq "relay") {
                $null = Assert-LanProbePeerTruth `
                    $entry `
                    $relayReadyMarker `
                    $relayShutdownNoisePattern
                Write-Output (
                    "[relay] exact ready marker " +
                    "(exit=0; owned launcher PID=$([int]$entry.Process.Id))"
                )
                continue
            }
            $truth = Assert-LanProbePeerTruth $entry "LAN_PROBE_OK"
            if ($entry.Name -eq "host") {
                $readyStdoutCount = [regex]::Matches(
                    $truth.Stdout,
                    $hostReadyPattern
                ).Count
                $readyStderrCount = [regex]::Matches(
                    $truth.Stderr,
                    $hostReadyPattern
                ).Count
                if ($readyStdoutCount -ne 1 -or $readyStderrCount -ne 0) {
                    throw (
                        "host must emit exactly one exact relay peer identity line " +
                        "on stdout and none on stderr; stdout=$readyStdoutCount, " +
                        "stderr=$readyStderrCount."
                    )
                }
            }
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
    $failureDetail = $_.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) {
        $failureDetail += " Stack: $($_.ScriptStackTrace)"
    }
    $failures.Add($failureDetail)
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
    foreach ($entry in $entries) {
        Write-LanProbePeerLogs $entry
    }
    foreach ($failure in $failures) {
        [Console]::Error.WriteLine("MULTIPLAYER_RELAY_PROBE_FAILED: $failure")
    }
    [Console]::Error.WriteLine("Relay probe logs preserved at: $logRoot")
    exit 1
}

Write-Output (
    "MULTIPLAYER_RELAY_PROBE_OK scenario=$Scenario gameMode=$GameMode " +
    "players=$PlayerCount port=$Port hostPeerId=$hostPeerId logRoot=$logRoot"
)
exit 0
