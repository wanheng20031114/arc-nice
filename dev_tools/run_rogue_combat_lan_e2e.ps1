param(
    [string]$GodotExe = "C:\Program Files\Godot\Godot_console.exe",
    [int]$Port = 29472,
    [int]$TimeoutSeconds = 110
)

$ErrorActionPreference = "Stop"
$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$logRoot = Join-Path $env:TEMP ("arc-nice-rogue-combat-e2e-" + [guid]::NewGuid().ToString("N"))
$syncRoot = Join-Path $logRoot "sync"
New-Item -ItemType Directory -Path $syncRoot -Force | Out-Null
$entries = @()

function Stop-RogueCombatProbeProcesses {
    $probeProcesses = @(
        Get-CimInstance Win32_Process | Where-Object {
            $_.Name -in @("Godot.exe", "Godot_console.exe") -and
            $_.CommandLine -like "*rogue_combat_lan_e2e_peer.gd*" -and
            $_.CommandLine -like "*$syncRoot*"
        }
    )
    foreach ($probeProcess in $probeProcesses) {
        Stop-Process -Id $probeProcess.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Start-RogueCombatPeer {
    param([string]$Role)

    $stdout = Join-Path $logRoot "$Role.out.log"
    $stderr = Join-Path $logRoot "$Role.err.log"
    $engineLog = Join-Path $logRoot "$Role.godot.log"
    $arguments = @(
        "--headless",
        "--path", $projectPath,
        "--log-file", $engineLog,
        "--script", "res://dev_tools/rogue_combat_lan_e2e_peer.gd",
        "--",
        "--probe-role=$Role",
        "--probe-port=$Port",
        "--probe-sync_dir=$syncRoot"
    )
    $process = Start-Process `
        -FilePath $GodotExe `
        -ArgumentList $arguments `
        -WorkingDirectory $projectPath `
        -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr `
        -WindowStyle Hidden `
        -PassThru
    return [pscustomobject]@{
        Role = $Role
        Process = $process
        Stdout = $stdout
        Stderr = $stderr
        EngineLog = $engineLog
    }
}

try {
    $entries += Start-RogueCombatPeer -Role "host"
    Start-Sleep -Milliseconds 350
    $entries += Start-RogueCombatPeer -Role "client"

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (($entries | Where-Object { -not $_.Process.HasExited }).Count -eq 0) {
            break
        }
        Start-Sleep -Milliseconds 100
    }

    $failed = $false
    foreach ($entry in $entries) {
        if (-not $entry.Process.HasExited) {
            Stop-Process -Id $entry.Process.Id -Force
            $failed = $true
        }
        $entry.Process.WaitForExit()
        $entry.Process.Refresh()
        $stdoutText = ""
        $stderrText = ""
        if (Test-Path $entry.Stdout) {
            $stdoutText = Get-Content $entry.Stdout -Raw
        }
        if (Test-Path $entry.Stderr) {
            $stderrText = Get-Content $entry.Stderr -Raw
        }
        Write-Host "==== $($entry.Role) stdout ===="
        Write-Host $stdoutText
        Write-Host "==== $($entry.Role) stderr ===="
        Write-Host $stderrText

        $roleUpper = $entry.Role.ToUpper()
        $expectedMarker = "ROGUE_COMBAT_LAN_${roleUpper}_OK"
        $spawnEvidence = "ROGUE_COMBAT_LAN_${roleUpper}_SPAWN"
        $rewardEvidence = "ROGUE_COMBAT_LAN_${roleUpper}_REWARD"
        $resultEvidence = "ROGUE_COMBAT_LAN_${roleUpper}_INDEPENDENT_RESULT_OK"
        $runtimeError = [string]$stderrText -match (
            "SCRIPT ERROR|Node not found|Invalid packet received|" +
            "ERR_UNCONFIGURED|Unable to send packet|Trying to cast"
        )
        $hasEvidence = (
            ([string]$stdoutText).Contains($expectedMarker) -and
            ([string]$stdoutText).Contains($spawnEvidence) -and
            ([string]$stdoutText).Contains($rewardEvidence) -and
            ([string]$stdoutText).Contains($resultEvidence)
        )
        # Godot_console.exe can hand the engine process off and leave the
        # Process wrapper without an ExitCode. The per-peer completion marker
        # is the authoritative result in that case.
        $exitCode = $entry.Process.ExitCode
        $exitCodeOkay = $null -eq $exitCode -or $exitCode -eq 0
        Write-Host (
            "Rogue combat LAN {0}: exit={1} evidence={2} runtime_error={3}" -f `
            $entry.Role, $exitCode, $hasEvidence, $runtimeError
        )
        if (-not $exitCodeOkay -or -not $hasEvidence -or $runtimeError) {
            $failed = $true
        }
    }

    if ($failed) {
        Write-Error "Rogue combat LAN E2E failed. Logs: $logRoot"
        exit 1
    }
    Write-Host "ROGUE_COMBAT_LAN_E2E_OK logs=$logRoot"
    exit 0
}
finally {
    foreach ($entry in $entries) {
        if ($entry.Process -ne $null -and -not $entry.Process.HasExited) {
            Stop-Process -Id $entry.Process.Id -Force
        }
    }
    # Godot_console.exe can own a separate Godot.exe engine process. Match the
    # unique probe script + sync directory so an abnormal wrapper exit cannot
    # leave either endpoint behind, while never touching the user's editor.
    Stop-RogueCombatProbeProcesses
}
