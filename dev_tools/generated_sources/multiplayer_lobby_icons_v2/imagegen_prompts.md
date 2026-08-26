# 多人联机界面图标 v2 ImageGen 提示词

生成方式：Codex 内置 `image_gen`，2026-08-26。

旧版 32×32 图标只作为语义和风格参考；所有收录源图均由模型重新生成，并在收录前用文件级检查确认是含原生 Alpha 的 RGBA PNG。未通过 Alpha 检查的候选图没有进入项目，也没有通过 RGB 颜色推断透明度。

## 共用提示词

用于标准模式、塔防模式、局域网、创建房间和开始游戏：

```text
Use case: stylized-concept
Asset type: 32x32 pixel-art game UI icon for a multiplayer lobby
Input images: Image 1 is a semantic and style reference only. Generate a completely new icon; do not cut out or retouch the old pixels.
Scene/backdrop: genuinely transparent background from generation; no colored backdrop.
Style/medium: crisp hand-crafted pixel art, bold readable silhouette at 32x32, dark charcoal one-pixel-style outline, restrained teal/cyan, leaf-green, warm gold and ivory palette matching the reference set.
Composition/framing: one centered isolated icon, square composition, 10% to 14% transparent padding, balanced visual weight.
Constraints: actual native alpha transparency; fully transparent outside the icon; clean opaque pixel clusters; no cast shadow; no glow; no text; no frame; no watermark; no extra objects.
Avoid: purple, magenta, violet, pink-purple pixels, chroma-key backgrounds, purple fringes or halos, checkerboard backgrounds, anti-aliased colored residue.
```

各图标主体：

- `mode_standard`：`a silver adventurer’s sword laid diagonally over a small warm parchment map with a subtle green route mark, clearly communicating standard adventure mode.`
- `mode_tower_defense`：`a compact wooden palisade fort with a central teal shield or gate and a few green leaves or crops, clearly communicating tower defense.`
- `network_lan`：`two compact teal computer monitors connected by one short antique-gold network cable, clearly communicating a local-area network.`
- `action_create_room`：`one antique-gold key paired with a small bright green plus symbol, clearly communicating create room.`
- `action_start_game`：`one teal rally flag on an antique-gold pole paired with a small gold right-pointing play arrow, clearly communicating start game.`

## 公网图标

```text
Use case: stylized-concept
Asset type: 32x32 pixel-art game UI icon for a multiplayer lobby
Input images: Image 1 is a semantic and style reference only. Generate a completely new icon; do not cut out or retouch the old pixels.
Primary request: a compact blue-green globe held between two small antique-gold network brackets, clearly communicating public internet matchmaking.
Scene/backdrop: no scene and no backdrop.
Style/medium: crisp hand-crafted pixel art, bold readable silhouette at 32x32, dark charcoal one-pixel-style outline, restrained teal/cyan, leaf-green, warm gold and ivory palette matching the reference set.
Composition/framing: exactly one centered isolated icon, square composition, 12% transparent padding, balanced visual weight.
Transparency is mandatory: return an RGBA PNG with genuine native alpha. Every pixel outside the icon must have alpha 0. Do not draw or bake any white, gray, black, checkerboard, grid, or colored background into RGB pixels.
Constraints: clean opaque pixel clusters; no cast shadow; no glow; no text; no frame; no watermark; no extra objects.
Avoid: purple, magenta, violet, pink-purple pixels, chroma-key backgrounds, purple fringes or halos, checkerboard patterns, anti-aliased colored residue.
```

## 测试模式 P1

```text
Create a brand-new isolated transparent-background pixel-art game UI icon.
Subject: one round cyan alchemy potion flask crossed with one small green-handled silver axe. Exactly these two objects, compact and unmistakable at 32x32.
Style: crisp hand-crafted pixel art, bold dark-charcoal pixel outline, large simple shapes, cyan/teal liquid, leaf-green handle, silver blade, tiny warm-gold accents.
Composition: centered square icon with 14% empty transparent padding.
Output: genuine RGBA PNG with native alpha; all space outside the silhouette is alpha 0.
No background, no checkerboard pattern, no platform, no badge, no letters or numbers, no text, no frame, no shadow, no glow, no extra objects, no purple, magenta, violet, pink-purple pixels, fringes, halos, or watermark.
```

## 测试模式 P2

```text
Create a brand-new isolated transparent-background pixel-art game UI icon.
Subject: one round cyan alchemy potion flask beside one compact orange-gold gear with a small green crystal component. Exactly these three elements, compact and unmistakable at 32x32.
Style: crisp hand-crafted pixel art, bold dark-charcoal pixel outline, large simple shapes, cyan/teal liquid, warm orange-gold gear, leaf-green crystal.
Composition: centered square icon with 14% empty transparent padding.
Output: genuine RGBA PNG with native alpha; all space outside the silhouette is alpha 0.
No background, no checkerboard pattern, no platform, no badge, no letters or numbers, no text, no frame, no shadow, no glow, no extra objects, no purple, magenta, violet, pink-purple pixels, fringes, halos, or watermark.
```
