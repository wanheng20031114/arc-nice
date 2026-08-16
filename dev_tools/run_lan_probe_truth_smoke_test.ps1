[CmdletBinding()]
param(
    [string]$GodotExe = "C:\Program Files\Godot\Godot_console.exe"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$multiplayerRunner = Join-Path $PSScriptRoot "run_multiplayer_lan_probe.ps1"
$rogueRunner = Join-Path $PSScriptRoot "run_mp_rogue_route_lan_probe.ps1"
$relayRunner = Join-Path $PSScriptRoot "run_multiplayer_relay_probe.ps1"
$truthCommon = Join-Path $PSScriptRoot "lan_probe_truth_common.ps1"
$fixtureProject = Join-Path $PSScriptRoot "fixtures\lan_probe_truth_project"
$fixtureScript = "res://lan_probe_truth_fixture.gd"
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$relayProject = Join-Path $projectRoot "relay_servers\relay_godot_project"
$smokeRunId = [Guid]::NewGuid().ToString("N")
$failures = [Collections.Generic.List[string]]::new()

. $truthCommon


function Invoke-TruthFixtureCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Runner,
        [Parameter(Mandatory = $true)][string]$Family,
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][bool]$ExpectSuccess,
        [int]$TimeoutSeconds = 15
    )

    $runnerArguments = @{
        GodotExe = $GodotExe
        TimeoutSeconds = $TimeoutSeconds
        ProjectPath = $fixtureProject
        PeerScript = $fixtureScript
        PeerExtraArguments = @(
            "--probe-truth_fixture=$Family`:$Mode",
            "--truth-fixture-smoke-run-id=$smokeRunId"
        )
    }
    if ($Family -eq "multiplayer") {
        $runnerArguments.PlayerCount = 2
        $runnerArguments.Port = 39070
    }
    elseif ($Family -eq "relay") {
        $runnerArguments.PlayerCount = 2
        $runnerArguments.Port = 39072
        $runnerArguments.RelayProjectPath = $relayProject
        $runnerArguments.RelayExtraArguments = @(
            "--truth-fixture-smoke-run-id=$smokeRunId"
        )
        $runnerArguments.RelayStartupIdleTimeoutSeconds = 1
        $runnerArguments.RelayEmptyIdleTimeoutSeconds = 1
    }
    else {
        $runnerArguments.Port = 39071
    }

    $captured = @(& $Runner @runnerArguments 2>&1)
    $exitCode = [int]$LASTEXITCODE
    $capturedText = ($captured | ForEach-Object { [string]$_ }) -join "`n"
    $runnerMarker = if ($Family -eq "multiplayer") {
        "MULTIPLAYER_LAN_PROBE_OK"
    }
    elseif ($Family -eq "relay") {
        "MULTIPLAYER_RELAY_PROBE_OK"
    }
    else {
        "MP_ROGUE_ROUTE_LAN_PROBE_OK"
    }
    $markerCount = [regex]::Matches(
        $capturedText,
        "(?m)^$([regex]::Escape($runnerMarker))(?: .*)?`r?$"
    ).Count

    if ($ExpectSuccess) {
        if ($exitCode -ne 0 -or $markerCount -ne 1) {
            throw (
                "$Name expected exit 0 and one $runnerMarker line; " +
                "exit=$exitCode marker_count=$markerCount.`n$capturedText"
            )
        }
    }
    elseif ($exitCode -eq 0 -or $markerCount -ne 0) {
        throw (
            "$Name expected a non-zero exit and no $runnerMarker line; " +
            "exit=$exitCode marker_count=$markerCount.`n$capturedText"
        )
    }
    Write-Output "[$Name] OK"
}


function Invoke-RelayAllowedNoiseMultiplicityCase {
    $caseRunId = [Guid]::NewGuid().ToString("N")
    $runMarkerPrefix = "--relay-noise-truth-run-id=$caseRunId"
    $context = New-LanProbeTruthContext $caseRunId $runMarkerPrefix
    $logRoot = Join-Path $env:TEMP "arc-relay-noise-truth-$caseRunId"
    $entry = $null
    try {
        New-Item -ItemType Directory -Path $logRoot -ErrorAction Stop | Out-Null
        $stdout = Join-Path $logRoot "peer.out.log"
        $stderr = Join-Path $logRoot "peer.err.log"
        $engineLog = Join-Path $logRoot "peer.godot.log"
        $arguments = @(
            "--headless",
            "--path", $fixtureProject,
            "--log-file", $engineLog,
            "--script", $fixtureScript,
            "--",
            "$runMarkerPrefix-peer",
            "--probe-role=client",
            "--probe-truth_fixture=relay:pass",
            "--truth-fixture-smoke-run-id=$smokeRunId"
        )
        $launched = Start-LanProbeManagedProcess `
            $context `
            $GodotExe `
            $fixtureProject `
            $arguments
        $entry = [pscustomobject]@{
            Name = "relay-noise-peer"
            Role = "client"
            Process = $launched.Process
            StdoutTask = $launched.StdoutTask
            StderrTask = $launched.StderrTask
            LogsCompleted = $false
            Stdout = $stdout
            Stderr = $stderr
            EngineLog = $engineLog
        }
        Wait-LanProbePeerProcesses $context @($entry) 15
        Assert-LanProbeManagedEntryExitCodes $context @($entry)
        Complete-LanProbePeerLogs $entry

        $noiseBlock = (
            "ERROR: Unable to send packet on channel 0, max channels: 0`r`n" +
            "   at: send (modules/enet/enet_packet_peer.cpp:62)`r`n"
        )
        $engineText = [IO.File]::ReadAllText(
            $engineLog,
            [Text.Encoding]::UTF8
        )
        $utf8NoBom = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText(
            $engineLog,
            $engineText + "`r`n" + $noiseBlock,
            $utf8NoBom
        )
        # 单个完整关闭噪声块是唯一允许情形；第二个相同块随后必须
        # 触发重复门，避免 allowlist 演变成不限次数的吞错规则。
        $null = Assert-LanProbePeerTruth `
            $entry `
            "LAN_PROBE_OK" `
            (Get-LanProbeRelayShutdownNoisePattern)
        [IO.File]::AppendAllText($engineLog, $noiseBlock, $utf8NoBom)

        $duplicateRejected = $false
        try {
            $null = Assert-LanProbePeerTruth `
                $entry `
                "LAN_PROBE_OK" `
                (Get-LanProbeRelayShutdownNoisePattern)
        }
        catch {
            $duplicateRejected = $_.Exception.Message.Contains(
                "at most one is allowed"
            )
            if (-not $duplicateRejected) {
                throw
            }
        }
        if (-not $duplicateRejected) {
            throw "Relay duplicate allowed-noise blocks were accepted."
        }
    }
    finally {
        Stop-LanProbeOwnedProcessTree $context
        if ($null -ne $entry) {
            Complete-LanProbePeerLogs $entry
        }
        Close-LanProbeProcessHandles $context
    }
    Write-Output "[relay-duplicate-allowed-noise] OK"
}


try {
    if (-not (Test-Path -LiteralPath $GodotExe -PathType Leaf)) {
        throw "Godot console executable does not exist: $GodotExe"
    }
    Invoke-TruthFixtureCase `
        -Name "multiplayer-pass" `
        -Runner $multiplayerRunner `
        -Family "multiplayer" `
        -Mode "pass" `
        -ExpectSuccess $true
    Invoke-TruthFixtureCase `
        -Name "rogue-pass" `
        -Runner $rogueRunner `
        -Family "rogue" `
        -Mode "pass" `
        -ExpectSuccess $true
    # 这两项是旧 runner 的两个假绿条件，必须分别被拒绝。
    Invoke-TruthFixtureCase `
        -Name "exit-zero-without-marker" `
        -Runner $multiplayerRunner `
        -Family "multiplayer" `
        -Mode "missing_marker" `
        -ExpectSuccess $false
    Invoke-TruthFixtureCase `
        -Name "nonzero-with-marker" `
        -Runner $rogueRunner `
        -Family "rogue" `
        -Mode "nonzero_with_marker" `
        -ExpectSuccess $false
    Invoke-TruthFixtureCase `
        -Name "duplicate-marker" `
        -Runner $multiplayerRunner `
        -Family "multiplayer" `
        -Mode "duplicate_marker" `
        -ExpectSuccess $false
    Invoke-TruthFixtureCase `
        -Name "forbidden-stderr" `
        -Runner $rogueRunner `
        -Family "rogue" `
        -Mode "forbidden_stderr" `
        -ExpectSuccess $false
    Invoke-TruthFixtureCase `
        -Name "forbidden-stdout" `
        -Runner $multiplayerRunner `
        -Family "multiplayer" `
        -Mode "forbidden_stdout" `
        -ExpectSuccess $false
    Invoke-TruthFixtureCase `
        -Name "timeout-owned-cleanup" `
        -Runner $rogueRunner `
        -Family "rogue" `
        -Mode "hang" `
        -ExpectSuccess $false `
        -TimeoutSeconds 1
    # Relay runner 不能借用 LAN 的结论；这些反例都经过它自己的
    # Relay/peer exit code、精确 marker、engine log 与后代清理门。
    Invoke-TruthFixtureCase `
        -Name "relay-pass" `
        -Runner $relayRunner `
        -Family "relay" `
        -Mode "pass" `
        -ExpectSuccess $true
    Invoke-TruthFixtureCase `
        -Name "relay-nonzero-with-marker" `
        -Runner $relayRunner `
        -Family "relay" `
        -Mode "nonzero_with_marker" `
        -ExpectSuccess $false
    Invoke-TruthFixtureCase `
        -Name "relay-duplicate-marker" `
        -Runner $relayRunner `
        -Family "relay" `
        -Mode "duplicate_marker" `
        -ExpectSuccess $false
    Invoke-TruthFixtureCase `
        -Name "relay-engine-error" `
        -Runner $relayRunner `
        -Family "relay" `
        -Mode "engine_error" `
        -ExpectSuccess $false
    Invoke-TruthFixtureCase `
        -Name "relay-timeout-owned-cleanup" `
        -Runner $relayRunner `
        -Family "relay" `
        -Mode "hang" `
        -ExpectSuccess $false `
        -TimeoutSeconds 3
    Invoke-RelayAllowedNoiseMultiplicityCase
}
catch {
    $failures.Add($_.Exception.Message)
}

# runner 的 finally 必须已经清空本 smoke 的全部 Godot；这里只读复核，
# 不按进程名兜底停止，以免误伤用户编辑器或其他 agent。
$remaining = @()
foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction Stop)) {
    if ($null -eq $process.CommandLine) {
        continue
    }
    if (
        ([string]$process.CommandLine).Contains(
            "--truth-fixture-smoke-run-id=$smokeRunId"
        )
    ) {
        $remaining += $process
    }
}
if ($remaining.Count -ne 0) {
    $descriptions = @(
        $remaining | ForEach-Object { "$($_.Name) PID=$($_.ProcessId)" }
    )
    $failures.Add(
        "Truth smoke left owned processes running: $($descriptions -join ', ')"
    )
}

if ($failures.Count -ne 0) {
    foreach ($failure in $failures) {
        [Console]::Error.WriteLine("LAN_PROBE_TRUTH_SMOKE_TEST_FAILED: $failure")
    }
    exit 1
}

Write-Output "LAN_PROBE_TRUTH_SMOKE_TEST_OK"
exit 0
