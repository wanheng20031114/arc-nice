# Elite Stone Golem source manifest

The elite sheet is derived only from the current runtime
`resources/texture/enemy/artificial_creation/stone_golem.png`. That file contains the user's latest
hand-repaired outline, complete legs, and internal pixels, so older generated
stone-golem sources must not be substituted for it.

## Source files

- `stone_golem_elite_detail_imagegen_reference.png`: built-in imagegen design
  reference for sparse ruby chips and mineral scratches. Its geometry and
  opaque black background are not suitable for runtime use.
- `stone_golem_elite_detail_overlay.png`: exact transparent native-pixel layer
  composited over the current base sheet. Every opaque pixel in this file is
  part of the reviewed ruby-detail mask.

## Image generation design pass

Mode: built-in `imagegen`, `precise-object-edit`.

Prompt:

> Use the supplied current user-repaired 4 x 4 stone-golem sprite sheet as the
> sole geometry reference. Create an elite variant by adding only sparse,
> deliberate red strength-signaling details: thin dark-crimson mineral
> scratches or crystal veins across a few broad interior stone faces, plus
> occasional tiny embedded ruby-like gem chips with a one-pixel highlight.
> Keep at least 90–95% of the original stone unchanged. Preserve every pose,
> scale, silhouette, feet anchor, external black outline, transparent boundary,
> frame placement, internal stone shading, and complete leg pixel. The accents
> must follow the same body blocks across frames and must not flicker. Do not
> add broad red panels, a red outer outline, a face, eyes, mouth, glow,
> gradients, blur, antialiasing, background, grid, text, or watermark.

The design reference established the visual language only. The final runtime
pixels were redrawn at native 64 px resolution against the exact base alpha
mask instead of downscaling the generated reference.

## Deterministic runtime build

```powershell
python dev_tools/create_stone_golem_elite_sheet.py `
  resources/texture/enemy/artificial_creation/stone_golem.png `
  resources/texture/enemy/artificial_creation/stone_golem_elite.png `
  --overlay-output `
  dev_assets/source_images/stone_golem_elite/stone_golem_elite_detail_overlay.png
```

The build no longer recolors normalized body regions. It performs three narrow
operations:

1. Existing interior moss texture is mapped to five ruby-mineral shades,
   preserving its authored motion across frames.
2. One 8-pixel chest crystal is placed on each live pose and follows the torso
   stone. It breaks into 7, 6, 4, then 3 pixels through the death animation.
3. One 4–5 pixel angular vein follows the same screen-left shoulder/upper-arm
   stone in every pose.

The compositor asserts that alpha remains binary and identical, every
eight-neighbour outer-boundary RGBA pixel is untouched, explicit details never
cover dark outlines or cracks, and the final diff exactly equals the transparent
overlay mask.

The current output changes 278 of 12,275 opaque pixels (2.26%), leaving 97.74%
of the base sheet byte-for-byte unchanged. Per-frame changes range from 10 to
25 pixels. The result remains a lossless 256 x 256 RGBA sheet with sixteen
native 64 x 64 frames.
