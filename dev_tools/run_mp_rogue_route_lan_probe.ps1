param(
    [string]$GodotExe = "C:\Program Files\Godot\Godot_console.exe",
    [int]$Port = 29386,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = "Stop"
$projectPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$logRoot = Join-Path $env:TEMP ("arc-nice-p3-lan-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $logRoot | Out-Null
$entries = @()

function Start-P3Peer {
    param([string]$Role)

    $stdout = Join-Path $logRoot "$Role.out.log"
    $stderr = Join-Path $logRoot "$Role.err.log"
    $engineLog = Join-Path $logRoot "$Role.godot.log"
    $arguments = @(
        "--headless",
        "--path", $projectPath,
        "--log-file", $engineLog,
        "--script", "dev_tools/mp_rogue_route_lan_probe_peer.gd",
        "--",
        "--probe-role=$Role",
        "--probe-port=$Port"
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
    }
}

try {
    $entries += Start-P3Peer -Role "host"
    Start-Sleep -Milliseconds 350
    $entries += Start-P3Peer -Role "client"

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
            Write-Host $stdoutText
        }
        if (Test-Path $entry.Stderr) {
            $stderrText = Get-Content $entry.Stderr -Raw
            Write-Host $stderrText
        }
        $expectedMarker = "MP_ROGUE_ROUTE_LAN_$($entry.Role.ToUpper())_OK"
        $markerFound = ([string]$stdoutText).Contains($expectedMarker)
        $stderrString = if ($null -eq $stderrText) { "" } else { [string]$stderrText }
        $stderrHasRuntimeError = (
            $stderrString.Contains("SCRIPT ERROR") `
            -or $stderrString.Contains("Node not found") `
            -or $stderrString.Contains("Invalid packet received")
        )
        Write-Host (
            "P3 LAN {0}: marker={1} runtime_error={2}" -f `
            $entry.Role, $markerFound, $stderrHasRuntimeError
        )
        if (
            -not $markerFound `
            -or $stderrHasRuntimeError
        ) {
            $failed = $true
        }
    }

    if ($failed) {
        Write-Error "P3 LAN probe failed. Logs: $logRoot"
        exit 1
    }
    Write-Host "MP_ROGUE_ROUTE_LAN_PROBE_OK logs=$logRoot"
    exit 0
}
finally {
    foreach ($entry in $entries) {
        if ($entry.Process -ne $null -and -not $entry.Process.HasExited) {
            Stop-Process -Id $entry.Process.Id -Force
        }
    }
}
