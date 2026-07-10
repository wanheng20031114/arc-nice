# Hoe Cat rebuild generation manifest

Generation mode: built-in `imagegen` tool, followed by flat-magenta chroma-key
removal and the native-grid pipeline in
`dev_tools/process_hoe_cat_assets.py`.

Copyright boundary: the generated artwork uses only the generic idea of a
top-down farm cat carrying a hoe. No existing Hoe Cat image or Sprout Lands
sprite was supplied as an edit target or image reference. Weishidaier was used
only to communicate native pixel density, compact 32x32 framing, and restrained
motion.

## Shared character specification

- Original wheat-cream tabby with caramel ear tips and tail bands.
- Muted teal neckerchief, cocoa outline, dark wood hoe, dull iron blade.
- Authentic hard-edged 16-bit/top-down pixel art; 12-16 shared colors.
- Body target: about 16-18 x 18-21 logical pixels in a 32x32 cell.
- Flat `#ff00ff` removable background; no shadows, text, watermark, blur,
  gradients, or antialiasing.
- Must not reproduce a commercial mascot, silhouette, markings, or frame poses.

## Prompt set

1. `anchor_source.png`
   - Three-view identity anchor: front/down, back/up, right/profile.
   - Same proportions, baseline, tool design, and compact logical scale.

2. `movement_source.png`
   - Exactly 4 columns x 3 rows: down, up, right.
   - Contact / passing / opposite contact / opposite passing.
   - Stable torso, one-pixel bob, alternating paws, lagging tail and hoe.
   - Processing mirrors right to left and enforces neutral/A/neutral/B.

3. `attack_source.png`
   - Exactly 5 columns x 3 rows: down, up, right.
   - Planted ready / anticipation / impact / follow-through / recovery.
   - Hips lead, torso follows, hands and hoe lag then overtake.
   - Continuous heavy agricultural chopping arc; no baked VFX.

4. `whirlwind_body_source.png`
   - Exactly 4 columns x 2 rows, read row-major.
   - One planted 360-degree rotation with stable center and baseline.
   - Feet pivot; scarf and tail trail angular motion; no magic ring.

5. `basic_slash_vfx_source.png`
   - Exactly 5 horizontal effects around a centered player pivot.
   - Compressed straw pixels / broken crescent / impact / soil fragments /
     sparse dissipation.
   - Six-to-eight colors; no sword slash, glow, fire, or complete circle.

6. `whirlwind_vfx_source.png`
   - Exactly 4 columns x 2 rows, read row-major, for 48x48 logical cells.
   - Two broken rotating crescents with an open center and square soil chips.
   - Build through frame 4, then fragment and dissipate; never a solid donut.

Every `*_alpha.png` file is the corresponding chroma-key-removed source used
by the processing pipeline.
