[CmdletBinding()]
param(
    [string]$GodotExe = "C:\Program Files\Godot\Godot_console.exe"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$multiplayerRunner = Join-Path $PSScriptRoot "run_multiplayer_lan_probe.ps1"
$rogueRunner = Join-Path $PSScriptRoot "run_mp_rogue_route_lan_probe.ps1"
$fixtureProject = Join-Path $PSScriptRoot "fixtures\lan_probe_truth_project"
$fixtureScript = "res://lan_probe_truth_fixture.gd"
$smokeRunId = [Guid]::NewGuid().ToString("N")
$failures = [Collections.Generic.List[string]]::new()


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
    else {
        $runnerArguments.Port = 39071
    }

    $captured = @(& $Runner @runnerArguments 2>&1)
    $exitCode = [int]$LASTEXITCODE
    $capturedText = ($captured | ForEach-Object { [string]$_ }) -join "`n"
    $runnerMarker = if ($Family -eq "multiplayer") {
        "MULTIPLAYER_LAN_PROBE_OK"
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
