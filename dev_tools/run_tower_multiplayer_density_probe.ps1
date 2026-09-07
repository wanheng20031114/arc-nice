param(
    [int]$Players = 6,
    [int]$Buildings = 400,
    [int]$Enemies = 300,
    [string]$EnemyWave = '',
    [int]$Frames = 300,
    [int]$Port = 28798,
    [ValidateSet('lan', 'relay')][string]$Transport = 'lan',
    [switch]$ActiveInput,
    [switch]$ReconnectLastClient,
    [switch]$PrepareRouteIdentity,
    [switch]$DetailedMetrics,
    [switch]$NativeCpu,
    [switch]$ProfileHost,
    [string]$Godot = 'C:/Program Files/Godot/Godot_console.exe'
)
$ErrorActionPreference = 'Stop'
if ($PrepareRouteIdentity -and -not $ReconnectLastClient) { throw '-PrepareRouteIdentity requires -ReconnectLastClient' }
$probeRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$runDirectory = Join-Path $probeRoot ('dev_tools/output/tower_network_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
$dirtyHashes = @{}
foreach ($relativePath in @(& git -C $probeRoot ls-files -m -o --exclude-standard)) {
    if ($relativePath -match '\.(gd|tres|tscn|ps1|py)$') {
        $fullPath = Join-Path $probeRoot $relativePath
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) { $dirtyHashes[$relativePath] = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash }
    }
}
$loaderText = Get-Content -LiteralPath (Join-Path $probeRoot 'scene/loading/game_load_coordinator.gd') -Raw -Encoding UTF8
$loaderSubThreads = [regex]::Match($loaderText, 'THREADED_RESOURCE_LIFETIME\.request\(\s*path,\s*"",\s*(true|false),').Groups[1].Value
$loaderLifetimeText = Get-Content -LiteralPath (Join-Path $probeRoot 'scene/loading/threaded_resource_lifetime.gd') -Raw -Encoding UTF8
$loaderEffectiveSubThreads = $loaderSubThreads
if ($loaderLifetimeText.Contains('use_sub_threads and not headless')) { $loaderEffectiveSubThreads = 'false' }
@{
    git_revision = (& git -C $probeRoot rev-parse HEAD)
    working_changes = @(& git -C $probeRoot status --short)
    players = $Players; buildings = $Buildings; enemies = $Enemies; frames = $Frames
    enemy_wave = $EnemyWave
    transport = $Transport; active_input = [bool]$ActiveInput; reconnect_last_client = [bool]$ReconnectLastClient; prepare_route_identity = [bool]$PrepareRouteIdentity; native_profile_host = [bool]$ProfileHost
    detailed_metrics = [bool]$DetailedMetrics
    native_cpu = [bool]$NativeCpu
    loader_requested_sub_threads = $loaderSubThreads; loader_effective_headless_sub_threads = $loaderEffectiveSubThreads; working_source_sha256 = $dirtyHashes
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $runDirectory 'run_metadata.json') -Encoding UTF8
$processes = @()
$relayProcess = $null
$nativeCpuProcesses = @()
$nativeCpuClock = $null
$nativeCpuCaptured = $false
function Start-Probe([int]$Index, [string]$Role) {
    $arguments = @('--headless', '--path', ('"' + $probeRoot + '"'), '--script', 'res://dev_tools/tower_multiplayer_density_probe.gd')
    if ($ProfileHost -and $Role -eq 'host') { $arguments += @('-d', '--profiling') }
    $arguments += @('--',
        "--role=$Role", "--index=$Index", "--port=$Port", "--players=$Players", "--buildings=$Buildings",
        "--enemies=$Enemies", "--frames=$Frames", "--transport=$Transport", ('--output-dir="' + $runDirectory + '"'))
    if ($ActiveInput) { $arguments += '--active-input' }
    if ($ReconnectLastClient) { $arguments += '--reconnect-last-client' }
    if ($PrepareRouteIdentity) { $arguments += '--prepare-route-identity' }
    if ($DetailedMetrics) { $arguments += '--detailed-metrics' }
    if ($EnemyWave) { $arguments += ('--enemy-wave="' + $EnemyWave + '"') }
    $started = Start-Process -FilePath $Godot -ArgumentList $arguments -WorkingDirectory $probeRoot -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $runDirectory "peer_$Index.log") `
        -RedirectStandardError (Join-Path $runDirectory "peer_$Index.err.log")
    # Retain the Windows process handle before the console wrapper exits. With
    # Start-Process, opening it only after exit can leave ExitCode unavailable.
    $null = $started.Handle
    return $started
}
try {
    if ($Transport -eq 'relay') {
        & python (Join-Path $PSScriptRoot 'prepare_local_relay_probe.py') --output-dir $runDirectory --players $Players
        if ($LASTEXITCODE -ne 0) { throw 'Local relay ticket preparation failed' }
        $context = Get-Content -LiteralPath (Join-Path $runDirectory 'relay_context.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $previousRoom = $env:ARC_NICE_RELAY_ROOM_ID
        $previousSecret = $env:ARC_NICE_RELAY_ADMISSION_SECRET
        try {
            $env:ARC_NICE_RELAY_ROOM_ID = $context.room_id
            $env:ARC_NICE_RELAY_ADMISSION_SECRET = $context.secret
            $relayArguments = @('--headless', '--path', ('"' + (Join-Path $probeRoot 'relay_servers/relay_godot_project') + '"'), '--',
                "--port=$Port", "--max-clients=$Players", '--max-lifetime=240', '--empty-idle-timeout=3', ('--probe-owner="' + $runDirectory + '"'))
            $relayProcess = Start-Process -FilePath $Godot -ArgumentList $relayArguments -WorkingDirectory $probeRoot -WindowStyle Hidden -PassThru `
                -RedirectStandardOutput (Join-Path $runDirectory 'relay.log') -RedirectStandardError (Join-Path $runDirectory 'relay.err.log')
            $null = $relayProcess.Handle
        }
        finally {
            $env:ARC_NICE_RELAY_ROOM_ID = $previousRoom
            $env:ARC_NICE_RELAY_ADMISSION_SECRET = $previousSecret
        }
        Start-Sleep -Milliseconds 600
        if ($relayProcess.HasExited) { throw 'Local relay failed to start' }
    }
    $processes += Start-Probe 0 'host'
    $startupDeadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $startupDeadline) {
        if ($processes[0].HasExited) { throw 'Host exited during startup' }
        if (Test-Path -LiteralPath (Join-Path $runDirectory 'host_ready.json')) { break }
        Start-Sleep -Milliseconds 200
    }
    if (-not (Test-Path -LiteralPath (Join-Path $runDirectory 'host_ready.json'))) { throw 'Host did not become ready' }
    for ($index = 1; $index -lt $Players; $index++) { $processes += Start-Probe $index 'client' }
    $processes.Id | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runDirectory 'pids.json') -Encoding UTF8
    Write-Output "PROBE_STARTED directory=$runDirectory pids=$($processes.Id -join ',')"
    $deadline = (Get-Date).AddSeconds(200)
    $teardownDeadline = $null
    while ((Get-Date) -lt $deadline) {
        if ($NativeCpu -and $null -eq $nativeCpuClock -and (Test-Path -LiteralPath (Join-Path $runDirectory 'host_sampling.json'))) {
            $nativeCpuProcesses = @(Get-CimInstance Win32_Process | Where-Object {
                $_.Name -match '^Godot.*\.exe$' -and $_.Name -notmatch '_console\.exe$' -and
                $_.CommandLine -and $_.CommandLine.Contains($runDirectory)
            } | ForEach-Object {
                $nativeProcess = Get-Process -Id $_.ProcessId
                $null = $nativeProcess.Handle
                $label = 'relay'
                if ($_.CommandLine -match '--index=(\d+)') { $label = 'peer_' + $Matches[1] }
                @{ process = $nativeProcess; label = $label; initial_ms = $nativeProcess.TotalProcessorTime.TotalMilliseconds }
            })
            $nativeCpuClock = [System.Diagnostics.Stopwatch]::StartNew()
        }
        if ($NativeCpu -and $null -ne $nativeCpuClock -and -not $nativeCpuCaptured -and (Test-Path -LiteralPath (Join-Path $runDirectory 'peer_0.json'))) {
            $wallMs = $nativeCpuClock.Elapsed.TotalMilliseconds
            $samples = @($nativeCpuProcesses | ForEach-Object {
                $_.process.Refresh()
                $cpuMs = $_.process.TotalProcessorTime.TotalMilliseconds - $_.initial_ms
                @{ label = $_.label; process_id = $_.process.Id; cpu_ms = $cpuMs; one_core_percent = $cpuMs * 100.0 / $wallMs }
            })
            @{ wall_ms = $wallMs; polling_interval_ms = 500; processes = $samples } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $runDirectory 'native_cpu.json') -Encoding UTF8
            $nativeCpuCaptured = $true
        }
        $alive = @($processes | Where-Object { -not $_.HasExited })
        if ($alive.Count -eq 0) { break }
        $failures = @(Get-ChildItem -LiteralPath $runDirectory -Filter 'failure_*.json')
        if ($failures.Count -gt 0) { throw ('Probe reported failure: ' + $failures[0].FullName) }
        if (Test-Path -LiteralPath (Join-Path $runDirectory 'stop.json')) {
            if ($null -eq $teardownDeadline) { $teardownDeadline = (Get-Date).AddSeconds(15) }
            if ((Get-Date) -gt $teardownDeadline) { throw 'Measurements completed but engine teardown exceeded 15 seconds' }
        }
        Start-Sleep -Milliseconds 500
    }
    if (@($processes | Where-Object { -not $_.HasExited }).Count -gt 0) { throw 'Probe exceeded runner deadline' }
    $logErrors = @(Get-ChildItem -LiteralPath $runDirectory -Filter '*.log' | Select-String -Pattern 'SCRIPT ERROR:|ERROR:|DENSITY_FAILURE')
    if ($logErrors.Count -gt 0) { $logErrors | ForEach-Object { Write-Output $_ }; throw 'Godot log errors' }
    foreach ($log in Get-ChildItem -LiteralPath $runDirectory -Filter '*.log') {
        $lines = @(Get-Content -LiteralPath $log.FullName -Encoding UTF8)
        for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
            if ($lines[$lineIndex] -notmatch '^WARNING:') { continue }
            # Native -d profiling also prints existing compiler lint. Only that
            # exact compiler site is allowed, never runtime/resource warnings.
            if ($ProfileHost -and $log.Name -eq 'peer_0.err.log' -and $lineIndex + 1 -lt $lines.Count -and $lines[$lineIndex + 1] -match '^\s+at: GDScript::reload ') { continue }
            throw "Runtime warning in $($log.Name): $($lines[$lineIndex])"
        }
    }
    foreach ($process in $processes) {
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "Godot process $($process.Id) exited with $($process.ExitCode)" }
    }
    if ($null -ne $relayProcess) {
        # The real Relay owns its empty-room lifetime. Verify that path instead
        # of letting finally terminate it while the 3-second idle timer runs.
        if (-not $relayProcess.WaitForExit(6000)) { throw 'Relay did not exit after its empty-room idle timeout' }
        if ($relayProcess.ExitCode -ne 0) { throw "Relay process $($relayProcess.Id) exited with $($relayProcess.ExitCode)" }
        Write-Output 'RELAY_EMPTY_IDLE_EXIT_PASS exit=0'
    }
    $results = @(Get-ChildItem -LiteralPath $runDirectory -Filter 'peer_*.json' | ForEach-Object {
        Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    })
    if ($results.Count -ne $Players) { throw 'Missing participant results' }
    $checkpoint = Get-Content -LiteralPath (Join-Path $runDirectory 'warehouse_checkpoint.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    for ($index = 0; $index -lt $Players; $index++) {
        $actual = Get-Content -LiteralPath (Join-Path $runDirectory "checkpoint_peer_$index.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($actual.water_count -ne $checkpoint.water_count -or @($actual.revisions.PSObject.Properties).Count -ne @($checkpoint.revisions.PSObject.Properties).Count) { throw "Warehouse checkpoint mismatch for participant $index" }
        foreach ($entry in $checkpoint.revisions.PSObject.Properties) {
            if ($actual.revisions.($entry.Name) -ne $entry.Value) { throw "Warehouse revision mismatch for participant $index" }
        }
    }
    Write-Output "WAREHOUSE_CHECKPOINT_PASS participants=$Players water=$($checkpoint.water_count)"
    if ($ReconnectLastClient) {
        $rejectedIdentity = Get-Content -LiteralPath (Join-Path $runDirectory 'reconnect_unknown_identity_rejected.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $rejectedIdentity.rejected) { throw 'Unknown reconnect identity was not rejected' }
        $reconnectHost = Get-Content -LiteralPath (Join-Path $runDirectory 'reconnect_host.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $reconnectClient = Get-Content -LiteralPath (Join-Path $runDirectory 'reconnect_client.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $reconnectRoster = Get-Content -LiteralPath (Join-Path $runDirectory 'reconnect_roster_pass.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($reconnectHost.new_peer_id -eq $reconnectHost.old_peer_id -or $reconnectClient.stable_key -ne $reconnectHost.stable_key -or $reconnectClient.incarnation -ne $reconnectHost.incarnation -or $reconnectRoster.plants -ne $Buildings -or $reconnectHost.host_accepted_input -le 0 -or $reconnectClient.local_projectiles -le 0) { throw 'Reconnect identity, roster or resumed input mismatch' }
        Write-Output "RECONNECT_PASS old=$($reconnectHost.old_peer_id) new=$($reconnectHost.new_peer_id) elapsed_ms=$($reconnectClient.elapsed_ms) enemies=$($reconnectRoster.enemies) plants=$($reconnectRoster.plants)"
        if ($PrepareRouteIdentity) {
            for ($index = 0; $index -lt $Players; $index++) {
                $routeIdentity = Get-Content -LiteralPath (Join-Path $runDirectory "route_identity_peer_$index.json") -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($routeIdentity.players -ne $Players -or -not $routeIdentity.old_removed -or $routeIdentity.new_peer_id -ne $reconnectHost.new_peer_id) { throw 'Retained embedded route identity mismatch' }
            }
            Write-Output "RETAINED_ROUTE_IDENTITY_PASS participants=$Players"
        }
    }
    foreach ($result in $results) {
        if ($result.participants -ne $Players -or $result.plants -ne $Buildings -or ((-not $EnemyWave) -and $result.enemies -ne $Enemies)) {
            throw "Density/cohort mismatch in participant $($result.index)"
        }
        if ($EnemyWave -and $result.minimum_sample_enemies -le 0) { throw "Mixed enemy cohort disappeared for participant $($result.index)" }
        if ($ActiveInput -and $result.role -eq 'client' -and $result.input_sequences.sent -le 0) {
            throw "Client $($result.index) did not send active input"
        }
        if ($ActiveInput -and $result.role -eq 'host') {
            foreach ($sequence in $result.input_sequences.host_accepted.PSObject.Properties.Value) {
                if ($sequence -le 0) { throw 'Host did not accept an active participant input stream' }
            }
            if ($DetailedMetrics -and $result.network_cpu.'rpc:net_projectile_fired'.calls -le 0) { throw 'No authoritative player projectiles were broadcast' }
        }
        if ($ActiveInput -and $result.local_projectiles_allocated -le 0) { throw "Participant $($result.index) did not fire local projectiles" }
        Write-Output ("PEER index={0} role={1} players={2} plants={3} enemies={4} frame_p95_ms={5}" -f
            $result.index, $result.role, $result.participants, $result.plants, $result.enemies, $result.frame_ms.p95)
    }
    Write-Output "PROBE_PASS directory=$runDirectory"
}
finally {
    $ownedIds = @($processes | ForEach-Object { $_.Id })
    if ($null -ne $relayProcess) { $ownedIds += $relayProcess.Id }
    # The Windows console launcher starts a separate Godot.exe child. Match the
    # exact per-run output directory as well as the fixture and headless flags,
    # so failed shutdowns cannot leave children or touch the user's editor.
    $ownedProcesses = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match '^Godot.*\.exe$' -and $_.CommandLine -match '--headless' -and
        $_.CommandLine -match 'tower_multiplayer_density_probe.gd|--probe-owner=' -and
        $_.CommandLine.Contains($runDirectory)
    })
    foreach ($process in ($ownedProcesses | Sort-Object Name)) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
    $remaining = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match '^Godot.*\.exe$' -and $_.CommandLine -match '--headless' -and
        $_.CommandLine -match 'tower_multiplayer_density_probe.gd|--probe-owner=' -and
        $_.CommandLine.Contains($runDirectory)
    })
    Write-Output "PROBE_PROCESS_CLEANUP remaining=$($remaining.Count) owned=$($ownedIds -join ',')"
    # These are generated local test capabilities, never production credentials.
    $contextPath = Join-Path $runDirectory 'relay_context.json'
    if (Test-Path -LiteralPath $contextPath) { Remove-Item -LiteralPath $contextPath -Force }
    if ($remaining.Count -gt 0) { throw 'Owned Godot validation process remains' }
}
