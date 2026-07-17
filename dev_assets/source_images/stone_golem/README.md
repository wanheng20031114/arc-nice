# Stone Golem source manifest

The source art was created with the built-in `imagegen` mode, then converted
into the runtime-native 64 px sprite sheet with nearest-neighbour processing.

## Source files

- `stone_golem_design_source.png`: one-character design exploration.
- `stone_golem_design_alpha.png`: background-removed design reference.
- `stone_golem_sheet_source.png`: generated 4 x 4 animation source.
- `stone_golem_sheet_alpha.png`: background-removed animation source used by
  the first runtime build.
- `stone_golem_sheet_source_v2.png`: repaired source with complete legs and
  safer separation between animation rows.
- `stone_golem_sheet_alpha_v2.png`: background-removed repaired source used by
  the current deterministic runtime build.

## Prompt set

Design prompt:

> Create an original compact blocky stone construct for a friendly-styled
> pixel-art game. Use a voxel-sandbox / Minecraft-inspired silhouette without
> copying a specific character: square stone blocks, grey and slate tones,
> sparse moss accents, short sturdy limbs, no eyes, no mouth, no face, no
> weapons, and no gore. It should read as a magically made object rather than a
> creature, feel non-brutal, and fit inside one logical 64 x 64 frame. Use hard
> pixel-art edges, no antialiasing, and a pure #ff00ff chroma background.

Animation prompt:

> Draw the exact same faceless blocky stone construct as a clean 4 x 4
> animation sheet. Keep identical scale, feet anchor, body proportions,
> palette, lighting, and left/right readability in every cell. Row 1: four
> slow walking frames. Row 2: four readable ground-slam windup frames, lifting
> and bracing before impact. Row 3: four ground-slam attack frames with the
> impact ring and a few harmless stone chips contained inside the cell. Row 4:
> four non-gory death frames settling into inert rubble. No eyes, mouth, face,
> text, border, watermark, gradients, blur, or antialiasing. Use hard pixel-art
> edges and a pure #ff00ff chroma background.

Repair prompt:

> Repair the supplied stone-golem animation sheet by changing only frame
> layout and any already-clipped lower-leg/foot pixels. Preserve the exact
> same faceless blocky construct, palette, materials, poses, proportions,
> lighting, moss accents, and non-brutal style. Reconstruct complete lower
> legs and feet wherever the original grid boundary cut them off. Keep the
> exact 4 x 4 row order: move, windup, ground slam, and non-gory death. Center
> every pose at the same scale and feet anchor, keep all body parts, chips, and
> impact rings inside their own cell with generous padding, and use a flat
> #ff00ff background with no grid, text, border, blur, or antialiasing.

## Deterministic runtime build

```powershell
python dev_tools/process_stone_golem_sheet.py `
  dev_assets/source_images/stone_golem/stone_golem_sheet_alpha_v2.png `
  resources/texture/stone_golem.png

python agent_skills/enemy-generation-pipeline/scripts/analyze_enemy_sheet.py `
  resources/texture/stone_golem.png `
  --grid 4x4 `
  --virtual-size 64x64 `
  --body-anchor 32x57 `
  --safe-padding 4
```

The output is a 256 x 256 lossless sheet containing sixteen native 64 x 64
frames. Runtime scale is `Vector2.ONE`, texture filtering is Nearest, and
mipmaps are disabled. The processing script detects transparent source gutters
instead of assuming every generated row is exactly one quarter of the source
height, which prevents feet and ground-slam effects from being cut before
downscaling.
