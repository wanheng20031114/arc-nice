# 最终 ImageGen 提示词

执行模式：Codex 内置 ImageGen，逐张生成。以下是用户否决华丽页游风后采用的最终提示词。

## `supply_tableau_approved_imagegen.png`

```text
Use case: stylized-concept
Asset type: portrait pixel-art tableau for a roguelite supply-node choice screen
Primary request: a compact abandoned supply cache in a ruined stone mine entrance, rendered with clear medium-sized pixels
Scene/backdrop: a shallow stone arch around a dark cave opening, with a wooden mining cart, two ordinary wooden crates, a rounded tied cloth sack, a loose rope coil, a worn pickaxe, and a handful of small cyan mineral fragments
Subject: readable ruined supply cache, no characters and no implied reward choice
Style/medium: restrained retro pixel art; large readable pixel clusters, simplified shapes, limited color ramps, roughly 120×160 effective logical detail
Composition/framing: tall self-contained diorama, front three-quarter view, centered with generous padding; cart central, smaller supplies around it; readable at 366×478
Lighting/mood: calm dim mine lighting with subtle cyan mineral accents and one small warm wall light; no bloom
Color palette: charcoal and slate stone; muted brown wood; tan cloth; dark steel; cyan; 16–20 production colors
Scene/backdrop for removal: perfectly flat solid #ff00ff chroma-key background
Constraints: original design; uniform #ff00ff outside subject; no shadows or texture on chroma background; do not use #ff00ff in subject; crisp opaque edges; no ornate frame, filigree, treasure spectacle, text, numbers, characters, creatures, reward icons, logo, watermark
Avoid: copying any commercial game asset, legendary browser-RPG ornament, high pixel density, photorealism, painterly blur, dramatic cinematic light, excessive props
```

## `supply_choice_panel_shared_imagegen.png`

```text
Use case: stylized-concept
Asset type: reusable horizontal game UI dialogue/choice panel background
Primary request: create one original cozy farming-life RPG pixel-art choice panel, using the warm readable language of classic 16-bit countryside RPG interfaces without copying any specific commercial frame, motif, or exact palette
Scene/backdrop: perfectly flat solid #ff00ff chroma-key background for local removal; one isolated panel only
Subject: a wide 3.5:1 rectangular dialogue card with gently clipped pixel corners; warm honey-brown wooden outer frame, slim dark cocoa outline, small cream edge highlights, and a calm pale butter/parchment inner field suitable for dark-brown Chinese text
Style/medium: crisp moderate-resolution pixel art, approximately a 130×37 logical-pixel design enlarged with nearest-neighbor; more detailed than 8-bit and less dense than painted UI
Composition/framing: single centered panel, straight-on orthographic view, symmetrical and simple, with generous flat magenta padding; visually quiet center
Color palette: dark cocoa, chestnut, honey wood, pale wheat, warm cream; restrained 8–12 production colors
Constraints: no text, numbers, icons, buttons, gems, leaves, vines, metal, stone, teal, blue, separate compartments, ornamental side objects, external shadow, logo, or watermark; hard pixel edges; do not use #ff00ff in the panel
Avoid: copying proprietary artwork, legendary browser-RPG ornament, industrial frames, material patchwork, painterly blur, soft gradients, photorealism
```

## `flying_envelope_approved_imagegen.png`

```text
Use case: stylized-concept
Asset type: pixel-art game inventory icon source for a SPECIAL collectible named “会飞的信封”
Primary request: one sealed cream paper envelope with two small stylized angular wings, visibly hovering; it must read immediately as a magical flying letter at 32×32
Subject: front three-quarter compact envelope, dark navy-brown outline, simple folded flap, tiny cyan seal, and one short blocky wing on each side built from two or three large feather shapes
Style/medium: clean low-resolution pixel art with intentionally large square pixels and hard clustered edges
Composition/framing: centered square icon, readable silhouette, generous clear padding
Color palette: deep navy-brown outline, parchment cream, muted tan shadow, pale sky blue wing highlights, cyan seal
Scene/backdrop: perfectly flat solid #ff00ff chroma-key background
Constraints: exactly one envelope and its two attached wings; uniform #ff00ff background without shadows, gradients, texture, floor, or glow; do not use #ff00ff in subject; crisp opaque silhouette; no text, postal mark, extra sparkles, cast shadow, UI frame, logo, watermark
Avoid: realistic feathers, soft transparency, motion blur, painterly rendering, photorealism, thin fragile lines, cropped wings
```
