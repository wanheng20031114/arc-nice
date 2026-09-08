param(
    [ValidateRange(0, 1000)][int]$Buildings = 400,
    [ValidateRange(1, 2000)][int]$Enemies = 300,
    [ValidateRange(1, 6000)][int]$Frames = 1800,
    [ValidateRange(0, 1200)][int]$Warmup = 300,
    [string]$EnemyWave = '',
    [switch]$Render,
    [switch]$DetailedMetrics,
    [switch]$Profile,
    [switch]$ActiveProduction,
    [switch]$DisableProduction,
    [switch]$DisableVisuals,
    [string]$ProjectPath = '',
    [string]$VariantLabel = '',
    [string]$Godot = 'C:/Program Files/Godot/Godot_console.exe'
)
$ErrorActionPreference = 'Stop'
if ($Profile -and -not $PSBoundParameters.ContainsKey('Frames')) { $Frames = 180 }
if ($Profile -and -not $PSBoundParameters.ContainsKey('Warmup')) { $Warmup = 120 }
$probeRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$launchRoot = if ($ProjectPath) { (Resolve-Path -LiteralPath $ProjectPath).Path } else { $probeRoot }
$runDirectory = Join-Path $probeRoot ('dev_tools/output/tower_density_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
# WorkingDirectory below already selects the project for the editor. Official
# release templates reject --path and ignore --script. Their isolated project's
# main scene must select tower_density_release_entry.tscn instead.
$arguments = @('--script', 'res://dev_tools/tower_density_probe.gd')
if (-not $Render) { $arguments += '--headless' }
if ($Profile) { $arguments += @('-d', '--profiling', '--ignore-error-breaks') }
$arguments += @('--', "--buildings=$Buildings", "--enemies=$Enemies", "--frames=$Frames", "--warmup=$Warmup",
    ('--output="' + (Join-Path $runDirectory 'result.json') + '"'))
if ($EnemyWave) { $arguments += ('--enemy-wave="' + $EnemyWave + '"') }
if ($DetailedMetrics) { $arguments += '--detailed-metrics' }
if ($ActiveProduction) { $arguments += '--active-production' }
if ($DisableProduction) { $arguments += '--disable-production' }
if ($DisableVisuals) { $arguments += '--disable-visuals' }
if ($Render) { $arguments += ('--screenshot="' + (Join-Path $runDirectory 'screenshot.png') + '"') }
$patch = (& git -C $probeRoot diff --binary) -join "`n"
[IO.File]::WriteAllText((Join-Path $runDirectory 'working.patch'), $patch, $utf8)
# Preserve new source files too: git diff alone cannot reconstruct an untracked
# fixture or helper used by this exact run.
& git -C $probeRoot ls-files --others --exclude-standard | Where-Object {
    $_ -match '\.(gd|gdshader|gdshaderinc|tscn|tres|ps1)$|(^|/)project.godot$'
} | ForEach-Object {
    $destination = Join-Path (Join-Path $runDirectory 'untracked_source') $_
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $probeRoot $_) -Destination $destination
}
$sourceHashes = @(& git -C $probeRoot ls-files --cached --others --exclude-standard | Where-Object {
    $_ -match '\.(gd|gdshader|gdshaderinc|tscn|tres)$|(^|/)project.godot$'
} | ForEach-Object {
    $path = Join-Path $probeRoot $_
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        @{ path = $_; sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
    }
})
$historicalManifest = Join-Path $launchRoot 'historical_source_manifest.json'
$historicalSource = $null
if (Test-Path -LiteralPath $historicalManifest -PathType Leaf) {
    Copy-Item -LiteralPath $historicalManifest -Destination (Join-Path $runDirectory 'historical_source_manifest.json')
    $historicalSource = @{
        path = $historicalManifest
        sha256 = (Get-FileHash -LiteralPath $historicalManifest -Algorithm SHA256).Hash
    }
}
@{
    git_revision = (& git -C $probeRoot rev-parse HEAD)
    working_changes = @(& git -C $probeRoot status --short)
    godot = $Godot; working_directory = $launchRoot; arguments = $arguments
    variant_label = $VariantLabel
    historical_source_manifest = $historicalSource
    executable_sha256 = (Get-FileHash -LiteralPath $Godot -Algorithm SHA256).Hash
    offline_lobby_fixture_placeholder = ($env:ARC_PUBLIC_LOBBY_API_BASE_URL -eq 'https://127.0.0.1')
    launch_project_godot = (Get-Content -LiteralPath (Join-Path $launchRoot 'project.godot') -Raw -Encoding UTF8)
    cpu = @(Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors)
    gpu = @(Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion)
    utc_started = [DateTime]::UtcNow.ToString('o')
    source_hashes = $sourceHashes
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $runDirectory 'manifest.json') -Encoding UTF8
$process = $null
try {
    $process = Start-Process -FilePath $Godot -ArgumentList $arguments -WorkingDirectory $launchRoot -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $runDirectory 'godot.log') `
        -RedirectStandardError (Join-Path $runDirectory 'godot.err.log')
    $null = $process.Handle
    Write-Output "DENSITY_STARTED directory=$runDirectory pid=$($process.Id)"
    $deadline = (Get-Date).AddSeconds(180)
    while (-not $process.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
    if (-not $process.HasExited) { throw 'Density probe exceeded 180 seconds' }
    $process.WaitForExit()
    $issues = @()
    $parserWarningCount = 0
    foreach ($log in Get-ChildItem -LiteralPath $runDirectory -Filter '*.log') {
        $lines = @(Get-Content -LiteralPath $log.FullName -Encoding UTF8)
        for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
            if ($lines[$lineIndex] -notmatch 'SCRIPT ERROR:|ERROR:|WARNING:') { continue }
            # -d enables existing GDScript lint diagnostics that normal runs do
            # not print. Keep and count only that precise compile-time class;
            # runtime ObjectDB/RID warnings and every ERROR still fail the run.
            if ($Profile -and $lines[$lineIndex] -match '^WARNING:' -and
                $lineIndex + 1 -lt $lines.Count -and
                $lines[$lineIndex + 1] -match '^\s+at: GDScript::reload \(res://') {
                $parserWarningCount++
                continue
            }
            $issues += ('{0}:{1}: {2}' -f $log.Name, ($lineIndex + 1), $lines[$lineIndex])
        }
    }
    if ($Profile) { Write-Output "DENSITY_PROFILER parser_lint_warnings=$parserWarningCount timing_includes_profiler_overhead=True" }
    if ($issues.Count -gt 0) { $issues | ForEach-Object { Write-Output $_ }; throw 'Godot validation emitted errors or warnings' }
    if ($process.ExitCode -ne 0) { throw "Godot exited with $($process.ExitCode)" }
    $result = Get-Content -LiteralPath (Join-Path $runDirectory 'result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($result.buildings_alive -ne $Buildings) { throw 'Building cohort was lost' }
    if (-not $EnemyWave -and $result.enemies_alive -ne $Enemies) { throw 'Baseline enemy cohort was lost' }
    if ($result.simulation.physics_ticks -ne $Frames) { throw 'Measured simulation ticks differ from the requested sample window' }
    Write-Output ("DENSITY_PASS frames={0} enemies_alive={1} wall_p95_ms={2} gpu_p95_ms={3} water={4}" -f
        $result.frames, $result.enemies_alive, $result.frame_ms.p95, $result.render_gpu_ms.p95, $result.water_produced_total)
}
finally {
    if ($null -ne $process -and -not $process.HasExited) {
        $process.Kill()
    }
    # Exact run-directory ownership includes the console launcher's Godot child;
    # never terminate another test, the editor, or an unrelated game window.
    $owned = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match '^Godot.*\.exe$' -and $_.CommandLine -match 'tower_density_probe.gd' -and $_.CommandLine.Contains($runDirectory)
    })
    foreach ($ownedProcess in $owned) {
        $ownedHandle = Get-Process -Id $ownedProcess.ProcessId -ErrorAction SilentlyContinue
        if ($null -ne $ownedHandle) {
            $null = $ownedHandle.Handle
            Stop-Process -Id $ownedProcess.ProcessId -Force -ErrorAction SilentlyContinue
            $ownedHandle.WaitForExit()
            $ownedHandle.Dispose()
        }
    }
    # WaitForExit also drains Start-Process's redirected streams. A process may
    # already have exited before this finally block; its log handles still need
    # draining before we open the files for their evidence hashes.
    if ($null -ne $process) { $process.WaitForExit() }
    $remaining = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match '^Godot.*\.exe$' -and $_.CommandLine -match 'tower_density_probe.gd' -and $_.CommandLine.Contains($runDirectory)
    })
    Write-Output "DENSITY_PROCESS_CLEANUP remaining=$($remaining.Count) directory=$runDirectory"
    if ($remaining.Count -gt 0) { throw 'Owned Godot validation process remains' }
    Get-ChildItem -LiteralPath $runDirectory -File -Recurse | Where-Object { $_.Name -ne 'artifact_hashes.json' } | ForEach-Object {
        @{ path = $_.FullName.Substring($runDirectory.Length + 1); sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runDirectory 'artifact_hashes.json') -Encoding UTF8
}
