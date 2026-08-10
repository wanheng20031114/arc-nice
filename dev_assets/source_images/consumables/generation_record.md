# Consumable potion image generation record

Generated on 2026-08-09 with the built-in ImageGen mode. Each distinct item was generated in a separate call. The existing `resources/texture/consumables/healing_potion.png` was used as the primary style reference.

Production processing:

- Chroma-key removal: `remove_chroma_key.py --auto-key border --soft-matte --transparent-threshold 35 --opaque-threshold 110 --despill`
- Pixel-grid analysis: `dev_tools/pixel_grid_analyzer.py`
- Crop and reduction: `dev_tools/pixel_crop_tool.py --padding 40 --alpha-threshold 127 --align-grid --compress-grid --logical-size 32`
- Final contract: 32×32 RGBA, nearest-neighbor reduction, alpha values limited to 0/255.

Source grid analysis reported approximate confidence `0.686` (large healing), `0.912` (rock), and `0.742` (large rock). All three met the project tool's safe threshold (`0.65`) and were manually checked at 1× before acceptance; no unsafe grid-compression override was used. Final native icons were rechecked as 32×32 with hard alpha and one-pixel top/bottom padding.

## Large healing potion

Source: `large_healing_potion_imagegen_green.png`

```text
Use case: stylized-concept
Asset type: 32x32 pixel-art game item icon source
Input images: Image 1 is a style and design reference only, not an edit target.
Primary request: Create a large healing potion that is unmistakably the bigger tier of the reference healing potion.
Scene/backdrop: perfectly flat solid #00ff00 chroma-key background for local background removal.
Subject: one centered squat glass potion bottle, visibly wider and heavier than the reference, matching its cork/neck design, dark near-black outline, cyan-white glass highlights, and vivid red healing liquid. Keep the bottle upright and symmetric enough to read at tiny size.
Style/medium: crisp hand-authored retro pixel art, chunky square pixels, same visual language and detail density as the reference, designed to reduce cleanly to a 32x32 RGBA icon.
Composition/framing: centered single bottle with even padding; the subject should occupy roughly 78% of the square canvas and must not touch the border.
Constraints: one object only; perfectly uniform #00ff00 background with no shadows, gradients, texture, floor, reflections, or lighting variation; crisp silhouette; no semi-transparent glass; do not use #00ff00 in the bottle; no text, label, logo, watermark, cast shadow, or extra props.
Avoid: smooth vector art, photorealism, soft antialiasing, blur, thin fragile details, multiple bottles.
```

## Rock potion

Source: `rock_potion_imagegen_green.png`

```text
Use case: stylized-concept
Asset type: 32x32 pixel-art game item icon source
Input images: Image 1 is the existing small healing potion and the main style/shape reference. Image 2 is the newly designed large healing potion and is a tier-size reference only.
Primary request: Create a small rock potion in exactly the same game-item visual language as Image 1.
Scene/backdrop: perfectly flat solid #00ff00 chroma-key background for local background removal.
Subject: one centered upright narrow glass potion bottle, similar small-tier proportions to Image 1, with a cork/neck design, dark near-black chunky outline, cyan-white glass highlights, and opaque warm gray stone-brown mineral liquid. Include a few simple blocky mineral/pebble shapes inside the liquid so it reads as a rock-defense potion at 32x32, without adding objects outside the bottle.
Style/medium: crisp hand-authored retro pixel art, chunky square pixels, matching the reference outline weight, glass highlight language, and detail density, designed to reduce cleanly to a 32x32 RGBA icon.
Composition/framing: centered single bottle with even padding; subject occupies roughly 72% of the square canvas and must not touch the border.
Constraints: one object only; perfectly uniform #00ff00 background with no shadows, gradients, texture, floor, reflections, or lighting variation; crisp silhouette; no semi-transparent glass; do not use #00ff00 in the bottle; warm gray and stone-brown contents; no text, label, logo, watermark, cast shadow, or extra props.
Avoid: wide large-tier silhouette, smooth vector art, photorealism, soft antialiasing, blur, thin fragile details, multiple bottles.
```

## Large rock potion

Source: `large_rock_potion_imagegen_green.png`

```text
Use case: stylized-concept
Asset type: 32x32 pixel-art game item icon source
Input images: Image 1 is the original small healing potion and defines the game's icon style. Image 2 is the large healing potion and defines the wider, heavier large-tier silhouette. Image 3 is the small rock potion and defines the warm gray stone-brown contents and mineral motif.
Primary request: Create a large rock potion, clearly the stronger and larger tier of Image 3, using the broad, weighty tier language of Image 2.
Scene/backdrop: perfectly flat solid #00ff00 chroma-key background for local background removal.
Subject: one centered squat glass potion bottle, visibly wider and heavier than Image 3, with the same cork/neck family, dark near-black chunky outline, cyan-white glass highlights, and opaque warm gray stone-brown mineral liquid. Use several bold blocky mineral/rock shapes inside the liquid, arranged differently from Image 3, so it reads immediately as a powerful rock-defense potion at 32x32.
Style/medium: crisp hand-authored retro pixel art, chunky square pixels, matching the reference outline weight, highlight language, and detail density, designed to reduce cleanly to a 32x32 RGBA icon.
Composition/framing: centered single bottle with even padding; subject occupies roughly 80% of the square canvas and must not touch the border.
Constraints: one object only; perfectly uniform #00ff00 background with no shadows, gradients, texture, floor, reflections, or lighting variation; crisp silhouette; no semi-transparent glass; do not use #00ff00 in the bottle; warm gray and stone-brown contents; no text, label, logo, watermark, cast shadow, or extra props.
Avoid: narrow small-tier silhouette, copying Image 3 pixel-for-pixel, smooth vector art, photorealism, soft antialiasing, blur, thin fragile details, multiple bottles.
```

## 2026-08-10 twelve-item expansion

The twelve new consumables were generated with twelve distinct built-in
ImageGen calls on flat `#FF00FF` backgrounds. Exact selected-source prompts and
reference-image paths are retained in `imagegen_prompt_manifest.json`; the
manifest SHA-256 is embedded by the deterministic build into
`new_consumable_asset_audit.json` and every per-item `*_asset_audit.json`.

Rebuild and verification commands:

```text
python dev_tools/process_consumable_assets.py
python dev_tools/consumable_asset_pipeline_smoke_test.py
```

The processing script performs border-connected key removal with RGB tolerance
72, hue tolerance 0.035, expansion radius 12, and hard alpha. It then samples
one output pixel per verified logical source cell, preserves the foreground
palette without quantization, permits nearest-neighbour enlargement only, and
centers the result on a 32x32 RGBA canvas with at least one transparent pixel
on every edge. Shrinking and the project pixel tool's unsafe grid-compression
override are never enabled.

Initial twelve-item source/grid summary (the three user-authored native masters
and the two later redraws are superseded by the current records below):

| Item | Initial source | Initial logical subject | Confidence |
| --- | --- | ---: | ---: |
| Blue Crystal Skill Battery | `skill_charge_battery_imagegen_magenta_v2.png` | 10x18 | 0.850 |
| Large Blue Crystal Skill Battery | `large_skill_charge_battery_imagegen_magenta_v2.png` | 20x28 | 0.857 |
| Purple Crystal Magic-Resistance Potion | `magic_resistance_potion_imagegen_magenta_v2.png` | 8x20 | 0.931 |
| Large Purple Crystal Magic-Resistance Potion | `large_magic_resistance_potion_imagegen_magenta_v2.png` | 12x16 | 0.973 |
| Gel Regeneration Tonic | `regeneration_potion_imagegen_magenta.png` | 10x22 | 0.960 |
| Large Gel Regeneration Tonic | `large_regeneration_potion_imagegen_magenta_v2.png` | 15x20 | 0.966 |
| Guardian Mixture | `guardian_mixture_imagegen_magenta.png` | 17x24 | 0.962 |
| Battle-Spirit Potion | `battle_spirit_potion_imagegen_magenta_v2.png` | 11x16 | 0.910 |
| Focus Potion | `focus_potion_imagegen_magenta.png` | 17x24 | 0.949 |
| Windwalk Potion | `windwalk_potion_imagegen_magenta.png` | 15x23 | 0.793 |
| Phantom Potion | `phantom_potion_imagegen_magenta.png` | 18x24 | 0.852 |
| Void Battery | `void_battery_imagegen_magenta.png` | 18x26 | 0.574 (manual review) |

The Void Battery is the only per-source manual grid approval. Automatic
analysis found near-square periods of 30.7x30.2 physical pixels but confidence
0.574 because of a local 14-pixel Y-axis harmonic. Manual review locked its
logical subject to 18x26; the audit records a 1.019 cell aspect ratio and
explicitly confirms that no global unsafe override was enabled.

Rejected-source decisions, SHA-256 values, and measured reasons remain in
`imagegen_prompt_manifest.json`, but rejected rasters that were neither production
inputs nor inputs to an approved ImageGen edit were removed after final approval.
The current rebuild consumes only approved sources and explicit native masters.

## 2026-08-10 native-density redraw and healing repair

The battle-spirit and windwalk icons from the twelve-item expansion were
redrawn after the user identified the enlarged-16x16/macroblock appearance.
The original healing potion is included in the same three-icon review set as a
repair asset; it remains excluded from the twelve-new-item count.

| Asset | Approved source | Reviewed source grid | Logical row edit | Native result |
| --- | --- | ---: | --- | ---: |
| Battle-Spirit Potion | `battle_spirit_potion_imagegen_magenta_v6.png` | 20x31 | remove original row `[2]` | 20x30 |
| Windwalk Potion | `windwalk_potion_imagegen_magenta_v4.png` | 24x32 | remove original rows `[2, 10]` | 24x30 |
| Healing Potion (repair) | `healing_potion_imagegen_magenta_v7.png` | 22x28 | duplicate belly rows after `[18, 20]` | 22x30 |

The reviewed row edits are native row deletions or duplications, not resizes.
Retained logical pixels are never resampled and production upscale is forbidden
for all three. After the row edit the processor changes only the 4-connected outermost silhouette to
uniform near-black RGBA `(5, 8, 12, 255)`. Internal colour blocks are not
modified. Every rebuilt icon must pass these recorded assertions:

- `outer_boundary_dark_ratio == 1.0`
- `second_layer_dark_ratio <= 0.20`
- origin-aligned, RGB-tolerance-8 same-colour 2x2 coverage `<= 0.25`
- alpha values are exactly `0/255`, transparent RGB is zero, and all four
  canvas edges retain at least one transparent pixel

The exact selected prompts, referenced-image paths, candidate decisions, removed
source hashes, and rejection reasons are stored in `imagegen_prompt_manifest.json`.
Only three rejected candidates remain because the approved redraw prompts consume
them as exact image inputs: battle v4, wind v3, and healing v6. In summary: battle v1/v3/v5
were too tall, v2 was the rejected low-density 11x16 source, and v4 was a
technically viable but overly round alternate; wind v1 was the previously
upscaled low-density source while v2/v3 were too tall; healing v1/v3/v5 were
too tall or unreliable and v4 had insufficient native density. The later
round-flask revision uses v7: v6 was too small, while v8 exceeded the target
grid and used anisotropic source cells. The user-supplied 22x30 purple bottle
is retained as `healing_potion_volume_reference.png`; it defines volume and
silhouette only, never the healing potion's colour identity.

### User-authored native masters

Commit `609532c5` manually corrected `magic_resistance_potion.png`,
`regeneration_potion.png`, and `phantom_potion.png`. Their exact production
PNGs are retained beside the generation sources as
`*_native_manual_master.png`. These are authoritative native 32x32 masters:
the full processor verifies pixel equality, hard alpha, transparent RGB, and
four-edge padding, writes an audit, and deliberately skips every production
write. Future ImageGen rebuilds therefore cannot replace the user's manual
work.

Targeted rebuild and audit commands:

```text
python dev_tools/process_consumable_assets.py --asset battle_spirit_potion --asset windwalk_potion --asset healing_potion
python dev_tools/process_consumable_assets.py --asset magic_resistance_potion --asset regeneration_potion --asset phantom_potion
```

The three-redraw contact sheets and aggregate audit are written separately as
`redrawn_consumables_contact_preview_{1x,8x}.png` and
`redrawn_consumable_asset_audit.json`; the existing new-consumables aggregate
continues to contain exactly twelve entries.
