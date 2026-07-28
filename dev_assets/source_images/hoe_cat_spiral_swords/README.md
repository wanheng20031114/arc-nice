# 锄头猫猫「雪狼破军」环绕利剑素材

## 交付文件

- 生图源图：`snow_wolf_pojun_sword_imagegen_source.png`
- 游戏内透明像素图：`resources/texture/player/hoe_cat/snow_wolf_pojun_sword.png`

游戏内素材为 24×24 RGBA 画布，剑身实际占用约 22×8 个原生像素；
保持 `scale = Vector2.ONE` 与最近邻采样，不做有损或非整数缩放。

## 生成方式

使用内置 imagegen 工具生成纯绿色抠图底源图，完整提示词如下：

```text
Use case: stylized-concept
Asset type: production source for a tiny 2D game pixel-art orbiting sword sprite
Input images: Image 1 is the Hoe Cat character pixel-art style reference; Image 2 is the Hoe Cat pale-yellow whirlwind VFX palette and energy reference; Image 3 is the existing compact game pickup atlas scale reference.
Primary request: create exactly one small straight fantasy sword for the Hoe Cat's Snow Wolf Po Jun pickup effect. The sword points perfectly horizontally to the right, with the hilt on the left and sharp tip on the right, so it can rotate radially around a character.
Subject: compact double-edged straight blade, short crossguard, tiny pommel; readable at a final logical footprint around 18x9 pixels; non-violent, magical tool-like design.
Style/medium: crisp hand-authored pixel art, hard square pixels, no antialiasing, no subpixel texture, matching the references' cute game sprite language.
Composition/framing: one sword only, centered, horizontal, generous empty padding, no cropping.
Color palette: dark amber-brown outline, golden yellow midtone, pale butter-yellow blade, a few warm ivory highlights; no blue, red, gray, green, or pure black.
Scene/backdrop: perfectly flat solid #00ff00 chroma-key background for local removal.
Constraints: the background must be one uniform #00ff00 with no shadows, gradients, texture, reflections, floor plane, or lighting variation; do not use #00ff00 anywhere in the sword; crisp silhouette; no cast shadow; no glow outside the silhouette; no text; no watermark; no second sword; no extra particles or objects.
Avoid: realistic rendering, painterly edges, diagonal pose, curved saber, oversized ornate weapon, blood, damage, gore, metallic gray blade, soft transparency.
```

本地处理流程：

1. 使用 imagegen 技能的 `remove_chroma_key.py` 去除纯绿背景。
2. 使用 `dev_tools/pixel_grid_analyzer.py` 确认源图逻辑网格置信度为 0.920。
3. 使用 `dev_tools/pixel_crop_tool.py` 按检测网格中心取样，压缩到 24×24：

```powershell
python dev_tools/pixel_crop_tool.py `
  dev_assets/source_images/hoe_cat_spiral_swords/snow_wolf_pojun_sword_transparent.png `
  resources/texture/player/hoe_cat/snow_wolf_pojun_sword.png `
  --padding 34 --alpha-threshold 128 --align-grid --compress-grid --logical-size 24
```

4. 不改变像素位置或 Alpha，以无抖动最近色映射收敛到固定 8 色调色板：
   `#371808`、`#6F4A12`、`#A96819`、`#D89728`、`#F0C84A`、
   `#FFE477`、`#FFF1A6`、`#FFF8D7`。

`snow_wolf_pojun_sword_transparent.png` 只用于本地流水线中转，不作为交付文件保留。

## 视觉与碰撞契约

- 四把剑复用同一纹理并彼此相差 90°，剑尖沿公转切线朝向。
- 剑中心轨道半径为 72 像素，略大于旋风斩约 67.31 像素的最大可见半径。
- 单把剑使用 22×6 的矩形碰撞体，和可见剑身保持一致。
- 公转速度为每秒 720°，0.5 秒完成一圈。
