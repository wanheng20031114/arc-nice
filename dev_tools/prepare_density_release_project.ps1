param(
    [Parameter(Mandatory = $true)][string]$Template,
    [string]$Destination = ''
)
$ErrorActionPreference = 'Stop'
$sourceRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
if (-not $Destination) { $Destination = Join-Path $PSScriptRoot 'output/density_release_project' }
$destinationRoot = [IO.Path]::GetFullPath($Destination)
if (-not $destinationRoot.StartsWith((Join-Path $PSScriptRoot 'output') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The disposable runtime project must stay under dev_tools/output.'
}
New-Item -ItemType Directory -Path $destinationRoot -Force | Out-Null
# No editor is launched against this project. Junctions share existing imported
# assets and production code without duplicating gigabytes or changing the game
# project's main scene. dev_tools is copied narrowly to avoid a directory cycle.
foreach ($directory in @('scene', 'resources', 'addons', '.godot')) {
    $link = Join-Path $destinationRoot $directory
    $target = Join-Path $sourceRoot $directory
    if (Test-Path -LiteralPath $link) {
        $existing = Get-Item -LiteralPath $link -Force
        if ($existing.LinkType -ne 'Junction' -or $existing.Target -ne $target) {
            throw "Unexpected existing path at $link"
        }
    } else {
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
    }
}
foreach ($file in @('run_state.gd', 'run_state.gd.uid', 'default_bus_layout.tres', 'icon.svg', 'icon.svg.import')) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot $file) -Destination (Join-Path $destinationRoot $file) -Force
}
$fixtureRoot = Join-Path $destinationRoot 'dev_tools'
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
foreach ($file in @('tower_density_probe.gd', 'tower_density_fixture.gd', 'tower_density_enemy_cohort.gd', 'tower_density_release_entry.gd', 'tower_density_release_entry.tscn')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $fixtureRoot $file) -Force
}
$config = Get-Content -LiteralPath (Join-Path $sourceRoot 'project.godot') -Raw -Encoding UTF8
if (-not $config.Contains('run/main_scene="res://scene/main_menu.tscn"')) { throw 'Unexpected production main scene' }
$config = $config.Replace('run/main_scene="res://scene/main_menu.tscn"', 'run/main_scene="res://dev_tools/tower_density_release_entry.tscn"')
[IO.File]::WriteAllText((Join-Path $destinationRoot 'project.godot'), $config, (New-Object Text.UTF8Encoding($false)))
$executable = Join-Path $destinationRoot 'Godot_release.exe'
Copy-Item -LiteralPath (Resolve-Path -LiteralPath $Template).Path -Destination $executable -Force
Write-Output "DENSITY_RELEASE_PROJECT=$destinationRoot"
Write-Output "DENSITY_RELEASE_EXECUTABLE=$executable"
Write-Output "DENSITY_RELEASE_SHA256=$((Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash)"
