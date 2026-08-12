# 攻速强化塔中层图像生成与资产血缘（ImageGen v1）

## 生成记录

- 生成方式：Codex 内置 ImageGen
- 用例：`stylized-concept`
- 输入图 1：`resources/texture/plant_defense/life_tower/life_tower.png`，作为完整塔的风格、比例和视觉重量参考。
- 输入图 2：`resources/texture/plant_defense/life_tower/layers/heart_foreground.png`，作为中层图像的占位和轮廓尺寸参考。
- 原始生成图：`attack_speed_emblem_imagegen_v1_magenta.png`
- 本地抠图：`attack_speed_emblem_imagegen_v1_transparent.png`
- 生成图 SHA-256：`6d9a551bb977392aa0b60efdc335db477a1d8e2f7d3155918e485526bf532a1a`
- 抠图 SHA-256：`14c817a1fed26e785d88c2de7bb46ebc6ccbe9f4778e310a4c93ca6081135661`

## 精确提示词

```text
Use case: stylized-concept
Asset type: production game pixel-art center emblem for a support tower
Input images: Image 1 is the existing Life Tower complete sprite and style/scale reference; Image 2 is the existing floating heart layer and exact center-emblem footprint reference.
Primary request: generate only a new blue attack-speed acceleration emblem to replace the red heart. The emblem should read immediately as speed: two compact right-facing chevrons with a small bright cyan energy streak, centered as one coherent floating symbol.
Scene/backdrop: perfectly flat solid #ff00ff chroma-key background for local removal.
Style/medium: crisp low-resolution pixel art enlarged with perfectly uniform square pixels; match the black outline thickness, chunky shading, saturation and readability of the supplied tower art.
Composition/framing: one isolated emblem, centered, generous padding; logical visible footprint approximately 16 by 14 pixels, designed to occupy the same center location and visual weight as Image 2.
Color palette: deep navy outline, vivid royal blue, electric cyan highlights, a few near-white cyan specular pixels. Do not use magenta inside the emblem.
Constraints: output only the emblem; no tower base, no heart, no text, no numbers, no particles, no shadow, no floor, no glow outside the pixel silhouette, no gradients, no antialiasing, no dithering, no watermark. Background must be one uniform #ff00ff with no variation.
```

## 选型结果

V1 确立了获批的造型、朝向、蓝色调和双箭头身份，但其逐格重建后的完整可见边界为 19×15，宽度超过正式中层的 17×17 硬门。因此 V1 仅作为 V2 定向重生的身份参考，不进入正式运行资源。正式血缘和处理规格见 `attack_speed_emblem_imagegen_v2_17x17_lineage.md`。
