# 攻速强化塔中层 V2 定向重生与正式资产血缘

## 生成记录

- 生成方式：Codex 内置 ImageGen 精确对象编辑。
- 输入图 1：V1 蓝色攻速标志，作为不可改变的造型、朝向、配色和双箭头身份参考。
- 输入图 2：`resources/texture/plant_defense/life_tower/layers/heart_foreground.png`，作为严格的正式中层尺寸参考。
- 原始生成图：`attack_speed_emblem_imagegen_v2_17x17_magenta.png`
- 原始生成图 SHA-256：`904397182fb8681bb622d6202d9932ec3b9f9a47be07ba2c423416bd2fffc2ec`
- 本地抠图：`attack_speed_emblem_imagegen_v2_17x17_transparent.png`
- 抠图 SHA-256：`62582fc5c5601f2a9b4f82b835eebb1f1db000a9834c13b130e83a803885a4c8`
- 抠图方式：ImageGen 技能随附 `remove_chroma_key.py`，边缘自动取键色（实际键色 `#f209e8`）、soft matte、透明阈值 12、不透明阈值 220、despill。

## 精确 V2 提示词

```text
Use case: precise-object-edit
Asset type: production game pixel-art center emblem for the Attack Speed Tower
Input images: Image 1 is the approved blue attack-speed emblem and must remain the visual identity; Image 2 is the existing Life Tower floating center layer as the strict footprint reference.
Primary request: reproduce Image 1's exact concept at a smaller logical-pixel footprint. Keep the same two right-facing blue acceleration chevrons, the same left cyan speed streaks, the same colors, outline style, direction, proportions and pixel-art character. Change only its size/compactness.
Scene/backdrop: perfectly flat solid #ff00ff chroma-key background.
Composition/framing: one isolated centered emblem with generous empty padding. The complete visible emblem, including black outline and all speed streaks, must occupy no more than 17 logical pixels in width and no more than 17 logical pixels in height. Target about 17x14 logical pixels. Every logical pixel is one uniform enlarged square; use one consistent grid and phase.
Constraints: change only size/compactness; do not redesign, rotate, mirror, recolor, add or remove the two-chevron identity. No tower base, heart, text, numbers, particles, shadows, glow outside silhouette, gradients, antialiasing, dithering or watermark. Background must be uniform #ff00ff and must not occur in the emblem.
```

## 确定性正式化

`dev_tools/build_attack_speed_tower_assets.py` 不对整张生成图做普通插值缩放。它在 V2 的 alpha ≥ 128 主体边界内，按需求锁定的 17×14 输出格逐格分区；每格以覆盖率决定透明轮廓，并以固定随机种子的 Lab 聚类从该格实际源色中选择代表色。输出因此只有原生 64×64 单像素格、二值 alpha 和至多 16 个源生颜色。

硬门包括：完整可见中层宽、高分别 ≤17；透明像素 RGB 全零；中层在上下 2 个原生像素的完整浮动周期内始终与正式底座零重叠；正式底座 SHA 和逐像素内容不变。

生成器输出：

- `resources/texture/plant_defense/attack_speed_tower/layers/speed_foreground.png`：64×64 正式中层。
- `resources/texture/plant_defense/attack_speed_tower/attack_speed_tower.png`：正式中层与生命强化塔底座的预合成总图，用于图标、登记和审阅。
- `final/attack_speed_tower_runtime_preview_8x.png`：8 倍整数最近邻预览。
- `final/attack_speed_tower_bob_preview.gif`：与生命强化塔相同的 2 秒、20 FPS、上下 2 原生像素浮动预览。

底座唯一来源为 `resources/texture/plant_defense/life_tower/layers/lower_body.png`（SHA-256 `2815c1ca6400bc4487021aa2be69704bde5ced69b90241a4210a79f89658e77d`）。攻速强化塔目录不生成底座副本，正式场景必须直接引用该文件。
