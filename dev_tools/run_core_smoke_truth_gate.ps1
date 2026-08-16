[CmdletBinding()]
param(
    [string]$GodotExe = "C:\Program Files\Godot\Godot_console.exe"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$RunId = [Guid]::NewGuid().ToString("N")
$RunMarkerPrefix = "--arc-core-smoke-run-id=$RunId"
$TempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$RunDirectory = [IO.Path]::GetFullPath(
    (Join-Path $TempRoot "arc-core-smoke-truth-$RunId")
)
$script:OwnedIdentityByPid = @{}
$script:OwnedCreationUtcByPid = @{}
$script:ProcessHandleByPid = @{}

# 完整塔防场景目前会在 Godot 退出时报告资源/RID 错误。
# 这些错误必须保持可见；本门禁只纳入输出完全干净的用例。
$Cases = @()
$Cases += [pscustomobject]@{
    Name = "wave-system"
    Script = "res://dev_tools/wave_system_smoke_test.gd"
    Marker = "WAVE_SYSTEM_SMOKE_TEST_OK"
    TimeoutSeconds = 45
}
$Cases += [pscustomobject]@{
    Name = "capoo-mage-impact-pool"
    Script = "res://dev_tools/capoo_mage_impact_pool_smoke_test.gd"
    Marker = "CAPOO_MAGE_IMPACT_POOL_SMOKE_TEST_OK"
    TimeoutSeconds = 30
}
$Cases += [pscustomobject]@{
    Name = "zhuangfangyi-interaction-skill"
    Script = "res://dev_tools/zhuangfangyi_interaction_skill_smoke_test.gd"
    Marker = "ZHUANGFANGYI_INTERACTION_SKILL_SMOKE_TEST_OK"
    TimeoutSeconds = 45
}


function Get-CimIdentity {
    param([Parameter(Mandatory = $true)]$CimProcess)

    $creationUtc = ([DateTime]$CimProcess.CreationDate).ToUniversalTime()
    return "$([int]$CimProcess.ProcessId)|$($creationUtc.Ticks)"
}


function Test-IsGodotProcess {
    param([Parameter(Mandatory = $true)]$CimProcess)

    return (
        $CimProcess.Name -ieq "Godot.exe" -or
        $CimProcess.Name -ieq "Godot_console.exe"
    )
}


function Register-OwnedCimProcess {
    param([Parameter(Mandatory = $true)]$CimProcess)

    $processId = [int]$CimProcess.ProcessId
    if (-not $script:OwnedIdentityByPid.ContainsKey($processId)) {
        $script:OwnedIdentityByPid[$processId] = Get-CimIdentity $CimProcess
        $script:OwnedCreationUtcByPid[$processId] = (
            ([DateTime]$CimProcess.CreationDate).ToUniversalTime()
        )
    }
}


function Update-OwnedProcessRegistry {
    $snapshot = @(Get-CimInstance Win32_Process -ErrorAction Stop)

    # 唯一运行 ID 只会出现在本门禁启动的 Godot 命令行中。
    foreach ($process in $snapshot) {
        if (
            (Test-IsGodotProcess $process) -and
            $null -ne $process.CommandLine -and
            $process.CommandLine.Contains($RunMarkerPrefix)
        ) {
            Register-OwnedCimProcess $process
        }
    }

    # 同时追踪后代进程；子进程不要求继承 Godot 命令行参数。
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($process in $snapshot) {
            $processId = [int]$process.ProcessId
            $parentId = [int]$process.ParentProcessId
            if (
                $script:OwnedIdentityByPid.ContainsKey($processId) -or
                -not $script:OwnedIdentityByPid.ContainsKey($parentId)
            ) {
                continue
            }
            $creationUtc = ([DateTime]$process.CreationDate).ToUniversalTime()
            if ($creationUtc -lt $script:OwnedCreationUtcByPid[$parentId]) {
                continue
            }
            Register-OwnedCimProcess $process
            $changed = $true
        }
    }
    return $snapshot
}


function Get-LiveOwnedProcesses {
    $snapshot = @(Update-OwnedProcessRegistry)
    $result = @()
    foreach ($process in $snapshot) {
        $processId = [int]$process.ProcessId
        if (
            $script:OwnedIdentityByPid.ContainsKey($processId) -and
            $script:OwnedIdentityByPid[$processId] -eq (Get-CimIdentity $process)
        ) {
            $result += $process
        }
    }
    return $result
}


function Get-LiveCaseGodotProcesses {
    param([Parameter(Mandatory = $true)][string]$CaseMarker)

    $snapshot = @(Update-OwnedProcessRegistry)
    return @(
        $snapshot | Where-Object {
            (Test-IsGodotProcess $_) -and
            $null -ne $_.CommandLine -and
            $_.CommandLine.Contains($CaseMarker)
        }
    )
}


function Register-ProcessHandle {
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)

    if (-not $script:ProcessHandleByPid.ContainsKey($Process.Id)) {
        $script:ProcessHandleByPid[$Process.Id] = $Process
    }
}


function Stop-OwnedProcessTree {
    $live = @(Get-LiveOwnedProcesses)
    if ($live.Count -gt 0) {
        $parentByPid = @{}
        foreach ($process in $live) {
            $parentByPid[[int]$process.ProcessId] = [int]$process.ParentProcessId
        }
        $depthByPid = @{}
        foreach ($process in $live) {
            $processId = [int]$process.ProcessId
            $depth = 0
            $cursor = $processId
            $visited = @{}
            while (
                $parentByPid.ContainsKey($cursor) -and
                $parentByPid[$cursor] -ne 0 -and
                -not $visited.ContainsKey($cursor)
            ) {
                $visited[$cursor] = $true
                $cursor = $parentByPid[$cursor]
                $depth++
            }
            $depthByPid[$processId] = $depth
        }

        # 先停止后代，并且只处理已经证明属于本轮运行的 PID。
        foreach ($process in @($live | Sort-Object {
            -1 * $depthByPid[[int]$_.ProcessId]
        })) {
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
        }
    }

    foreach ($handle in $script:ProcessHandleByPid.Values) {
        try {
            if (-not $handle.HasExited) {
                $handle.WaitForExit(5000) | Out-Null
            }
            if ($handle.HasExited) {
                $handle.WaitForExit()
            }
        }
        catch {
            # 下方 CIM 复核才是最终依据；句柄清理仅作尽力处理。
        }
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $remaining = @(Get-LiveOwnedProcesses)
        if ($remaining.Count -eq 0) {
            return
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)

    $remainingDescriptions = @(
        $remaining | ForEach-Object {
            "$($_.Name) PID=$($_.ProcessId)"
        }
    )
    throw "Owned process cleanup failed: $($remainingDescriptions -join ', ')"
}


function Assert-CleanOutput {
    param(
        [Parameter(Mandatory = $true)][string]$CaseName,
        [Parameter(Mandatory = $true)][string]$ExpectedMarker,
        [Parameter(Mandatory = $true)][string]$CombinedOutput
    )

    $forbidden = [regex]::Match(
        $CombinedOutput,
        "SCRIPT ERROR|Parse Error|Failed to load script|(?m)^ERROR"
    )
    if ($forbidden.Success) {
        throw "$CaseName emitted forbidden engine output: $($forbidden.Value)"
    }

    $markerPattern = "(?m)^$([regex]::Escape($ExpectedMarker))`r?$"
    $markerMatches = [regex]::Matches($CombinedOutput, $markerPattern)
    if ($markerMatches.Count -ne 1) {
        throw (
            "$CaseName must emit exactly one exact $ExpectedMarker line; " +
            "found $($markerMatches.Count)."
        )
    }
}


function Invoke-CoreSmokeCase {
    param(
        [Parameter(Mandatory = $true)]$Case,
        [Parameter(Mandatory = $true)][int]$CaseIndex
    )

    $caseRunId = "$RunId-$CaseIndex"
    $caseMarker = "--arc-core-smoke-run-id=$caseRunId"
    $stdoutPath = Join-Path $RunDirectory "$($Case.Name).stdout.log"
    $stderrPath = Join-Path $RunDirectory "$($Case.Name).stderr.log"
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $GodotExe
    $startInfo.WorkingDirectory = $ProjectRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Arguments = (
        "--headless --path `"$ProjectRoot`" " +
        "--script `"$($Case.Script)`" -- $caseMarker"
    )

    $launcher = [Diagnostics.Process]::new()
    $launcher.StartInfo = $startInfo
    if (-not $launcher.Start()) {
        throw "$($Case.Name) failed to start Godot."
    }
    Register-ProcessHandle $launcher
    $caseProcessIds = @([int]$launcher.Id)
    $stdoutTask = $launcher.StandardOutput.ReadToEndAsync()
    $stderrTask = $launcher.StandardError.ReadToEndAsync()

    $deadline = [DateTime]::UtcNow.AddSeconds([int]$Case.TimeoutSeconds)
    $completed = $false
    do {
        # WaitForExit 负责确认直接启动的进程；CIM 额外追踪可能发生的
        # Godot_console 到 Godot 引擎进程交接。
        if (-not $launcher.HasExited) {
            $launcher.WaitForExit(100) | Out-Null
        }
        $liveCaseEngines = @(Get-LiveCaseGodotProcesses $caseMarker)
        foreach ($engine in $liveCaseEngines) {
            $enginePid = [int]$engine.ProcessId
            if ($caseProcessIds -notcontains $enginePid) {
                $caseProcessIds += $enginePid
            }
            if (-not $script:ProcessHandleByPid.ContainsKey($enginePid)) {
                try {
                    Register-ProcessHandle ([Diagnostics.Process]::GetProcessById($enginePid))
                }
                catch {
                    # 进程可能在 CIM 快照后退出，留到下一轮轮询复核。
                }
            }
        }
        if ($launcher.HasExited -and $liveCaseEngines.Count -eq 0) {
            $completed = $true
            break
        }
    } while ([DateTime]::UtcNow -lt $deadline)

    if (-not $completed) {
        throw "$($Case.Name) exceeded its $($Case.TimeoutSeconds)-second timeout."
    }

    $launcher.WaitForExit()
    $launcherExitCode = $launcher.ExitCode
    if ($null -eq $launcherExitCode) {
        throw "$($Case.Name) did not expose an exit code after WaitForExit."
    }
    if ([int]$launcherExitCode -ne 0) {
        throw "$($Case.Name) exited with code $launcherExitCode."
    }

    # Godot_console 会传递引擎退出状态；交接得到的句柄也必须显式
    # WaitForExit，然后再由 CIM 确认没有带本轮标记的引擎残留。
    foreach ($caseProcessId in $caseProcessIds) {
        if ($caseProcessId -eq [int]$launcher.Id) {
            continue
        }
        if (-not $script:ProcessHandleByPid.ContainsKey($caseProcessId)) {
            continue
        }
        $caseProcess = $script:ProcessHandleByPid[$caseProcessId]
        $caseProcess.WaitForExit()
    }

    $stdout = [string]$stdoutTask.Result
    $stderr = [string]$stderrTask.Result
    [IO.File]::WriteAllText($stdoutPath, $stdout, [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($stderrPath, $stderr, [Text.Encoding]::UTF8)
    $combinedOutput = $stdout + "`n" + $stderr

    try {
        Assert-CleanOutput $Case.Name $Case.Marker $combinedOutput
    }
    catch {
        [Console]::Error.WriteLine("[$($Case.Name)] captured output:")
        [Console]::Error.WriteLine($combinedOutput)
        throw
    }

    $liveAfterExit = @(Get-LiveCaseGodotProcesses $caseMarker)
    if ($liveAfterExit.Count -ne 0) {
        throw "$($Case.Name) left a marked Godot engine running after WaitForExit."
    }
    $casePidList = (@($caseProcessIds | Sort-Object -Unique) -join ",")
    Write-Output (
        "[$($Case.Name)] OK (owned PIDs=$casePidList; " +
        "marked engine exit verified by CIM)"
    )
}


$failures = [Collections.Generic.List[string]]::new()
try {
    if (-not (Test-Path -LiteralPath $GodotExe -PathType Leaf)) {
        throw "Godot console executable does not exist: $GodotExe"
    }
    New-Item -ItemType Directory -Path $RunDirectory -ErrorAction Stop | Out-Null

    for ($caseIndex = 0; $caseIndex -lt $Cases.Count; $caseIndex++) {
        Invoke-CoreSmokeCase $Cases[$caseIndex] $caseIndex
    }
}
catch {
    $failures.Add($_.Exception.Message)
}
finally {
    try {
        Stop-OwnedProcessTree
    }
    catch {
        $failures.Add($_.Exception.Message)
    }

    foreach ($handle in $script:ProcessHandleByPid.Values) {
        try {
            $handle.Dispose()
        }
        catch {
        }
    }

    try {
        $expectedPrefix = $TempRoot.TrimEnd('\') + '\'
        if (
            $RunDirectory.StartsWith(
                $expectedPrefix,
                [StringComparison]::OrdinalIgnoreCase
            ) -and
            (Split-Path -Leaf $RunDirectory) -eq "arc-core-smoke-truth-$RunId" -and
            (Test-Path -LiteralPath $RunDirectory -PathType Container)
        ) {
            Remove-Item -LiteralPath $RunDirectory -Recurse -Force
        }
    }
    catch {
        $failures.Add("Temporary log cleanup failed: $($_.Exception.Message)")
    }
}

if ($failures.Count -ne 0) {
    foreach ($failure in $failures) {
        [Console]::Error.WriteLine("CORE_SMOKE_TRUTH_GATE_FAILED: $failure")
    }
    exit 1
}

Write-Output "CORE_SMOKE_TRUTH_GATE_OK"
exit 0
