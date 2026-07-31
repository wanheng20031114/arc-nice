# Multiplayer lobby icon source

The runtime icons in `resources/texture/ui/multiplayer/` were derived from
`multiplayer_lobby_icon_atlas_chroma.png` with the built-in ImageGen tool.
`multiplayer_lobby_icon_atlas_transparent.png` is the chroma-keyed intermediate,
and `crops/` retains the full-resolution per-cell sources used by the pixel
pipeline.

Reference inputs:

- `resources/texture/ui/menu_rooftop_garden_background.png`
- `resources/texture/plant_defense/grape_arc_tower/icon.png`

Processing:

```powershell
python C:\Users\wanheng\.codex\skills\.system\imagegen\scripts\remove_chroma_key.py `
  --input multiplayer_lobby_icon_atlas_chroma.png `
  --out multiplayer_lobby_icon_atlas_transparent.png `
  --key-color "#ff00ff" --tolerance 50 --spill-cleanup --force

python dev_tools\process_multiplayer_lobby_icons.py `
  dev_assets\source_images\multiplayer_lobby\multiplayer_lobby_icon_atlas_transparent.png `
  resources\texture\ui\multiplayer `
  --source-crops-dir dev_assets\source_images\multiplayer_lobby\crops
```

Exact prompt:

```text
Use case: ui-mockup
Asset type: project-bound pixel-art UI icon sprite sheet for a Godot multiplayer lobby
Primary request: Create exactly eight distinct, text-free pixel-art UI icons arranged in an exact 4-column by 2-row grid.
Input images: Image 1 is the lobby rooftop-garden palette and atmosphere reference; Image 2 is the reference for crisp small-scale game icon rendering, outline weight, and readable silhouettes.
Scene/backdrop: perfectly flat uniform solid #ff00ff chroma-key background, with no shadows, gradients, texture, grid lines, dividers, reflections, or lighting variation. Do not use #ff00ff in any icon.
Style/medium: true hand-crafted game pixel art, crisp hard pixel clusters, one-pixel dark outline at an eventual 32x32 icon scale, limited deep-teal / warm-brass / ivory / leaf-green palette matching the references, no antialias blur.
Composition/framing: exact 4x2 atlas; each icon occupies one equal cell, centered, same apparent scale, generous empty padding, no overlap. Row 1 left to right: (1) ordinary adventure mode — crossed short sword and travel map; (2) tower-defense mode — sturdy living wooden tower with leaf and shield; (3) test arena P1 — one laboratory flask combined with a small leaf and wrench; (4) test arena P2 — two small laboratory flasks beside a training target. Row 2 left to right: (5) public online — small globe with two radio arcs; (6) LAN — two linked computer terminals; (7) create room — brass key with a clear plus symbol; (8) start game — rally flag with a small forward arrow.
Constraints: exactly eight icons and no extra symbols; icons must remain recognizable when reduced to 32x32; no words, letters, digits, labels, watermark, border frames, cast shadows, or decorative background. Keep all subjects fully separated from the chroma background with crisp edges.
```
