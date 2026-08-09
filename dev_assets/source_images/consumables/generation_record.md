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
