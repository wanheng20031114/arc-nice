param(
    [Parameter(Mandatory = $true)][string]$Template,
    [string]$Destination = ''
)
$ErrorActionPreference = 'Stop'
if (-not $Destination) { $Destination = Join-Path $PSScriptRoot 'output/density_multiplayer_release_project' }
# Reuse the audited isolated-project setup and its path/junction checks. The
# single-player project and production main scene are never modified.
& (Join-Path $PSScriptRoot 'prepare_density_release_project.ps1') -Template $Template -Destination $Destination
$destinationRoot = [IO.Path]::GetFullPath($Destination)
$fixtureRoot = Join-Path $destinationRoot 'dev_tools'
foreach ($file in @('tower_multiplayer_density_probe.gd', 'tower_multiplayer_density_fixture.gd', 'tower_multiplayer_density_fixture.tscn', 'tower_multiplayer_density_release_entry.gd', 'tower_multiplayer_density_release_entry.tscn')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $fixtureRoot $file) -Force
}
$configPath = Join-Path $destinationRoot 'project.godot'
$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
if (-not $config.Contains('run/main_scene="res://dev_tools/tower_density_release_entry.tscn"')) { throw 'Unexpected isolated main scene' }
$config = $config.Replace('run/main_scene="res://dev_tools/tower_density_release_entry.tscn"', 'run/main_scene="res://dev_tools/tower_multiplayer_density_release_entry.tscn"')
[IO.File]::WriteAllText($configPath, $config, [Text.UTF8Encoding]::new($false))
Write-Output "MULTIPLAYER_RELEASE_EXECUTABLE=$(Join-Path $destinationRoot 'Godot_release.exe')"
