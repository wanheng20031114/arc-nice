param(
    [string]$GodotExe = "C:\Users\wh\Downloads\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe",
    [int]$Port = 29270,
    [int]$TimeoutSeconds = 65,
    [ValidateSet("full", "leave", "wave")]
    [string]$Scenario = "full",
    [switch]$GodotVerbose
)

$ErrorActionPreference = "Stop"

$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$logRoot = Join-Path $env:TEMP ("arc-nice-lan-probe-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $logRoot | Out-Null

$processes = @()

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
        Start-Sleep -Milliseconds $StartDelayMs
    }

    $stdout = Join-Path $logRoot "$Name.out.log"
    $stderr = Join-Path $logRoot "$Name.err.log"
    $args = @()
    if ($GodotVerbose) {
        $args += "--verbose"
    }
    $args += @(
        "--headless",
        "--path", $projectPath,
        "--script", "dev_tools/multiplayer_lan_probe_peer.gd",
        "--",
        "--probe-role=$Role",
        "--probe-name=$Name",
        "--probe-host=127.0.0.1",
        "--probe-port=$Port",
        "--probe-expected_players=4",
        "--probe-timeout_seconds=12",
        "--probe-run_seconds=$RunSeconds",
        "--probe-linger_seconds=$LingerSeconds",
        "--probe-events=$Events",
        "--probe-scenario=$Scenario"
    )

    $process = Start-Process `
        -FilePath $GodotExe `
        -ArgumentList $args `
        -WorkingDirectory $projectPath `
        -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr `
        -WindowStyle Hidden `
        -PassThru

    [pscustomobject]@{
        Name = $Name
        Role = $Role
        Process = $process
        Stdout = $stdout
        Stderr = $stderr
    }
}

try {
    $processes += Start-ProbePeer -Role "host" -Name "host" -RunSeconds 3.0
    $processes += Start-ProbePeer -Role "client" -Name "client2" -StartDelayMs 350 -RunSeconds 2.0 -LingerSeconds 6.0 -Events ($Scenario -eq "full")
    $processes += Start-ProbePeer -Role "client" -Name "client3" -StartDelayMs 150 -RunSeconds 2.0 -LingerSeconds 6.0
    $processes += Start-ProbePeer -Role "client" -Name "client4" -StartDelayMs 150 -RunSeconds 2.0 -LingerSeconds 6.0

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $running = $processes | Where-Object { -not $_.Process.HasExited }
        if ($running.Count -eq 0) {
            break
        }
        Start-Sleep -Milliseconds 250
    }

    $timedOut = $false
    foreach ($entry in $processes) {
        if (-not $entry.Process.HasExited) {
            $timedOut = $true
            Stop-Process -Id $entry.Process.Id -Force
        }
        $entry.Process.WaitForExit()
    }

    $failed = $timedOut
    foreach ($entry in $processes) {
        $entry.Process.Refresh()
        Write-Host "==== $($entry.Name) stdout ===="
        $stdoutText = ""
        if (Test-Path $entry.Stdout) {
            $stdoutText = Get-Content $entry.Stdout -Raw
            Write-Host $stdoutText
        }
        Write-Host "==== $($entry.Name) stderr ===="
        if (Test-Path $entry.Stderr) {
            $stderrText = Get-Content $entry.Stderr -Raw
            Write-Host $stderrText
            if ($stderrText -match "Node not found|Invalid packet received|ERR_UNCONFIGURED|Unable to send packet|Trying to cast|ObjectDB instances leaked|resources still in use") {
                $failed = $true
                Write-Host "ERROR: $($entry.Name) produced network/runtime errors in stderr."
            }
        }
        if ($entry.Process.ExitCode -ne 0 -and $stdoutText -notmatch "LAN_PROBE_OK") {
            $failed = $true
            Write-Host "ERROR: $($entry.Name) exited with code $($entry.Process.ExitCode)."
        }
    }

    if ($timedOut) {
        Write-Host "ERROR: LAN probe timed out after $TimeoutSeconds seconds."
    }
    if ($failed) {
        exit 1
    }

    Write-Host "MULTIPLAYER_LAN_PROBE_OK scenario=$Scenario logRoot=$logRoot"
    exit 0
}
finally {
    foreach ($entry in $processes) {
        if ($entry.Process -ne $null -and -not $entry.Process.HasExited) {
            Stop-Process -Id $entry.Process.Id -Force
        }
    }
}
