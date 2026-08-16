Set-StrictMode -Version Latest


function New-LanProbeTruthContext {
    param(
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$RunMarkerPrefix
    )

    return [pscustomobject]@{
        RunId = $RunId
        RunMarkerPrefix = $RunMarkerPrefix
        OwnedIdentityByProcessId = @{}
        OwnedCreationUtcByProcessId = @{}
        ProcessHandleByProcessId = @{}
    }
}


function Get-LanProbeCimIdentity {
    param([Parameter(Mandatory = $true)]$CimProcess)

    $creationUtc = ([DateTime]$CimProcess.CreationDate).ToUniversalTime()
    return "$([int]$CimProcess.ProcessId)|$($creationUtc.Ticks)"
}


function Register-LanProbeOwnedCimProcess {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$CimProcess,
        [bool]$HasRunMarker = $false
    )

    $processId = [int]$CimProcess.ProcessId
    if (-not $Context.OwnedIdentityByProcessId.ContainsKey($processId)) {
        $creationUtc = ([DateTime]$CimProcess.CreationDate).ToUniversalTime()
        $Context.OwnedIdentityByProcessId[$processId] = (
            Get-LanProbeCimIdentity $CimProcess
        )
        $Context.OwnedCreationUtcByProcessId[$processId] = $creationUtc
    }
    if ($HasRunMarker) {
        if (-not $Context.ProcessHandleByProcessId.ContainsKey($processId)) {
            try {
                $handle = [Diagnostics.Process]::GetProcessById($processId)
                $handleCreationUtc = $handle.StartTime.ToUniversalTime()
                $cimCreationUtc = ([DateTime]$CimProcess.CreationDate).ToUniversalTime()
                $creationDelta = [Math]::Abs(
                    ($handleCreationUtc - $cimCreationUtc).TotalSeconds
                )
                if ($creationDelta -le 1.0) {
                    $Context.ProcessHandleByProcessId[$processId] = $handle
                }
                else {
                    $handle.Dispose()
                }
            }
            catch {
                # 交接进程可能在 CIM 快照后立即退出；其存活与清理由
                # PID+创建时间复核，peer launcher 的退出码仍单独强校验。
            }
        }
    }
}


function Register-LanProbeProcessHandle {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process
    )

    if (-not $Context.ProcessHandleByProcessId.ContainsKey([int]$Process.Id)) {
        $Context.ProcessHandleByProcessId[[int]$Process.Id] = $Process
    }
}


function ConvertTo-LanProbeCommandLineArgument {
    param([AllowEmptyString()][string]$Argument)

    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') {
        return $Argument
    }

    # ProcessStartInfo.ArgumentList 在 Windows PowerShell 5.1 的 .NET
    # Framework 中不可用；按 CreateProcess 规则安全构造单个参数。
    $builder = New-Object Text.StringBuilder
    $null = $builder.Append('"')
    $backslashCount = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashCount++
            continue
        }
        if ($character -eq [char]34) {
            $null = $builder.Append(('\' * ($backslashCount * 2 + 1)))
            $null = $builder.Append('"')
            $backslashCount = 0
            continue
        }
        if ($backslashCount -gt 0) {
            $null = $builder.Append(('\' * $backslashCount))
            $backslashCount = 0
        }
        $null = $builder.Append($character)
    }
    if ($backslashCount -gt 0) {
        $null = $builder.Append(('\' * ($backslashCount * 2)))
    }
    $null = $builder.Append('"')
    return $builder.ToString()
}


function Start-LanProbeManagedProcess {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$EnableLiveLineCapture
    )

    $quotedArguments = @(
        $Arguments | ForEach-Object {
            ConvertTo-LanProbeCommandLineArgument ([string]$_)
        }
    )
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Executable
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Arguments = $quotedArguments -join ' '

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw "Failed to start probe executable: $Executable"
    }
    $stdoutBuffer = $null
    $stderrBuffer = $null
    if ($EnableLiveLineCapture) {
        # Relay 的 ready/host-id 是后续 peer 的必要输入；逐行异步读取既能
        # 实时取到精确行，也避免 stdout/stderr 管道写满阻塞 Godot。
        $stdoutBuffer = New-Object Text.StringBuilder
        $stderrBuffer = New-Object Text.StringBuilder
        $stdoutTask = $process.StandardOutput.ReadLineAsync()
        $stderrTask = $process.StandardError.ReadLineAsync()
    }
    else {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
    }
    Register-LanProbeLauncherOwnership $Context $process
    return [pscustomobject]@{
        Process = $process
        StdoutTask = $stdoutTask
        StderrTask = $stderrTask
        LiveLineCapture = [bool]$EnableLiveLineCapture
        StdoutBuffer = $stdoutBuffer
        StderrBuffer = $stderrBuffer
        StdoutClosed = $false
        StderrClosed = $false
    }
}


function Update-LanProbeLiveLineCapture {
    param([Parameter(Mandatory = $true)]$Entry)

    $hasLiveCaptureProperty = (
        $Entry.PSObject.Properties.Name -contains "LiveLineCapture"
    )
    if (-not $hasLiveCaptureProperty -or -not $Entry.LiveLineCapture) {
        return
    }

    foreach ($channelName in @("Stdout", "Stderr")) {
        $closedPropertyName = "${channelName}Closed"
        $taskPropertyName = "${channelName}Task"
        $bufferPropertyName = "${channelName}Buffer"
        while (-not [bool]$Entry.$closedPropertyName) {
            $lineTask = $Entry.$taskPropertyName
            if (-not $lineTask.IsCompleted) {
                break
            }
            if ($lineTask.IsFaulted) {
                throw (
                    "$($Entry.Name) $channelName live capture failed: " +
                    $lineTask.Exception.GetBaseException().Message
                )
            }
            if ($lineTask.IsCanceled) {
                throw "$($Entry.Name) $channelName live capture was canceled."
            }
            if ($null -eq $lineTask.Result) {
                $Entry.$closedPropertyName = $true
                break
            }
            $null = $Entry.$bufferPropertyName.AppendLine(
                [string]$lineTask.Result
            )
            $Entry.$taskPropertyName = if ($channelName -eq "Stdout") {
                $Entry.Process.StandardOutput.ReadLineAsync()
            }
            else {
                $Entry.Process.StandardError.ReadLineAsync()
            }
        }
    }
}


function Complete-LanProbePeerLogs {
    param([Parameter(Mandatory = $true)]$Entry)

    if ($Entry.LogsCompleted) {
        return
    }
    if (-not $Entry.Process.HasExited) {
        throw "$($Entry.Name) logs cannot complete before its launcher exits."
    }
    $Entry.Process.WaitForExit()
    $hasLiveCapture = (
        $Entry.PSObject.Properties.Name -contains "LiveLineCapture" -and
        $Entry.LiveLineCapture
    )
    if ($hasLiveCapture) {
        $captureDeadline = [DateTime]::UtcNow.AddSeconds(5)
        do {
            Update-LanProbeLiveLineCapture $Entry
            if ($Entry.StdoutClosed -and $Entry.StderrClosed) {
                break
            }
            Start-Sleep -Milliseconds 10
        } while ([DateTime]::UtcNow -lt $captureDeadline)
        if (-not $Entry.StdoutClosed) {
            throw "$($Entry.Name) stdout did not close within 5 seconds."
        }
        if (-not $Entry.StderrClosed) {
            throw "$($Entry.Name) stderr did not close within 5 seconds."
        }
        $stdout = $Entry.StdoutBuffer.ToString()
        $stderr = $Entry.StderrBuffer.ToString()
    }
    else {
        if (-not $Entry.StdoutTask.Wait(5000)) {
            throw "$($Entry.Name) stdout did not close within 5 seconds."
        }
        if (-not $Entry.StderrTask.Wait(5000)) {
            throw "$($Entry.Name) stderr did not close within 5 seconds."
        }
        $stdout = [string]$Entry.StdoutTask.Result
        $stderr = [string]$Entry.StderrTask.Result
    }
    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Entry.Stdout, $stdout, $utf8NoBom)
    [IO.File]::WriteAllText($Entry.Stderr, $stderr, $utf8NoBom)
    $Entry.LogsCompleted = $true
}


function Update-LanProbeOwnedProcessRegistry {
    param([Parameter(Mandatory = $true)]$Context)

    $snapshot = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    $processById = @{}
    foreach ($process in $snapshot) {
        $processById[[int]$process.ProcessId] = $process
    }

    # 只有本轮不可预测的运行 ID 才能建立初始所有权。可执行文件名不参与
    # 判断，以兼容官方版、下载版以及 console -> engine 的进程交接。
    foreach ($process in $snapshot) {
        $hasRunMarker = $false
        if ($null -ne $process.CommandLine) {
            $hasRunMarker = ([string]$process.CommandLine).Contains(
                $Context.RunMarkerPrefix
            )
        }
        if ($hasRunMarker) {
            $requiresExitCode = (
                [string]$process.Name -match '(?i)^Godot.*\.exe$'
            )
            Register-LanProbeOwnedCimProcess `
                $Context `
                $process `
                $requiresExitCode
        }
    }

    # 子进程不一定继承 Godot 参数，因此沿已核实的父进程追踪。父 PID 必须
    # 仍对应原创建时间，避免 PID 复用把无关进程纳入清理范围。
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($process in $snapshot) {
            $processId = [int]$process.ProcessId
            $parentProcessId = [int]$process.ParentProcessId
            $processAlreadyOwned = (
                $Context.OwnedIdentityByProcessId.ContainsKey($processId)
            )
            $parentIsOwned = (
                $Context.OwnedIdentityByProcessId.ContainsKey($parentProcessId)
            )
            $parentIsLive = $processById.ContainsKey($parentProcessId)
            if ($processAlreadyOwned -or -not $parentIsOwned -or -not $parentIsLive) {
                continue
            }

            $liveParent = $processById[$parentProcessId]
            $liveParentIdentity = Get-LanProbeCimIdentity $liveParent
            $parentIdentityMatches = (
                $Context.OwnedIdentityByProcessId[$parentProcessId] -eq $liveParentIdentity
            )
            if (-not $parentIdentityMatches) {
                continue
            }
            $creationUtc = ([DateTime]$process.CreationDate).ToUniversalTime()
            if ($creationUtc -lt $Context.OwnedCreationUtcByProcessId[$parentProcessId]) {
                continue
            }
            Register-LanProbeOwnedCimProcess $Context $process $false
            $changed = $true
        }
    }
    return $snapshot
}


function Get-LiveLanProbeOwnedProcesses {
    param([Parameter(Mandatory = $true)]$Context)

    $snapshot = @(Update-LanProbeOwnedProcessRegistry $Context)
    $result = @()
    foreach ($process in $snapshot) {
        $processId = [int]$process.ProcessId
        $processIdIsOwned = (
            $Context.OwnedIdentityByProcessId.ContainsKey($processId)
        )
        $identityMatches = $false
        if ($processIdIsOwned) {
            $liveIdentity = Get-LanProbeCimIdentity $process
            $identityMatches = (
                $Context.OwnedIdentityByProcessId[$processId] -eq $liveIdentity
            )
        }
        if ($identityMatches) {
            $result += $process
        }
    }
    return $result
}


function Register-LanProbeLauncherOwnership {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process
    )

    Register-LanProbeProcessHandle $Context $Process
    $registered = $false
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        $candidate = Get-CimInstance `
            Win32_Process `
            -Filter "ProcessId = $([int]$Process.Id)" `
            -ErrorAction SilentlyContinue
        $candidateHasRunMarker = $false
        if ($null -ne $candidate -and $null -ne $candidate.CommandLine) {
            $candidateHasRunMarker = ([string]$candidate.CommandLine).Contains(
                $Context.RunMarkerPrefix
            )
        }
        if ($candidateHasRunMarker) {
            Register-LanProbeOwnedCimProcess $Context $candidate $true
            $registered = $true
            break
        }
        if ($Process.HasExited) {
            break
        }
        Start-Sleep -Milliseconds 25
    }
    if (-not $registered) {
        throw (
            "Could not establish CIM ownership for launched process " +
            "$([int]$Process.Id)."
        )
    }
}


function Watch-LanProbeProcessOwnership {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][int]$Milliseconds
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($Milliseconds)
    do {
        $null = Update-LanProbeOwnedProcessRegistry $Context
        Start-Sleep -Milliseconds 25
    } while ([DateTime]::UtcNow -lt $deadline)
}


function Wait-LanProbePeerProcesses {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][array]$Entries,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        foreach ($entry in $Entries) {
            Update-LanProbeLiveLineCapture $entry
            if (-not $entry.Process.HasExited) {
                $entry.Process.WaitForExit(50) | Out-Null
            }
        }
        $runningLaunchers = @(
            $Entries | Where-Object { -not $_.Process.HasExited }
        )
        $liveOwned = @(Get-LiveLanProbeOwnedProcesses $Context)
        if ($runningLaunchers.Count -eq 0 -and $liveOwned.Count -eq 0) {
            foreach ($entry in $Entries) {
                # 无参 WaitForExit 会等待重定向日志完全刷新。
                $entry.Process.WaitForExit()
            }
            return
        }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)

    $runningNames = @()
    foreach ($entry in $Entries) {
        if (-not $entry.Process.HasExited) {
            $runningNames += $entry.Name
        }
    }
    $ownedDescriptions = @(
        $liveOwned | ForEach-Object {
            "$($_.Name) PID=$($_.ProcessId)"
        }
    )
    throw (
        "LAN probe exceeded its $TimeoutSeconds-second timeout; " +
        "running peers=$($runningNames -join ','); " +
        "live owned processes=$($ownedDescriptions -join ',')."
    )
}


function Read-LanProbeLogText {
    param(
        [Parameter(Mandatory = $true)][string]$PeerName,
        [Parameter(Mandatory = $true)][string]$ChannelName,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$PeerName did not create its $ChannelName log: $Path"
    }
    return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
}


function Assert-LanProbePeerTruth {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)][string]$ExpectedMarker,
        [string]$AllowedExactStderrAndEngineErrorPattern = ""
    )

    if (-not $Entry.Process.HasExited) {
        throw "$($Entry.Name) truth check ran before its launcher exited."
    }
    $Entry.Process.WaitForExit()

    $stdout = Read-LanProbeLogText $Entry.Name "stdout" $Entry.Stdout
    $stderr = Read-LanProbeLogText $Entry.Name "stderr" $Entry.Stderr
    $engineLog = Read-LanProbeLogText $Entry.Name "engine" $Entry.EngineLog
    $failures = [Collections.Generic.List[string]]::new()

    $launcherExitCode = $Entry.Process.ExitCode
    if ($null -eq $launcherExitCode) {
        $failures.Add("$($Entry.Name) launcher did not expose an exit code.")
    }
    elseif ([int]$launcherExitCode -ne 0) {
        $failures.Add(
            "$($Entry.Name) exited with code $([int]$launcherExitCode)."
        )
    }

    $markerPattern = "(?m)^$([regex]::Escape($ExpectedMarker))`r?$"
    $stdoutMarkerCount = [regex]::Matches($stdout, $markerPattern).Count
    $stderrMarkerCount = [regex]::Matches($stderr, $markerPattern).Count
    if ($stdoutMarkerCount -ne 1 -or $stderrMarkerCount -ne 0) {
        $failures.Add(
            "$($Entry.Name) must emit exactly one exact $ExpectedMarker " +
            "line on stdout and none on stderr; stdout=$stdoutMarkerCount, " +
            "stderr=$stderrMarkerCount."
        )
    }

    $auditedStderr = $stderr
    $auditedEngineLog = $engineLog
    if (-not [string]::IsNullOrEmpty($AllowedExactStderrAndEngineErrorPattern)) {
        foreach ($channelName in @("stderr", "engine")) {
            $channelText = if ($channelName -eq "stderr") {
                $auditedStderr
            }
            else {
                $auditedEngineLog
            }
            $allowedMatchCount = [regex]::Matches(
                $channelText,
                $AllowedExactStderrAndEngineErrorPattern
            ).Count
            if ($allowedMatchCount -gt 1) {
                $failures.Add(
                    "$($Entry.Name) emitted the exact allowed error block " +
                    "$allowedMatchCount times on $channelName; at most one is allowed."
                )
                continue
            }
            if ($allowedMatchCount -eq 1) {
                $channelText = [regex]::Replace(
                    $channelText,
                    $AllowedExactStderrAndEngineErrorPattern,
                    ""
                )
            }
            if ($channelName -eq "stderr") {
                $auditedStderr = $channelText
            }
            else {
                $auditedEngineLog = $channelText
            }
        }
    }

    # --log-file 会镜像 print 输出，因此 marker 的唯一性以 stdout 为准；
    # 三个通道仍全部参加错误审计。Relay 仅可显式传入已证明的
    # 关闭期完整错误块，stdout 从不过滤，同通道重复也仍失败。
    $combinedOutput = (
        "--- stdout ---`n$stdout`n" +
        "--- stderr ---`n$auditedStderr`n" +
        "--- engine log ---`n$auditedEngineLog"
    )
    $forbidden = [regex]::Match(
        $combinedOutput,
        (
            "SCRIPT ERROR|Parse Error|Failed to load script|(?m)^ERROR|" +
            "Node not found|Invalid packet received|ERR_UNCONFIGURED|" +
            "Unable to send packet|Trying to cast|ObjectDB instances leaked|" +
            "resources still in use"
        )
    )
    if ($forbidden.Success) {
        $failures.Add(
            "$($Entry.Name) emitted forbidden engine output: $($forbidden.Value)"
        )
    }

    if ($failures.Count -ne 0) {
        throw ($failures -join " ")
    }
    return [pscustomobject]@{
        Stdout = $stdout
        Stderr = $stderr
        EngineLog = $engineLog
    }
}


function Get-LanProbeRelayShutdownNoisePattern {
    # 只允许 Relay 关闭期已复现的 ENet 两行完整块。不用宽泛
    # `Unable to send packet` 子串，避免吞掉其他信道、节点或协议错误。
    return (
        '(?m)^ERROR: Unable to send packet on channel 0, max channels: 0\r?\n' +
        '[ ]{3}at: send \(modules/enet/enet_packet_peer\.cpp:62\)\r?(?:\n|$)'
    )
}


function Assert-LanProbeManagedEntryExitCodes {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][array]$Entries
    )

    $failures = [Collections.Generic.List[string]]::new()
    foreach ($entry in $Entries) {
        $processId = [int]$entry.Process.Id
        if (-not $Context.OwnedIdentityByProcessId.ContainsKey($processId)) {
            $failures.Add(
                "$($entry.Name) launcher PID=$processId was not registered as owned."
            )
            continue
        }
        try {
            if (-not $entry.Process.HasExited) {
                $failures.Add(
                    "$($entry.Name) launcher PID=$processId is still running."
                )
                continue
            }
            $entry.Process.WaitForExit()
            $exitCode = $entry.Process.ExitCode
            if ($null -eq $exitCode) {
                $failures.Add(
                    "$($entry.Name) launcher PID=$processId has no exit code."
                )
            }
            elseif ([int]$exitCode -ne 0) {
                $failures.Add(
                    "$($entry.Name) launcher PID=$processId exited with code " +
                    "$([int]$exitCode)."
                )
            }
        }
        catch {
            $failures.Add(
                "$($entry.Name) launcher PID=$processId exit-code audit failed: " +
                $_.Exception.Message
            )
        }
    }
    if ($failures.Count -ne 0) {
        throw ($failures -join " ")
    }
}


function Write-LanProbePeerLogs {
    param([Parameter(Mandatory = $true)]$Entry)

    foreach ($channel in @(
        [pscustomobject]@{ Name = "stdout"; Path = $Entry.Stdout },
        [pscustomobject]@{ Name = "stderr"; Path = $Entry.Stderr },
        [pscustomobject]@{ Name = "engine"; Path = $Entry.EngineLog }
    )) {
        [Console]::Error.WriteLine(
            "==== $($Entry.Name) $($channel.Name) ===="
        )
        if (Test-Path -LiteralPath $channel.Path -PathType Leaf) {
            [Console]::Error.WriteLine(
                [IO.File]::ReadAllText($channel.Path, [Text.Encoding]::UTF8)
            )
        }
        else {
            [Console]::Error.WriteLine("<missing: $($channel.Path)>")
        }
    }
}


function Stop-LanProbeOwnedProcessTree {
    param([Parameter(Mandatory = $true)]$Context)

    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $live = @(Get-LiveLanProbeOwnedProcesses $Context)
        if ($live.Count -eq 0) {
            break
        }

        $parentByProcessId = @{}
        foreach ($process in $live) {
            $parentByProcessId[[int]$process.ProcessId] = (
                [int]$process.ParentProcessId
            )
        }
        $depthByProcessId = @{}
        foreach ($process in $live) {
            $processId = [int]$process.ProcessId
            $depth = 0
            $cursor = $processId
            $visited = @{}
            while ($parentByProcessId.ContainsKey($cursor)) {
                if ($parentByProcessId[$cursor] -eq 0 -or $visited.ContainsKey($cursor)) {
                    break
                }
                $visited[$cursor] = $true
                $cursor = $parentByProcessId[$cursor]
                $depth++
            }
            $depthByProcessId[$processId] = $depth
        }

        # 只停止 PID 与 CIM 创建时间均仍匹配的本轮进程，并先停后代。
        foreach ($process in @($live | Sort-Object {
            -1 * $depthByProcessId[[int]$_.ProcessId]
        })) {
            $processId = [int]$process.ProcessId
            $current = Get-CimInstance `
                Win32_Process `
                -Filter "ProcessId = $processId" `
                -ErrorAction SilentlyContinue
            $identityMatches = $false
            if ($null -ne $current) {
                $currentIdentity = Get-LanProbeCimIdentity $current
                $identityMatches = (
                    $Context.OwnedIdentityByProcessId[$processId] -eq $currentIdentity
                )
            }
            if ($identityMatches) {
                Stop-Process `
                    -Id $processId `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)

    foreach ($handle in @($Context.ProcessHandleByProcessId.Values)) {
        try {
            if (-not $handle.HasExited) {
                # Diagnostics.Process 句柄只指向已由本 runner 捕获的进程；
                # 即便 CIM 临时不可用，也不能把 launcher/交接进程留在后台。
                $handle.Kill()
            }
            $handle.WaitForExit()
        }
        catch {
            # 最终所有权复核由下方 CIM 快照负责。
        }
    }

    $remaining = @(Get-LiveLanProbeOwnedProcesses $Context)
    if ($remaining.Count -ne 0) {
        $descriptions = @(
            $remaining | ForEach-Object {
                "$($_.Name) PID=$($_.ProcessId)"
            }
        )
        throw "Owned process cleanup failed: $($descriptions -join ', ')"
    }
}


function Close-LanProbeProcessHandles {
    param([Parameter(Mandatory = $true)]$Context)

    foreach ($handle in @($Context.ProcessHandleByProcessId.Values)) {
        try {
            $handle.Dispose()
        }
        catch {
        }
    }
}
