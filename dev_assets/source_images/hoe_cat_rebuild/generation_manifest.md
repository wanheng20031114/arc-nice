# Hoe Cat rebuild generation manifest

Generation mode: built-in `imagegen` tool, followed by background-key removal
(flat magenta for the character boards; auto-keyed green border for the new
pale swing aura and skill icon) and the native-grid pipeline in
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

5. `death_source.png`
   - Exactly 5 horizontal phases: hit/compress, loss of balance, collapse,
     ground contact, and a settled final pose.
   - Uses the rebuilt cat and hoe boards as identity references, then shares
     the runtime character palette, outline treatment, scale, and foot line.
   - No gore; the non-looping animation deliberately retains its final frame.

6. `basic_slash_vfx_flow_v3_source.png`
   - Exactly 4 columns x 2 rows, read row-major as eight continuous phases:
     ignition, short arc, layered growth, impact, follow-through, trailing arc,
     broken fragments, and fading motes. Its motion rhythm takes loose visual
     cues from the Swordsman Cat slash without copying that effect's geometry.
   - Pale-yellow brush ribbon with an ivory cutting edge, warm-gold inner
     contour, naturally tapered ends, and restrained square motes; no soil,
     weapon, character, solid fan, straight cut edge, or full semicircle.
   - Processing registers every frame to one player pivot, scales the forward
     reach to the 48 px gameplay radius, and gently compresses the cross axis.
     It deliberately does not sector-clip the artwork: the bright body stays
     close to the 60-degree hit cone while tapered tips and soft motes may extend
     slightly beyond it. Runtime cells remain 112x112 with transparent safety
     padding. After Lanczos reduction, a smooth 24-to-216 alpha remap restores a
     crisp cutting core while retaining one antialiased edge band for clean
     free-aim rotation. The runtime node adds pale-yellow overbright colour with
     a dedicated HDR 2D shader; the shared game Environment supplies the glow.

7. `whirlwind_vfx_source.png`
   - Exactly 4 columns x 2 rows, read row-major, for 48x48 logical cells.
   - Two broken rotating crescents with an open center and square soil chips.
   - Build through frame 4, then fragment and dissipate; never a solid donut.

8. `whirlwind_icon_v2_source.png`
   - One centered 360-degree pale-yellow whirlwind emblem around a compact
     wooden hoe, with ivory highlights and restrained square sparks.
   - Processed into a transparent, hard-edged 128x128 icon with a fixed
     fourteen-color maximum palette and generous padding.

Every `*_alpha.png` file is the corresponding chroma-key-removed source used
by the processing pipeline.
