# Enemy Sprite Pipeline Reference

## Success Pattern From Capoo Mage

The Capoo mage replacement worked because the asset pipeline stopped treating the sheet as a generic 4x4 grid and started treating each frame as a body anchored sprite:

- The source alpha sheet was kept as the canonical texture instead of downscaling too early.
- Each frame was measured independently.
- The body foot anchor was extracted from the main body color component, not from the weapon, hat, projectile, or VFX.
- All frames used a consistent logical frame size.
- Actual source regions were clipped to their own source cells, then `AtlasTexture.margin` restored a stable logical frame.
- The `AnimatedSprite2D` scale and position were recalculated from the logical frame anchor.
- A preview with anchor crosshairs caught frame contamination before final tests.

This is the preferred pattern for future enemy sprite replacements.

## Design Phase

Start with a single high-quality sample. Validate:

- The enemy reads clearly at expected game scale.
- The silhouette is not dependent on fine details.
- Body color is separable from outfit, weapon, glow, and background.
- Weapons, hats, robes, backpacks, spell circles, or other attachments are visually allowed to extend, but the body remains the size reference.
- The design has enough pose range for movement, windup, attack, and death rows.

Do not accept a weak sample because the sheet is already generated. Regenerate early.

## Body Color And Anchor Strategy

Use the most stable body part as the anchor source. For Capoo-style enemies, the blue body is better than:

- Hat top, because it bends and rises.
- Weapon, because it extends left/right and may disappear in death.
- Spell/projectile VFX, because it changes size and may be detached.
- Full alpha bbox, because attack effects and staffs skew the center.

Preferred anchor order:

1. Largest connected component matching the known body color range.
2. Largest connected alpha component if the body color cannot be isolated.
3. Full visible alpha bbox only as a fallback.

For foot-aligned enemies, anchor x should be the body component horizontal center, and anchor y should be the body component bottom.

## Background Color Selection

Use alpha whenever possible. If image generation cannot provide clean alpha, use a pure flat chroma background.

Choose the chroma color by distance from the actual sprite palette:

- Inspect the accepted single sample first.
- Collect dominant body, outline, weapon, VFX, and clothing colors.
- Test candidate backgrounds such as magenta, green, cyan, red, yellow, and blue.
- Pick the candidate with the largest minimum RGB distance from important sprite colors.
- Avoid colors that appear in glow, outlines, magic effects, eyes, weapons, or UI-like markings.

Practical guidance:

- Green works poorly for green enemies, poison effects, or foliage-like weapons.
- Magenta works poorly for purple magic, pink VFX, or red-blue highlights.
- Cyan works poorly for blue bodies, ice effects, or pale magic.
- Yellow works poorly for gold trims, fire highlights, and lightning.
- Red works poorly for fire, blood, danger VFX, or red eyes.

Prompt for a flat background explicitly:

```text
pure flat chroma [color] background, no gradient, no shadow, no contact shadow,
no glow on the background, no texture, no text, no border
```

When removing chroma:

- Flood fill or propagate from the image border through pixels near the key color.
- Do not delete every matching pixel globally.
- Despill only visible fringe pixels near the removed background.
- Save an alpha debug image before slicing.

## Animation Sheet Prompt Contract

Ask for a sheet only after sample quality is good. Specify:

- Exact grid size, usually 4 columns x 4 rows for this enemy family.
- Row names and meanings.
- Stable camera, stable body size, same pivot/feet position.
- One full character per cell.
- No overlap between cells.
- Enough empty padding for weapons and VFX.
- Transparent alpha or pure flat chosen chroma background.

Example:

```text
Create a pixel art enemy sprite sheet for the accepted design.
4 columns x 4 rows.
Row 1: move cycle.
Row 2: attack windup / spell charging.
Row 3: attack release.
Row 4: death / defeated.
Keep the body exactly the same size in every frame.
Keep the feet/body anchor in the same relative position in every cell.
Weapons, hat, and magic effects may move, but must not change the body scale.
Use pure flat [chosen chroma color] background with no shadows or gradients.
No text, no labels, no frame borders.
```

## Slicing Strategy

Do not assume equal grid cells are enough. Use them only as rough source-cell bounds.

For each cell:

1. Crop the rough grid cell.
2. Find the visible alpha bbox.
3. Find the body component bbox.
4. Compute global body anchor.
5. Create a target logical frame around the anchor.
6. Validate that the target logical frame contains the current cell's visible bbox.
7. If the logical frame crosses into a neighboring source cell, intersect the actual AtlasTexture `region` with the current cell and use `margin` to preserve the logical size.

Use this pattern in `.tres` files:

```text
[sub_resource type="AtlasTexture" id="AtlasTexture_move_0"]
atlas = ExtResource("1_texture")
region = Rect2(actual_left, actual_top, actual_width, actual_height)
margin = Rect2(offset_x_inside_logical_frame, offset_y_inside_logical_frame, missing_width, missing_height)
filter_clip = true
```

`region.size + margin.size` should equal the logical frame size for every frame.

## Scaling And Centering

After slicing, calculate the scene transform from the logical frame.

Definitions:

- `logical_frame_size`: the AtlasTexture `get_size()` result, including margin.
- `body_anchor`: the stable anchor inside that logical frame.
- `sprite_scale`: the chosen Godot `AnimatedSprite2D.scale`.
- `desired_world_anchor`: where the body anchor should land in the enemy scene.

Formula:

```text
local_anchor_offset = (body_anchor - logical_frame_size / 2) * sprite_scale
sprite_position = desired_world_anchor - local_anchor_offset
```

If the collision shape is centered and its bottom is the foot location, `desired_world_anchor.y` is usually close to `collision_shape_height / 2`.

Always verify this with a preview:

- Draw every frame into its logical frame.
- Draw a crosshair at `body_anchor`.
- Check that the body stays steady while hats, weapons, and VFX move around it.
- Check for neighboring-frame fragments.

## Compression And Import

Pixel art rules:

- Use nearest-neighbor scaling only.
- Avoid resizing before the final slicing strategy is known.
- Prefer keeping the original alpha source as the canonical texture when it is clean.
- Use lossless PNG optimization only.
- Avoid lossy compression or palette conversion that changes alpha edges unless visually inspected.
- In Godot, keep mipmaps off for small pixel sprites unless there is a deliberate zoom pipeline.
- Use `texture_filter = 2` or the project's established pixel filtering convention.

## Godot Integration Checklist

For each enemy replacement:

- Preserve `Texture2D` and `SpriteFrames` UIDs when replacing existing resources.
- Keep animation names matching configs, usually `move`, `windup`, `attack`, `death`.
- Update the enemy `.tscn` directly rather than adding dynamic setup code.
- Reimport changed PNGs with Godot.
- Run focused smoke tests.
- Add or update smoke assertions for:
  - texture size;
  - animation names;
  - frame counts;
  - AtlasTexture logical frame size;
  - region bounds inside atlas;
  - scene `AnimatedSprite2D.position`;
  - scene `AnimatedSprite2D.scale`.
- Check for and clean up headless/import Godot processes before final reporting.

## When To Regenerate Instead Of Fix

Regenerate when:

- Body scale differs per row.
- Props are cropped in several frames.
- Background bleeds into sprite outlines too heavily.
- Chroma color appears inside key sprite details.
- Multiple poses overlap within a cell.
- The design is unreadable at game scale.

Use code processing when:

- The art is good but cells are uneven.
- The body anchor is stable but the grid is imprecise.
- Background is removable with edge-connected chroma removal.
- Minor despill or alpha cleanup is sufficient.
