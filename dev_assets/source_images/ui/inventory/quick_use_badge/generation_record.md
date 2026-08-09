# Quick-use badge generation record

## ImageGen

- Mode: built-in ImageGen
- Use case: `stylized-concept`
- Generated source: `imagegen_source.png`
- Chroma key: flat `#ff00ff`
- Intended runtime asset: `resources/texture/ui/inventory/quick_use_badge.png`
- Selected concept: public-machine “press to activate” pictogram

Prompt:

> Create one centered public-machine “press to activate” pictogram made from only two geometric parts: a downward press-piece above a short horizontal button bar. Preserve the exact coarse pixel geometry. Color the upper shape pale sky blue and the lower bar a more saturated cyan-sky-blue. Place it on a perfectly flat solid #ff00ff chroma-key background. No enclosing frame, hand, lightning, text, keycap, shadow, glow, gradient, watermark, or extra object.

## Deterministic processing

1. Remove the border-connected chroma background with `dev_tools/connected_background_remover.py`, producing `key_removed.png` with hard alpha.
2. Analyze the source with `dev_tools/pixel_grid_analyzer.py`. The keyed source detected an approximate physical grid at confidence `0.871`.
3. Run `dev_tools/pixel_crop_tool.py` with `--padding 64 --alpha-threshold 127 --align-grid --compress-grid --logical-size 10`, producing `cropped_10_unquantized.png` without unsafe grid compression.
4. Run `python dev_assets/source_images/ui/inventory/quick_use_badge/build_quick_use_badge.py` to snap the two visible shapes to the reviewed sky-blue palette, clear transparent RGB bytes, validate the safety edge, and write the runtime PNG.

The runtime PNG must remain 10×10 RGBA, use only alpha 0/255, have transparent RGB set to zero, and contain exactly two opaque colors.

The final native 10×10 image reports a 1px `native_or_unknown` grid at low confidence (`0.231`), as expected for an already-logical tiny asset. It was therefore reviewed directly at 1× and nearest-neighbor enlargement; no unsafe compression override was used.

Final runtime SHA-256: `563a302f169c8dfd5ec897393a7d94ef4695db24a68e998c5aa1ee19039b1c2d`
