# P3 地下遗址主题 ImageGen 提示词

生成方式：Codex 内置 `image_gen`。

## 地下遗址背景

```text
Use case: stylized-concept
Asset type: finished 2D game route-map background texture
Primary request: create a dark underground-ruins exploration background for a route-map scene, replacing a starfield
Scene/backdrop: an ancient subterranean ruin floor viewed straight down from a high orthographic top-down camera; broad worn stone slabs, partially buried foundations, a few broken pillars and collapsed masonry arranged mostly around the outer perimeter; subtle cracks, dust, and sparse traces of old mechanisms
Style/medium: restrained stylized game environment painting with clean, simplified large shapes; slightly Minecraft-like block construction in the masonry, but not literal pixel art; practical readable game backdrop, not splash art
Composition/framing: 16:9 landscape; seamless-feeling wide map backdrop; central 60% must remain dark, calm, low-detail, and low-contrast so bright route nodes, lines, labels, and a small player sprite remain readable; environmental silhouettes and larger ruin fragments primarily near the edges and corners; no single focal object
Lighting/mood: dim underground ambient light, very faint cool cyan mineral or dormant-rune glow only at a few perimeter cracks, heavy soft vignette, quiet archaeological exploration mood
Color palette: very limited palette of near-black, charcoal, slate gray, desaturated blue-green, with tiny muted oxidized-bronze accents; average scene brightness very low
Materials/textures: broad matte stone, dust, chipped block edges; texture visible but never noisy
Constraints: fully opaque background; no transparency; no text; no symbols that look like UI; no characters; no enemies; no route nodes; no connecting lines; no HUD; no map labels; no watermark; preserve generous visual quiet throughout the center
Avoid: starry sky, outer space, bright magic, ornate fantasy palace, glossy metal, high saturation, dense rubble everywhere, photorealism, dramatic cinematic focal lighting, collectible-card art, Chinese browser-game aesthetic, excessive micro-detail
```

## 遗址物资节点图标

```text
Use case: stylized-concept
Asset type: source artwork for one simple route-map UI icon
Primary request: a compact icon representing supplies recovered from underground ruins
Scene/backdrop: native transparent background
Subject: one small cracked ancient stone supply coffer or blocky reliquary, front three-quarter view, with a single simple cool-cyan relic shard visible inside and one tiny muted bronze clasp
Style/medium: clean flat game UI icon, bold simplified silhouette, restrained Minecraft-like block construction, thick dark outline, broad color areas, readable when reduced to 22 pixels; match a minimal six-color icon family
Composition/framing: one centered object, square canvas, generous empty padding on every side
Color palette: charcoal outline, two slate-gray stone shades, muted bronze, one cyan accent, one pale highlight
Constraints: transparent alpha outside the subject; crisp isolated edges; no baked background, cast shadow, contact shadow, text, runes or letters, extra objects, border frame, or watermark
Avoid: realistic treasure chest, gold piles, ornate fantasy decoration, glossy rendering, many tiny details, browser-game loot icon aesthetic, soft blurry silhouette
```
