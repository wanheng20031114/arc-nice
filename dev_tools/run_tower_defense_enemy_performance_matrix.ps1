param(
    [string[]]$EnemyConfigs = @(),

    [int[]]$EnemyCounts = @(300),

    [string]$BasicControlConfig = (
        "res://resources/config/enemies/yuanshi_insect_basic.tres"
    ),

    [switch]$Execute,

    [switch]$SelfTest,

    [bool]$QuickValidation = $false,

    [ValidateRange(0, 3600)]
    [int]$WarmupFrames = 120,

    [ValidateRange(30, 36000)]
    [int]$SampleFrames = 1200,

    [int]$Seed = 20260717,

    [int]$RandomOrderSeed = 20260824,

    [ValidateRange(0.0, 1000.0)]
    [double]$WallP95BudgetMs = (1000.0 / 60.0),

    [ValidateRange(0.0, 1000.0)]
    [double]$WallP99BudgetMs = (1000.0 / 30.0),

    [ValidateRange(0.0, 1.0)]
    [double]$Over33RatioBudget = 0.005,

    [ValidateRange(0.0, 1.0)]
    [double]$CvRerunThreshold = 0.10,

    [ValidateSet("gl_compatibility", "mobile", "forward_plus")]
    [string]$RenderingMethod = "gl_compatibility",

    [ValidateSet("opengl3", "vulkan", "d3d12")]
    [string]$RenderingDriver = "opengl3",

    [string]$GodotExe = "C:\Program Files\Godot\Godot_console.exe",

    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),

    [ValidateRange(100, 5000)]
    [int]$ExternalSampleIntervalMs = 100,

    [ValidateRange(3, 10000)]
    [int]$MinimumExternalSamples = 20,

    [ValidateRange(1, 3600)]
    [int]$PerRunTimeoutSeconds = 180,

    [ValidateRange(1, 86400)]
    [int]$GlobalTimeoutSeconds = 21600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$matrixSchemaVersion = 1
$backendRunnerName = "run_tower_defense_enemy_cohort_probe.ps1"
$supportedEnemyCounts = @(50, 100, 200, 300)
$roundDefinitions = @(
    [pscustomobject][ordered]@{ round = 1; order = "forward" },
    [pscustomobject][ordered]@{ round = 2; order = "reverse" },
    [pscustomobject][ordered]@{ round = 3; order = "fixed_random" }
)
$script:ActiveChildProcess = $null


function Get-OptionalPropertyValue {
    param(
        [object]$InputObject,
        [string]$Name,
        [object]$DefaultValue = $null
    )

    if ($null -eq $InputObject) {
        return $DefaultValue
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }
    return $property.Value
}


function Get-Sha256Hex {
    param([string]$Text)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return [Convert]::ToHexString($sha.ComputeHash($bytes)).ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}


function Get-ReversedItems {
    param([object[]]$Items)

    $result = [Collections.Generic.List[object]]::new()
    for ($index = $Items.Count - 1; $index -ge 0; $index -= 1) {
        $result.Add($Items[$index])
    }
    return @($result)
}


function Get-FixedRandomItems {
    param(
        [object[]]$Items,
        [int]$OrderSeed
    )

    $decorated = foreach ($item in $Items) {
        $caseKey = [string](Get-OptionalPropertyValue $item "case_key" "")
        [pscustomobject]@{
            sort_key = "$(Get-Sha256Hex "$OrderSeed|$caseKey")|$caseKey"
            item = $item
        }
    }
    return @(
        $decorated |
            Sort-Object -Property sort_key |
            ForEach-Object { $_.item }
    )
}


function Get-MedianValue {
    param([double[]]$Values)

    $ordered = @($Values | Sort-Object)
    if ($ordered.Count -eq 0) {
        return $null
    }
    $middle = [int][Math]::Floor($ordered.Count / 2)
    if ($ordered.Count % 2 -eq 1) {
        return [double]$ordered[$middle]
    }
    return ([double]$ordered[$middle - 1] + [double]$ordered[$middle]) / 2.0
}


function Get-CoefficientOfVariation {
    param([double[]]$Values)

    if ($Values.Count -lt 2) {
        return $null
    }
    $mean = ($Values | Measure-Object -Average).Average
    if ([Math]::Abs($mean) -le [double]::Epsilon) {
        return 0.0
    }
    $squaredError = 0.0
    foreach ($value in $Values) {
        $difference = $value - $mean
        $squaredError += $difference * $difference
    }
    $populationStandardDeviation = [Math]::Sqrt($squaredError / $Values.Count)
    return $populationStandardDeviation / [Math]::Abs($mean)
}


function Get-TwoOfThreeVerdict {
    param([object[]]$RoundVotes)

    $validVotes = @($RoundVotes | Where-Object { [bool]$_.valid })
    $passCount = @($validVotes | Where-Object { [bool]$_.passed }).Count
    $failCount = $validVotes.Count - $passCount
    $verdict = if ($RoundVotes.Count -ne 3 -or $validVotes.Count -ne 3) {
        "invalid"
    } elseif ($passCount -ge 2) {
        "passed"
    } else {
        "failed"
    }
    return [pscustomobject][ordered]@{
        verdict = $verdict
        valid_round_count = $validVotes.Count
        pass_count = $passCount
        fail_count = $failCount
        required_pass_count = 2
        expected_round_count = 3
    }
}


function Get-FingerprintIdentity {
    param([object]$Fingerprint)

    $godot = Get-OptionalPropertyValue $Fingerprint "godot" $null
    $os = Get-OptionalPropertyValue $Fingerprint "os" $null
    $cpu = Get-OptionalPropertyValue $Fingerprint "cpu" $null
    $rendering = Get-OptionalPropertyValue $Fingerprint "rendering" $null
    $window = Get-OptionalPropertyValue $Fingerprint "window" $null
    $vsync = Get-OptionalPropertyValue $Fingerprint "vsync" $null
    $flags = Get-OptionalPropertyValue $Fingerprint "intrusive_flags" $null
    $projection = [ordered]@{
        commit = Get-OptionalPropertyValue $Fingerprint "commit" $null
        dirty = Get-OptionalPropertyValue $Fingerprint "dirty" $null
        source_control_supported = Get-OptionalPropertyValue `
            $Fingerprint `
            "source_control_supported" `
            $false
        godot_version = Get-OptionalPropertyValue $godot "version" ""
        os_name = Get-OptionalPropertyValue $os "name" ""
        os_version = Get-OptionalPropertyValue $os "version" ""
        cpu_name = Get-OptionalPropertyValue $cpu "name" ""
        logical_processor_count = Get-OptionalPropertyValue `
            $cpu `
            "logical_processor_count" `
            0
        gpu = Get-OptionalPropertyValue $Fingerprint "gpu" ""
        requested_method = Get-OptionalPropertyValue $rendering "requested_method" ""
        effective_method = Get-OptionalPropertyValue $rendering "effective_method" ""
        requested_driver = Get-OptionalPropertyValue $rendering "requested_driver" ""
        effective_driver = Get-OptionalPropertyValue $rendering "effective_driver" ""
        requested_size = @(
            Get-OptionalPropertyValue $window "requested_size" @()
        )
        effective_size = @(
            Get-OptionalPropertyValue $window "effective_size" @()
        )
        requested_vsync = Get-OptionalPropertyValue $vsync "requested_mode" ""
        effective_vsync = Get-OptionalPropertyValue $vsync "effective_mode" ""
        seed = Get-OptionalPropertyValue $Fingerprint "seed" $null
        intrusive_flags = [ordered]@{
            fence_ab_metrics = Get-OptionalPropertyValue `
                $flags `
                "fence_ab_metrics" `
                $null
            enemy_hot_metrics = Get-OptionalPropertyValue `
                $flags `
                "enemy_hot_metrics" `
                $null
            guardian_overlap_metrics = Get-OptionalPropertyValue `
                $flags `
                "guardian_overlap_metrics" `
                $null
            runtime_count_scans = Get-OptionalPropertyValue `
                $flags `
                "runtime_count_scans" `
                $null
            projectile_hot_metrics = Get-OptionalPropertyValue `
                $flags `
                "projectile_hot_metrics" `
                $null
        }
    }
    return $projection | ConvertTo-Json -Depth 8 -Compress
}


function Test-FingerprintComplete {
    param([object]$Fingerprint)

    $errors = [Collections.Generic.List[string]]::new()
    if ($null -eq $Fingerprint) {
        $errors.Add("Runner result omitted fingerprint.")
        return [pscustomobject]@{ valid = $false; errors = @($errors); identity = "" }
    }
    $godot = Get-OptionalPropertyValue $Fingerprint "godot" $null
    $os = Get-OptionalPropertyValue $Fingerprint "os" $null
    $cpu = Get-OptionalPropertyValue $Fingerprint "cpu" $null
    $rendering = Get-OptionalPropertyValue $Fingerprint "rendering" $null
    $window = Get-OptionalPropertyValue $Fingerprint "window" $null
    $vsync = Get-OptionalPropertyValue $Fingerprint "vsync" $null
    $flags = Get-OptionalPropertyValue $Fingerprint "intrusive_flags" $null
    if ([string]::IsNullOrWhiteSpace(
        [string](Get-OptionalPropertyValue $Fingerprint "commit" "")
    )) {
        $errors.Add("Fingerprint commit is missing.")
    }
    if ($null -eq $Fingerprint.PSObject.Properties["dirty"]) {
        $errors.Add("Fingerprint dirty state is missing.")
    }
    if ([string]::IsNullOrWhiteSpace(
        [string](Get-OptionalPropertyValue $godot "version" "")
    )) {
        $errors.Add("Fingerprint Godot version is missing.")
    }
    if ([string]::IsNullOrWhiteSpace(
        [string](Get-OptionalPropertyValue $os "name" "")
    )) {
        $errors.Add("Fingerprint OS is missing.")
    }
    if ([string]::IsNullOrWhiteSpace(
        [string](Get-OptionalPropertyValue $cpu "name" "")
    ) -or [int](Get-OptionalPropertyValue $cpu "logical_processor_count" 0) -le 0) {
        $errors.Add("Fingerprint CPU or logical processor count is missing.")
    }
    if ([string]::IsNullOrWhiteSpace(
        [string](Get-OptionalPropertyValue $rendering "effective_method" "")
    ) -or [string]::IsNullOrWhiteSpace(
        [string](Get-OptionalPropertyValue $rendering "effective_driver" "")
    )) {
        $errors.Add("Fingerprint renderer or driver is missing.")
    }
    if ($null -eq $window -or $null -eq $vsync) {
        $errors.Add("Fingerprint window or VSync state is missing.")
    }
    if ($null -eq $Fingerprint.PSObject.Properties["seed"]) {
        $errors.Add("Fingerprint seed is missing.")
    }
    if ($null -eq $flags) {
        $errors.Add("Fingerprint intrusive flags are missing.")
    }
    return [pscustomobject]@{
        valid = $errors.Count -eq 0
        errors = @($errors)
        identity = Get-FingerprintIdentity $Fingerprint
    }
}


function Test-FingerprintCompatible {
    param(
        [object]$Expected,
        [object]$Actual
    )

    $expectedValidation = Test-FingerprintComplete $Expected
    $actualValidation = Test-FingerprintComplete $Actual
    return (
        $expectedValidation.valid -and
        $actualValidation.valid -and
        $expectedValidation.identity -ceq $actualValidation.identity
    )
}


function ConvertTo-ResourceFilePath {
    param(
        [string]$ResourcePath,
        [string]$ResolvedProjectRoot
    )

    if (-not $ResourcePath.StartsWith("res://", [StringComparison]::Ordinal)) {
        throw "Enemy config must use a res:// path: $ResourcePath"
    }
    $relativePath = $ResourcePath.Substring(6).Replace(
        "/",
        [IO.Path]::DirectorySeparatorChar
    )
    $fullPath = [IO.Path]::GetFullPath(
        (Join-Path $ResolvedProjectRoot $relativePath)
    )
    $rootPrefix = $ResolvedProjectRoot.TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Enemy config escaped the project root: $ResourcePath"
    }
    return $fullPath
}


function Get-DiscoveredEnemyConfigs {
    param([string]$ResolvedProjectRoot)

    $enemyDirectory = Join-Path $ResolvedProjectRoot "resources/config/enemies"
    $result = [Collections.Generic.List[string]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $enemyDirectory -Filter "*.tres") {
        $source = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
        if ($source -notmatch '(?m)^enemy_scene\s*=\s*ExtResource') {
            continue
        }
        $relative = [IO.Path]::GetRelativePath(
            $ResolvedProjectRoot,
            $file.FullName
        ).Replace("\", "/")
        $result.Add("res://$relative")
    }
    $result.Sort([StringComparer]::Ordinal)
    return @($result)
}


function Get-NormalizedEnemyConfigs {
    param(
        [string[]]$RequestedConfigs,
        [string]$ResolvedProjectRoot
    )

    $sourceConfigs = if ($RequestedConfigs.Count -gt 0) {
        @($RequestedConfigs)
    } else {
        @(Get-DiscoveredEnemyConfigs $ResolvedProjectRoot)
    }
    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $result = [Collections.Generic.List[string]]::new()
    foreach ($config in $sourceConfigs) {
        $trimmed = $config.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }
        $fullPath = ConvertTo-ResourceFilePath $trimmed $ResolvedProjectRoot
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "Enemy config does not exist: $trimmed"
        }
        $source = Get-Content -LiteralPath $fullPath -Raw -Encoding UTF8
        if ($source -notmatch '(?m)^enemy_scene\s*=\s*ExtResource') {
            throw "Resource is not an EnemyConfig fixture: $trimmed"
        }
        if ($seen.Add($trimmed)) {
            $result.Add($trimmed)
        }
    }
    return @($result)
}


function New-MatrixCases {
    param(
        [string[]]$Configs,
        [int[]]$Counts,
        [string]$BasicConfig
    )

    $cases = [Collections.Generic.List[object]]::new()
    $cases.Add([pscustomobject][ordered]@{
        case_key = "control_zero|0"
        case_id = "control_zero_0"
        label = "0-enemy control"
        enemy_config = $BasicConfig
        enemy_count = 0
        control = "zero"
        is_control = $true
    })
    foreach ($count in $Counts) {
        $cases.Add([pscustomobject][ordered]@{
            case_key = "control_basic|$BasicConfig|$count"
            case_id = "control_basic_$count"
            label = "basic control ($count)"
            enemy_config = $BasicConfig
            enemy_count = $count
            control = "basic"
            is_control = $true
        })
    }
    foreach ($config in $Configs) {
        if ($config.Equals($BasicConfig, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $name = [IO.Path]::GetFileNameWithoutExtension($config)
        foreach ($count in $Counts) {
            $cases.Add([pscustomobject][ordered]@{
                case_key = "enemy|$config|$count"
                case_id = "enemy_${name}_$count"
                label = "$name ($count)"
                enemy_config = $config
                enemy_count = $count
                control = "none"
                is_control = $false
            })
        }
    }
    return @($cases)
}


function New-RoundPlans {
    param(
        [object[]]$Cases,
        [int]$OrderSeed
    )

    $plans = [Collections.Generic.List[object]]::new()
    foreach ($definition in $roundDefinitions) {
        $orderedCases = switch ($definition.order) {
            "forward" { @($Cases) }
            "reverse" { @(Get-ReversedItems $Cases) }
            "fixed_random" { @(Get-FixedRandomItems $Cases $OrderSeed) }
            default { throw "Unsupported order strategy: $($definition.order)" }
        }
        $plans.Add([pscustomobject][ordered]@{
            round = $definition.round
            order = $definition.order
            case_ids = @($orderedCases | ForEach-Object { $_.case_id })
            cases = $orderedCases
        })
    }
    return @($plans)
}


function ConvertTo-BoolParameterToken {
    param(
        [string]$Name,
        [bool]$Value
    )

    $literal = $Value.ToString().ToLowerInvariant()
    return "-${Name}:`$$literal"
}


function Get-BackendArguments {
    param(
        [object]$Case,
        [string]$BackendRunner,
        [string]$ResolvedProjectRoot,
        [int]$ChildTimeoutSeconds
    )

    $gateProfile = if ([int]$Case.enemy_count -eq 300) {
        "cpu60"
    } else {
        "diagnostic"
    }
    $quickForRun = $QuickValidation -and $gateProfile -eq "cpu60"
    return @(
        "-NoProfile",
        "-File", $BackendRunner,
        "-EnemyConfig", [string]$Case.enemy_config,
        "-GateProfile", $gateProfile,
        (ConvertTo-BoolParameterToken "QuickValidation" $quickForRun),
        "-Phase", "engagement",
        "-EnemyCount", [string]$Case.enemy_count,
        "-WarmupFrames", [string]$WarmupFrames,
        "-SampleFrames", [string]$SampleFrames,
        (ConvertTo-BoolParameterToken "Headless" $true),
        "-FixedFps", "60",
        "-MaxFps", "0",
        "-RenderingMethod", $RenderingMethod,
        "-RenderingDriver", $RenderingDriver,
        "-Seed", [string]$Seed,
        "-WallP95BudgetMs", $WallP95BudgetMs.ToString(
            "G17",
            [Globalization.CultureInfo]::InvariantCulture
        ),
        "-WallP99BudgetMs", $WallP99BudgetMs.ToString(
            "G17",
            [Globalization.CultureInfo]::InvariantCulture
        ),
        "-Over33RatioBudget", $Over33RatioBudget.ToString(
            "G17",
            [Globalization.CultureInfo]::InvariantCulture
        ),
        (ConvertTo-BoolParameterToken "FenceAbMetrics" $false),
        (ConvertTo-BoolParameterToken "EnemyHotMetrics" $false),
        (ConvertTo-BoolParameterToken "GuardianOverlapMetrics" $false),
        (ConvertTo-BoolParameterToken "RuntimeCountScans" $false),
        (ConvertTo-BoolParameterToken "ProjectileHotMetrics" $false),
        "-GodotExe", $GodotExe,
        "-ProjectRoot", $ResolvedProjectRoot,
        "-ExternalSampleIntervalMs", [string]$ExternalSampleIntervalMs,
        "-MinimumExternalSamples", [string]$MinimumExternalSamples,
        "-TimeoutSeconds", [string]$ChildTimeoutSeconds
    )
}


function Invoke-BackendRunner {
    param(
        [string[]]$Arguments,
        [int]$WaitTimeoutSeconds
    )

    $pwshCommand = Get-Command pwsh -ErrorAction Stop
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pwshCommand.Source
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        $null = $startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $startedUtc = [DateTime]::UtcNow
    try {
        if (-not $process.Start()) {
            throw "Unable to start the cohort runner process."
        }
        $script:ActiveChildProcess = $process
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($WaitTimeoutSeconds * 1000)) {
            try {
                $process.Kill($true)
            }
            catch {
                # The process may have exited between the timeout and kill.
            }
            $process.WaitForExit(5000) | Out-Null
            return [pscustomobject]@{
                timed_out = $true
                exit_code = -1
                elapsed_seconds = ([DateTime]::UtcNow - $startedUtc).TotalSeconds
                stdout = ""
                stderr = "Backend runner exceeded its matrix wait timeout."
                payload = $null
            }
        }
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $matches = [regex]::Matches($stdout, '(?m)^\{[^\r\n]+\}\r?$')
        $payload = if ($matches.Count -gt 0) {
            $matches[$matches.Count - 1].Value | ConvertFrom-Json -Depth 100
        } else {
            $null
        }
        return [pscustomobject]@{
            timed_out = $false
            exit_code = [int]$process.ExitCode
            elapsed_seconds = ([DateTime]::UtcNow - $startedUtc).TotalSeconds
            stdout = $stdout
            stderr = $stderr
            payload = $payload
        }
    }
    finally {
        $script:ActiveChildProcess = $null
        $process.Dispose()
    }
}


function Get-TextTail {
    param(
        [string]$Text,
        [int]$MaximumCharacters = 2000
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return ""
    }
    if ($Text.Length -le $MaximumCharacters) {
        return $Text.Trim()
    }
    return $Text.Substring($Text.Length - $MaximumCharacters).Trim()
}


function ConvertTo-RoundRecord {
    param(
        [object]$Case,
        [int]$Round,
        [string]$Order,
        [int]$SequenceIndex,
        [object]$Invocation
    )

    $payload = $Invocation.payload
    $godot = Get-OptionalPropertyValue $payload "godot" $null
    $wall = Get-OptionalPropertyValue $godot "wall_ms" $null
    $frameBudget = Get-OptionalPropertyValue $godot "frame_budget" $null
    $external = Get-OptionalPropertyValue $payload "external_process" $null
    $wallP50 = [double](Get-OptionalPropertyValue $wall "p50" 0.0)
    $wallP95 = [double](Get-OptionalPropertyValue $wall "p95" 0.0)
    $wallP99 = [double](Get-OptionalPropertyValue $wall "p99" 0.0)
    $over33 = [double](
        Get-OptionalPropertyValue $frameBudget "over_33_333_ratio" 0.0
    )
    $metricsAvailable = (
        $null -ne $payload -and
        $null -ne $godot -and
        $wallP95 -gt 0.0 -and
        $wallP99 -gt 0.0
    )
    $runValid = (
        -not [bool]$Invocation.timed_out -and
        $null -ne $payload -and
        [bool](Get-OptionalPropertyValue $payload "valid" $false) -and
        $metricsAvailable
    )
    $withinBudgets = (
        $metricsAvailable -and
        $wallP95 -le $WallP95BudgetMs -and
        $wallP99 -le $WallP99BudgetMs -and
        $over33 -le $Over33RatioBudget
    )
    return [pscustomobject][ordered]@{
        case_key = $Case.case_key
        case_id = $Case.case_id
        label = $Case.label
        enemy_config = $Case.enemy_config
        enemy_count = $Case.enemy_count
        control = $Case.control
        is_control = $Case.is_control
        round = $Round
        order = $Order
        sequence_index = $SequenceIndex
        backend_profile = if ([int]$Case.enemy_count -eq 300) {
            "cpu60"
        } else {
            "diagnostic"
        }
        process_exit_code = $Invocation.exit_code
        elapsed_seconds = [Math]::Round($Invocation.elapsed_seconds, 3)
        valid = $runValid
        passed = $runValid -and $withinBudgets
        backend_verdict = [string](
            Get-OptionalPropertyValue $payload "verdict" "invalid"
        )
        metrics = [ordered]@{
            wall_p50_ms = $wallP50
            wall_p95_ms = $wallP95
            wall_p99_ms = $wallP99
            over_33_333_ratio = $over33
            whole_process_cpu_average_percent = [double](
                Get-OptionalPropertyValue `
                    $external `
                    "whole_process_cpu_average_percent" `
                    0.0
            )
            whole_process_cpu_core_equivalent_average_percent = [double](
                Get-OptionalPropertyValue `
                    $external `
                    "whole_process_cpu_core_equivalent_average_percent" `
                    0.0
            )
            working_p95_mib = [double](
                Get-OptionalPropertyValue $external "working_p95_mib" 0.0
            )
            private_p95_mib = [double](
                Get-OptionalPropertyValue $external "private_p95_mib" 0.0
            )
            external_sample_count = [int](
                Get-OptionalPropertyValue $external "sample_count" 0
            )
        }
        fingerprint = Get-OptionalPropertyValue $payload "fingerprint" $null
        violations = @(
            Get-OptionalPropertyValue $payload "violations" @()
        )
        error = if ($null -eq $payload) {
            Get-TextTail $Invocation.stderr
        } else {
            ""
        }
    }
}


function Get-MetricMedian {
    param(
        [object[]]$Records,
        [string]$MetricName
    )

    $values = @(
        $Records |
            Where-Object { [bool]$_.valid } |
            ForEach-Object { [double]$_.metrics[$MetricName] }
    )
    return Get-MedianValue $values
}


function New-CaseAggregates {
    param(
        [object[]]$Cases,
        [object[]]$Records
    )

    $aggregates = [Collections.Generic.List[object]]::new()
    foreach ($case in $Cases) {
        $caseRecords = @(
            $Records |
                Where-Object { $_.case_key -ceq $case.case_key } |
                Sort-Object -Property round
        )
        $vote = Get-TwoOfThreeVerdict $caseRecords
        $p95Values = @(
            $caseRecords |
                Where-Object { [bool]$_.valid } |
                ForEach-Object { [double]$_.metrics.wall_p95_ms }
        )
        $cv = Get-CoefficientOfVariation $p95Values
        $rerunRecommended = $null -ne $cv -and $cv -gt $CvRerunThreshold
        $aggregates.Add([pscustomobject][ordered]@{
            case_key = $case.case_key
            case_id = $case.case_id
            label = $case.label
            enemy_config = $case.enemy_config
            enemy_count = $case.enemy_count
            control = $case.control
            is_control = $case.is_control
            verdict = $vote.verdict
            valid_round_count = $vote.valid_round_count
            pass_count = $vote.pass_count
            fail_count = $vote.fail_count
            required_pass_count = $vote.required_pass_count
            median_of_round_percentiles = [ordered]@{
                wall_p50_ms = Get-MetricMedian $caseRecords "wall_p50_ms"
                wall_p95_ms = Get-MetricMedian $caseRecords "wall_p95_ms"
                wall_p99_ms = Get-MetricMedian $caseRecords "wall_p99_ms"
                over_33_333_ratio = Get-MetricMedian `
                    $caseRecords `
                    "over_33_333_ratio"
                whole_process_cpu_average_percent = Get-MetricMedian `
                    $caseRecords `
                    "whole_process_cpu_average_percent"
                whole_process_cpu_core_equivalent_average_percent = Get-MetricMedian `
                    $caseRecords `
                    "whole_process_cpu_core_equivalent_average_percent"
                working_p95_mib = Get-MetricMedian $caseRecords "working_p95_mib"
                private_p95_mib = Get-MetricMedian $caseRecords "private_p95_mib"
            }
            primary_metric = "wall_p95_ms"
            coefficient_of_variation = if ($null -eq $cv) {
                $null
            } else {
                [Math]::Round($cv, 6)
            }
            cv_threshold = $CvRerunThreshold
            rerun_recommended = $rerunRecommended
            rerun_prompt = if ($rerunRecommended) {
                "wall_p95_ms CV exceeds $($CvRerunThreshold * 100)%; rerun all three rounds for this case."
            } else {
                ""
            }
            rounds = $caseRecords
        })
    }
    return @($aggregates)
}


function New-MainRanking {
    param([object[]]$Aggregates)

    $rankable = @(
        $Aggregates |
            Where-Object {
                [int]$_.enemy_count -eq 300 -and
                $_.control -ne "zero" -and
                $_.verdict -ne "invalid"
            } |
            Sort-Object `
                @{ Expression = {
                    [double]$_.median_of_round_percentiles.wall_p95_ms
                }; Descending = $true }, `
                @{ Expression = { [string]$_.case_id }; Descending = $false }
    )
    $ranking = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $rankable.Count; $index += 1) {
        $aggregate = $rankable[$index]
        $ranking.Add([pscustomobject][ordered]@{
            rank = $index + 1
            case_id = $aggregate.case_id
            label = $aggregate.label
            enemy_config = $aggregate.enemy_config
            is_basic_control = $aggregate.control -eq "basic"
            verdict = $aggregate.verdict
            unacceptable = $aggregate.verdict -eq "failed"
            median_wall_p95_ms = (
                $aggregate.median_of_round_percentiles.wall_p95_ms
            )
            median_wall_p99_ms = (
                $aggregate.median_of_round_percentiles.wall_p99_ms
            )
            median_cpu_core_equivalent_percent = (
                $aggregate.median_of_round_percentiles.
                    whole_process_cpu_core_equivalent_average_percent
            )
            coefficient_of_variation = $aggregate.coefficient_of_variation
            rerun_recommended = $aggregate.rerun_recommended
            pass_count = $aggregate.pass_count
            fail_count = $aggregate.fail_count
        })
    }
    return @($ranking)
}


function New-ScalingSeries {
    param([object[]]$Aggregates)

    $series = [Collections.Generic.List[object]]::new()
    $groups = $Aggregates |
        Where-Object { $_.control -ne "zero" } |
        Group-Object -Property enemy_config
    foreach ($group in $groups) {
        $points = @(
            $group.Group |
                Sort-Object -Property enemy_count |
                ForEach-Object {
                    [pscustomobject][ordered]@{
                        enemy_count = $_.enemy_count
                        verdict = $_.verdict
                        median_wall_p95_ms = (
                            $_.median_of_round_percentiles.wall_p95_ms
                        )
                        median_wall_p99_ms = (
                            $_.median_of_round_percentiles.wall_p99_ms
                        )
                        coefficient_of_variation = $_.coefficient_of_variation
                    }
                }
        )
        $series.Add([pscustomobject][ordered]@{
            enemy_config = $group.Name
            points = $points
        })
    }
    return @($series)
}


function New-SelfTestFingerprint {
    param([string]$Commit)

    return [pscustomobject][ordered]@{
        commit = $Commit
        dirty = $false
        source_control_supported = $true
        godot = [pscustomobject]@{ version = "4.test" }
        os = [pscustomobject]@{ name = "TestOS"; version = "1" }
        cpu = [pscustomobject]@{
            name = "TestCPU"
            logical_processor_count = 8
        }
        gpu = "TestGPU"
        rendering = [pscustomobject]@{
            requested_method = "gl_compatibility"
            effective_method = "gl_compatibility"
            requested_driver = "opengl3"
            effective_driver = "opengl3"
        }
        window = [pscustomobject]@{
            requested_size = @(0, 0)
            effective_size = @(0, 0)
        }
        vsync = [pscustomobject]@{
            requested_mode = "project"
            effective_mode = "disabled"
        }
        seed = 7
        intrusive_flags = [pscustomobject]@{
            fence_ab_metrics = $false
            enemy_hot_metrics = $false
            guardian_overlap_metrics = $false
            runtime_count_scans = $false
            projectile_hot_metrics = $false
        }
    }
}


function Invoke-MatrixSelfTest {
    $tests = [Collections.Generic.List[object]]::new()
    $fixtures = @(
        [pscustomobject]@{ case_key = "a"; case_id = "a" },
        [pscustomobject]@{ case_key = "b"; case_id = "b" },
        [pscustomobject]@{ case_key = "c"; case_id = "c" },
        [pscustomobject]@{ case_key = "d"; case_id = "d" },
        [pscustomobject]@{ case_key = "e"; case_id = "e" }
    )
    $forward = @($fixtures | ForEach-Object { $_.case_id })
    $reverse = @(
        Get-ReversedItems $fixtures | ForEach-Object { $_.case_id }
    )
    $randomOne = @(
        Get-FixedRandomItems $fixtures 12345 | ForEach-Object { $_.case_id }
    )
    $randomTwo = @(
        Get-FixedRandomItems $fixtures 12345 | ForEach-Object { $_.case_id }
    )
    $tests.Add([pscustomobject][ordered]@{
        name = "round_ordering"
        passed = (
            ($forward -join ",") -ceq "a,b,c,d,e" -and
            ($reverse -join ",") -ceq "e,d,c,b,a" -and
            ($randomOne -join ",") -ceq "e,c,d,a,b" -and
            ($randomOne -join ",") -ceq ($randomTwo -join ",") -and
            ($randomOne | Sort-Object) -join "," -ceq "a,b,c,d,e"
        )
        forward = $forward
        reverse = $reverse
        fixed_random = $randomOne
    })

    $twoPasses = Get-TwoOfThreeVerdict @(
        [pscustomobject]@{ valid = $true; passed = $true },
        [pscustomobject]@{ valid = $true; passed = $false },
        [pscustomobject]@{ valid = $true; passed = $true }
    )
    $twoFailures = Get-TwoOfThreeVerdict @(
        [pscustomobject]@{ valid = $true; passed = $false },
        [pscustomobject]@{ valid = $true; passed = $true },
        [pscustomobject]@{ valid = $true; passed = $false }
    )
    $invalidRound = Get-TwoOfThreeVerdict @(
        [pscustomobject]@{ valid = $true; passed = $true },
        [pscustomobject]@{ valid = $false; passed = $false },
        [pscustomobject]@{ valid = $true; passed = $true }
    )
    $tests.Add([pscustomobject][ordered]@{
        name = "two_of_three"
        passed = (
            $twoPasses.verdict -eq "passed" -and
            $twoFailures.verdict -eq "failed" -and
            $invalidRound.verdict -eq "invalid"
        )
        two_passes = $twoPasses
        two_failures = $twoFailures
        invalid_round = $invalidRound
    })

    $fingerprintA = New-SelfTestFingerprint "commit-a"
    $fingerprintAClone = New-SelfTestFingerprint "commit-a"
    $fingerprintB = New-SelfTestFingerprint "commit-b"
    $tests.Add([pscustomobject][ordered]@{
        name = "fingerprint_rejects_mixing"
        passed = (
            (Test-FingerprintCompatible $fingerprintA $fingerprintAClone) -and
            -not (Test-FingerprintCompatible $fingerprintA $fingerprintB)
        )
        identical_accepted = Test-FingerprintCompatible `
            $fingerprintA `
            $fingerprintAClone
        mixed_commit_rejected = -not (
            Test-FingerprintCompatible $fingerprintA $fingerprintB
        )
    })

    $failedTests = @($tests | Where-Object { -not [bool]$_.passed })
    return [pscustomobject][ordered]@{
        schema_version = $matrixSchemaVersion
        mode = "self_test"
        valid = $failedTests.Count -eq 0
        verdict = if ($failedTests.Count -eq 0) { "passed" } else { "failed" }
        tests = @($tests)
        violations = @(
            $failedTests | ForEach-Object {
                [pscustomobject]@{
                    code = "self_test_failure"
                    message = "Self-test failed: $($_.name)"
                }
            }
        )
    }
}


if ($SelfTest) {
    $selfTestResult = Invoke-MatrixSelfTest
    $selfTestResult | ConvertTo-Json -Depth 20 -Compress
    if (-not $selfTestResult.valid) {
        exit 1
    }
    exit 0
}

$resolvedProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
$backendRunner = Join-Path $PSScriptRoot $backendRunnerName
if (-not (Test-Path -LiteralPath $backendRunner -PathType Leaf)) {
    throw "Existing cohort runner was not found: $backendRunner"
}
if (-not (Test-Path -LiteralPath $GodotExe -PathType Leaf)) {
    throw "Godot executable was not found: $GodotExe"
}

$normalizedCounts = @($EnemyCounts | Select-Object -Unique)
if ($normalizedCounts.Count -eq 0) {
    throw "EnemyCounts must contain at least one scaling point."
}
foreach ($count in $normalizedCounts) {
    if ($count -notin $supportedEnemyCounts) {
        throw "EnemyCounts supports only 50, 100, 200, and 300; received $count."
    }
}
$normalizedCounts = @($normalizedCounts | Sort-Object)

$basicControlFile = ConvertTo-ResourceFilePath `
    $BasicControlConfig `
    $resolvedProjectRoot
if (-not (Test-Path -LiteralPath $basicControlFile -PathType Leaf)) {
    throw "Basic control config does not exist: $BasicControlConfig"
}
$normalizedConfigs = Get-NormalizedEnemyConfigs `
    $EnemyConfigs `
    $resolvedProjectRoot
if ($BasicControlConfig -notin $normalizedConfigs) {
    $normalizedConfigs = @($normalizedConfigs) + @($BasicControlConfig)
}

$matrixCases = New-MatrixCases `
    $normalizedConfigs `
    $normalizedCounts `
    $BasicControlConfig
$roundPlans = New-RoundPlans $matrixCases $RandomOrderSeed
$planProjection = [ordered]@{
    configs = @($normalizedConfigs)
    counts = @($normalizedCounts)
    cases = @($matrixCases | ForEach-Object { $_.case_key })
    rounds = @(
        $roundPlans | ForEach-Object {
            [ordered]@{ round = $_.round; order = $_.order; cases = $_.case_ids }
        }
    )
    seed = $Seed
    random_order_seed = $RandomOrderSeed
    quick_validation = $QuickValidation
    warmup_frames = $WarmupFrames
    sample_frames = $SampleFrames
    renderer = $RenderingMethod
    driver = $RenderingDriver
}
$planFingerprint = Get-Sha256Hex (
    $planProjection | ConvertTo-Json -Depth 20 -Compress
)
$settings = [ordered]@{
    plan_fingerprint = $planFingerprint
    candidate_config_count = $normalizedConfigs.Count
    case_count_per_round = $matrixCases.Count
    total_run_count = $matrixCases.Count * 3
    enemy_counts = @($normalizedCounts)
    supported_scaling_counts = $supportedEnemyCounts
    basic_control_config = $BasicControlConfig
    seed = $Seed
    random_order_seed = $RandomOrderSeed
    quick_validation = $QuickValidation
    warmup_frames = $WarmupFrames
    sample_frames = $SampleFrames
    wall_p95_budget_ms = $WallP95BudgetMs
    wall_p99_budget_ms = $WallP99BudgetMs
    over_33_333_ratio_budget = $Over33RatioBudget
    cv_rerun_threshold = $CvRerunThreshold
    rendering_method = $RenderingMethod
    rendering_driver = $RenderingDriver
    per_run_timeout_seconds = $PerRunTimeoutSeconds
    global_timeout_seconds = $GlobalTimeoutSeconds
    order_policy = @("forward", "reverse", "fixed_random")
    verdict_policy = "three valid rounds; at least two budget passes"
    primary_ranking_metric = "median of round wall_p95_ms percentiles"
    fingerprint_policy = "all backend fingerprints must match exactly"
}

if (-not $Execute) {
    $dryRun = [ordered]@{
        schema_version = $matrixSchemaVersion
        mode = "dry_run"
        valid = $true
        verdict = "planned"
        execute_required = $true
        execute_switch = "-Execute"
        backend_runner = $backendRunner
        settings = $settings
        cases = @($matrixCases)
        rounds = @(
            $roundPlans | ForEach-Object {
                [ordered]@{
                    round = $_.round
                    order = $_.order
                    case_ids = $_.case_ids
                }
            }
        )
        violations = @()
    }
    $dryRun | ConvertTo-Json -Depth 20 -Compress
    exit 0
}

$startedUtc = [DateTime]::UtcNow
$globalDeadlineUtc = $startedUtc.AddSeconds($GlobalTimeoutSeconds)
$records = [Collections.Generic.List[object]]::new()
$matrixViolations = [Collections.Generic.List[object]]::new()
$referenceFingerprint = $null
$referenceFingerprintIdentity = ""
$stopExecution = $false

try {
    foreach ($roundPlan in $roundPlans) {
        for ($sequenceIndex = 0; $sequenceIndex -lt $roundPlan.cases.Count; $sequenceIndex += 1) {
            $remainingSeconds = [int][Math]::Floor(
                ($globalDeadlineUtc - [DateTime]::UtcNow).TotalSeconds
            )
            if ($remainingSeconds -le 0) {
                $matrixViolations.Add([pscustomobject]@{
                    code = "global_timeout"
                    message = "Matrix exceeded its $GlobalTimeoutSeconds-second global timeout."
                })
                $stopExecution = $true
                break
            }
            $case = $roundPlan.cases[$sequenceIndex]
            $childTimeout = [Math]::Max(
                1,
                [Math]::Min($PerRunTimeoutSeconds, $remainingSeconds)
            )
            $backendArguments = Get-BackendArguments `
                $case `
                $backendRunner `
                $resolvedProjectRoot `
                $childTimeout
            $invocation = Invoke-BackendRunner `
                $backendArguments `
                $remainingSeconds
            $record = ConvertTo-RoundRecord `
                $case `
                $roundPlan.round `
                $roundPlan.order `
                $sequenceIndex `
                $invocation
            $records.Add($record)

            $fingerprintValidation = Test-FingerprintComplete $record.fingerprint
            if (-not $fingerprintValidation.valid) {
                $matrixViolations.Add([pscustomobject]@{
                    code = "fingerprint_incomplete"
                    message = "Backend fingerprint was incomplete for $($case.case_id), round $($roundPlan.round)."
                    details = $fingerprintValidation.errors
                })
                $stopExecution = $true
                break
            }
            if ($null -eq $referenceFingerprint) {
                $referenceFingerprint = $record.fingerprint
                $referenceFingerprintIdentity = $fingerprintValidation.identity
            } elseif (-not (Test-FingerprintCompatible $referenceFingerprint $record.fingerprint)) {
                $matrixViolations.Add([pscustomobject]@{
                    code = "fingerprint_mismatch"
                    message = "Mixed benchmark fingerprints were rejected at $($case.case_id), round $($roundPlan.round)."
                    expected_identity = $referenceFingerprintIdentity
                    actual_identity = $fingerprintValidation.identity
                })
                $stopExecution = $true
                break
            }
            if ($invocation.timed_out) {
                $matrixViolations.Add([pscustomobject]@{
                    code = "backend_timeout"
                    message = "Backend timed out for $($case.case_id), round $($roundPlan.round)."
                })
            }
        }
        if ($stopExecution) {
            break
        }
    }
}
finally {
    if ($null -ne $script:ActiveChildProcess -and -not $script:ActiveChildProcess.HasExited) {
        try {
            $script:ActiveChildProcess.Kill($true)
            $script:ActiveChildProcess.WaitForExit(5000) | Out-Null
        }
        catch {
            # The token-scoped child process may already be terminating.
        }
    }
}

$aggregates = New-CaseAggregates $matrixCases @($records)
$mainRanking = New-MainRanking $aggregates
$scalingSeries = New-ScalingSeries $aggregates
$rerunRecommendations = @(
    $aggregates |
        Where-Object { [bool]$_.rerun_recommended } |
        ForEach-Object {
            [pscustomobject][ordered]@{
                case_id = $_.case_id
                enemy_config = $_.enemy_config
                enemy_count = $_.enemy_count
                coefficient_of_variation = $_.coefficient_of_variation
                prompt = $_.rerun_prompt
            }
        }
)
$invalidAggregates = @($aggregates | Where-Object { $_.verdict -eq "invalid" })
$failedMainCases = @(
    $aggregates |
        Where-Object {
            [int]$_.enemy_count -eq 300 -and
            $_.control -ne "zero" -and
            $_.verdict -eq "failed"
        }
)
$matrixValid = $matrixViolations.Count -eq 0 -and $invalidAggregates.Count -eq 0
$matrixVerdict = if (-not $matrixValid) {
    "invalid"
} elseif ($failedMainCases.Count -gt 0) {
    "failed"
} else {
    "passed"
}
$result = [ordered]@{
    schema_version = $matrixSchemaVersion
    mode = "executed"
    valid = $matrixValid
    verdict = $matrixVerdict
    settings = $settings
    started_utc = $startedUtc.ToString("o")
    elapsed_seconds = [Math]::Round(
        ([DateTime]::UtcNow - $startedUtc).TotalSeconds,
        3
    )
    completed_run_count = $records.Count
    expected_run_count = $matrixCases.Count * 3
    fingerprint = $referenceFingerprint
    violations = @($matrixViolations)
    controls = @($aggregates | Where-Object { [bool]$_.is_control })
    cpu_main_ranking = $mainRanking
    unacceptable_cpu_main_cases = @(
        $mainRanking | Where-Object { [bool]$_.unacceptable }
    )
    unranked_invalid_main_cases = @(
        $invalidAggregates |
            Where-Object { [int]$_.enemy_count -eq 300 } |
            ForEach-Object { $_.case_id }
    )
    scaling_series = $scalingSeries
    case_aggregates = $aggregates
    rerun_recommendations = $rerunRecommendations
}
$result | ConvertTo-Json -Depth 30 -Compress
if ($matrixVerdict -ne "passed") {
    exit 1
}
exit 0
