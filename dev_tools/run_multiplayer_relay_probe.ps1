param(
    [string]$GodotExe = "C:\Program Files\Godot\Godot_console.exe",
    [int]$Port = 40230,
    [int]$TimeoutSeconds = 130,
    [ValidateSet("full", "leave", "wave", "tower_defense")]
    [string]$Scenario = "full",
    [ValidateSet("standard", "tower_defense")]
    [string]$GameMode = "standard",
    [switch]$GodotVerbose
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$relayProjectPath = Join-Path $projectPath "relay_servers\relay_godot_project"
$logRoot = Join-Path $env:TEMP ("arc-nice-relay-probe-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $logRoot | Out-Null

$entries = @()

try {
    $relayStdout = Join-Path $logRoot "relay.out.log"
    $relayStderr = Join-Path $logRoot "relay.err.log"
    $relayArgs = @(
        "--headless",
        "--path", $relayProjectPath,
        "--",
        "--port=$Port"
    )
    Set-Content -Path (Join-Path $logRoot "relay.args.txt") -Encoding UTF8 -Value ($relayArgs -join "`n")
    $relayProcess = Start-Process `
        -FilePath $GodotExe `
        -ArgumentList $relayArgs `
        -WorkingDirectory $relayProjectPath `
        -RedirectStandardOutput $relayStdout `
        -RedirectStandardError $relayStderr `
        -WindowStyle Hidden `
        -PassThru
    $entries += [pscustomobject]@{
        Name = "relay"
        Process = $relayProcess
        Stdout = $relayStdout
        Stderr = $relayStderr
    }

    Start-Sleep -Seconds 5

    $hostStdout = Join-Path $logRoot "host.out.log"
    $hostStderr = Join-Path $logRoot "host.err.log"
    $hostArgs = @()
    if ($GodotVerbose) {
        $hostArgs += "--verbose"
    }
    $hostArgs += @(
        "--headless",
        "--path", $projectPath,
        "--script", "res://dev_tools/multiplayer_lan_probe_peer.gd",
        "--",
        "--probe-role=host",
        "--probe-mode=relay",
        "--probe-name=host",
        "--probe-host=127.0.0.1",
        "--probe-port=$Port",
        "--probe-relay_host_peer_id=0",
        "--probe-expected_players=4",
        "--probe-timeout_seconds=20",
        "--probe-run_seconds=3",
        "--probe-linger_seconds=0",
        "--probe-events=False",
        "--probe-scenario=$Scenario",
        "--probe-game_mode=$GameMode"
    )
    Set-Content -Path (Join-Path $logRoot "host.args.txt") -Encoding UTF8 -Value ($hostArgs -join "`n")
    $hostProcess = Start-Process `
        -FilePath $GodotExe `
        -ArgumentList $hostArgs `
        -WorkingDirectory $projectPath `
        -RedirectStandardOutput $hostStdout `
        -RedirectStandardError $hostStderr `
        -WindowStyle Hidden `
        -PassThru
    $entries += [pscustomobject]@{
        Name = "host"
        Process = $hostProcess
        Stdout = $hostStdout
        Stderr = $hostStderr
    }

    Start-Sleep -Seconds 8
    $hostText = ""
    if (Test-Path $hostStdout) {
        $hostText = Get-Content $hostStdout -Raw
    }
    if ($hostText -notmatch "RELAY_PROBE_HOST_READY host_peer_id=(\d+)") {
        throw "Host did not report relay host peer id. logRoot=$logRoot"
    }
    $hostPeerId = [int]$Matches[1]
    if ($hostPeerId -le 1) {
        throw "Relay host peer id must not be 1; saw $hostPeerId. logRoot=$logRoot"
    }
    Write-Host "Relay host peer id: $hostPeerId"

    $clientBaseArgs = @()
    if ($GodotVerbose) {
        $clientBaseArgs += "--verbose"
    }
    $clientBaseArgs += @(
        "--headless",
        "--path", $projectPath,
        "--script", "res://dev_tools/multiplayer_lan_probe_peer.gd",
        "--",
        "--probe-role=client",
        "--probe-mode=relay",
        "--probe-host=127.0.0.1",
        "--probe-port=$Port",
        "--probe-relay_host_peer_id=$hostPeerId",
        "--probe-expected_players=4",
        "--probe-timeout_seconds=20",
        "--probe-run_seconds=2",
        "--probe-linger_seconds=6",
        "--probe-scenario=$Scenario",
        "--probe-game_mode=$GameMode"
    )

    foreach ($clientSpec in @(
        @{ Name = "client2"; DelayMs = 0; Events = "True" },
        @{ Name = "client3"; DelayMs = 150; Events = "False" },
        @{ Name = "client4"; DelayMs = 150; Events = "False" }
    )) {
        if ($clientSpec.DelayMs -gt 0) {
            Start-Sleep -Milliseconds $clientSpec.DelayMs
        }
        $clientName = $clientSpec.Name
        $clientStdout = Join-Path $logRoot "$clientName.out.log"
        $clientStderr = Join-Path $logRoot "$clientName.err.log"
        $clientArgs = $clientBaseArgs + @(
            "--probe-name=$clientName",
            "--probe-events=$($clientSpec.Events)"
        )
        Set-Content -Path (Join-Path $logRoot "$clientName.args.txt") -Encoding UTF8 -Value ($clientArgs -join "`n")
        $clientProcess = Start-Process `
            -FilePath $GodotExe `
            -ArgumentList $clientArgs `
            -WorkingDirectory $projectPath `
            -RedirectStandardOutput $clientStdout `
            -RedirectStandardError $clientStderr `
            -WindowStyle Hidden `
            -PassThru
        $entries += [pscustomobject]@{
            Name = $clientName
            Process = $clientProcess
            Stdout = $clientStdout
            Stderr = $clientStderr
        }
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $runningPeers = $entries | Where-Object {
            $_.Name -ne "relay" -and -not $_.Process.HasExited
        }
        if ($runningPeers.Count -eq 0) {
            break
        }
        Start-Sleep -Milliseconds 250
    }

    $timedOut = $false
    foreach ($entry in $entries) {
        if ($entry.Name -eq "relay") {
            continue
        }
        if (-not $entry.Process.HasExited) {
            $timedOut = $true
            Stop-Process -Id $entry.Process.Id -Force
        }
        $entry.Process.WaitForExit()
    }

    if (-not $relayProcess.HasExited) {
        $relayProcess.WaitForExit(5000) | Out-Null
    }
    if (-not $relayProcess.HasExited) {
        Stop-Process -Id $relayProcess.Id -Force
        $relayProcess.WaitForExit()
    }

    $failed = $timedOut
    foreach ($entry in $entries) {
        $entry.Process.Refresh()
        $stdoutText = ""
        $stderrText = ""
        if (Test-Path $entry.Stdout) {
            $stdoutText = Get-Content $entry.Stdout -Raw
        }
        if (Test-Path $entry.Stderr) {
            $stderrText = Get-Content $entry.Stderr -Raw
        }
        Write-Host "==== $($entry.Name) stdout ===="
        Write-Host $stdoutText
        Write-Host "==== $($entry.Name) stderr ===="
        Write-Host $stderrText
        if ($entry.Name -ne "relay" -and $stdoutText -notmatch "LAN_PROBE_OK") {
            $failed = $true
            Write-Host "ERROR: $($entry.Name) did not report LAN_PROBE_OK."
        }
        if ($entry.Name -eq "relay" -and $stdoutText -notmatch "server_relay=true") {
            $failed = $true
            Write-Host "ERROR: Relay did not report server_relay=true."
        }
        $effectiveStderr = $stderrText
        if ($entry.Name -eq "relay") {
            $effectiveStderr = $effectiveStderr -replace "ERROR: Unable to send packet on channel 0, max channels: 0\r?\n\s+at: send \(modules/enet/enet_packet_peer.cpp:62\)\r?\n", ""
        }
        if ($effectiveStderr -match "SCRIPT ERROR|Node not found|Invalid packet received|ERR_UNCONFIGURED|Unable to send packet|Trying to cast|ObjectDB instances leaked|resources still in use|RPC '.*' is not allowed|unknown peer ID|checksum failed|Failed to get cached node") {
            $failed = $true
            Write-Host "ERROR: $($entry.Name) produced network/runtime errors in stderr."
        }
    }

    if ($timedOut) {
        Write-Host "ERROR: Relay probe timed out after $TimeoutSeconds seconds."
    }
    if ($failed) {
        exit 1
    }

    Write-Host "MULTIPLAYER_RELAY_PROBE_OK scenario=$Scenario gameMode=$GameMode port=$Port hostPeerId=$hostPeerId logRoot=$logRoot"
    exit 0
}
finally {
    foreach ($entry in $entries) {
        if ($entry.Process -ne $null -and -not $entry.Process.HasExited) {
            Stop-Process -Id $entry.Process.Id -Force
            $entry.Process.WaitForExit()
        }
    }
}
