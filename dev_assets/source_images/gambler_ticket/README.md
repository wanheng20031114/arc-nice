# 赌怪专用券图标来源

- 生成方式：Codex 内置 ImageGen
- 用途：32×32 背包/仓库物品图标的生产源图
- 源图：`gambler_ticket_imagegen_source.png`
- 最终资源：`res://resources/texture/materials/gambler_ticket.png`

## 最终提示词

```text
Use case: stylized-concept
Asset type: production source for a 32x32 pixel-art game inventory item icon
Primary request: create exactly one small admission coupon ticket, visually just a normal paper ticket for a special game
Scene/backdrop: perfectly flat solid #00ff00 chroma-key background for local removal
Subject: one compact rectangular paper coupon with slightly notched/perforated short edges, warm cream paper, dark brown pixel outline, a tiny simple purple-and-gold circular stamp mark with no letters
Style/medium: crisp hand-authored pixel art, hard square pixels, no antialiasing, readable when reduced to a 32x32 transparent game icon, matching a cute top-down pixel game
Composition/framing: single ticket centered, slight diagonal tilt, fully visible, generous uniform padding, no cropping
Color palette: cream, pale gold, warm brown outline, restrained purple accent; do not use green in the ticket
Constraints: exactly one ticket; no text, numbers, letters, characters, logos, watermark, cast shadow, glow, particles, or extra objects; background must be one uniform #00ff00 with no gradient, texture, lighting variation, floor plane, reflection, or shadow; crisp separated silhouette
Avoid: casino imagery, playing cards, dice, poker chips, slot machines, money, weapons, realistic rendering, ornate clutter, thin unreadable details
```

## 处理记录

1. 以边缘自动取样的色键去除纯绿背景，并做柔和去绿边。
2. 使用 `dev_tools/pixel_grid_analyzer.py` 检查主体边界与网格；源图为生成式高分辨率像素风，网格置信度 0.431。
3. 人工核对主体后，使用 `dev_tools/pixel_crop_tool.py` 清除半透明残边、保留 90 物理像素留白，并以最近邻中心取样压缩到 32×32；不做颜色平均或平滑。
