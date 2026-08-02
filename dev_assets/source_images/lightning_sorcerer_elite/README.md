# 精英雷电术士紫色色阶重做记录

当前版本严格复用冰霜术士普通/精英之间已经验证过的处理原则：精英图不是
逐帧绘制装饰，也不要求不同姿势共享相同的画布坐标，而是把普通版中一套固定
的源色色阶逐像素映射成一套固定的精英色色阶。这样颜色天然附着在衣袍、冠部、
法杖结晶和法术像素上，随每个原始动作移动，不会出现紫色像素钉在画布上、跨帧
爬动或闪烁的问题。

## 冰霜术士对照结论

`dev_tools/process_frost_sorcerer_elite_assets.py` 只执行六组固定的蓝色到青色
映射。它不使用逐帧遮罩，主动画每帧实际改色数量会随姿势从 68 到 191 变化，
八帧移动会从 85 到 109 变化。这种“源色相同就始终映射到同一目标色”的契约，
才是冰霜精英动画稳定的原因。

此前雷电精英的 v6 方案反而把同一行动作的紫色坐标和数量强制设为完全相同。
角色的衣袍和四肢在运动，但紫色坐标不动，因此视觉上仍然会漂移。该构建路径已
移除。

## 当前权威文件

- `lightning_sorcerer_elite_palette_swap_v7_imagegen_reference.png`：Codex
  内置 `imagegen` 生成的 4×4 多级紫色色阶设计参考。
- `lightning_sorcerer_elite_move_8pose_palette_swap_v7_imagegen_reference.png`：
  Codex 内置 `imagegen` 生成的八帧移动紫色色阶设计参考。
- `resources/texture/enemy/sorcerer/lightning_sorcerer_elite.png`：160×160 运行时主动画；
  只由普通版主图执行固定色表映射得到。
- `resources/texture/enemy/sorcerer/lightning_sorcerer_elite_move.png`：320×40 八帧移动横条；
  只由普通版移动横条执行同一固定色表映射得到。
- `resources/animation/lightning_sorcerer_elite.tres`：独立 SpriteFrames；移动
  8 帧、12 fps，蓄力/攻击/死亡各 4 帧。

目录中 `full_redesign`、`clean_trim`、`edge_trim`、`temporal_topology` 和更早
版本只保留为历史问题记录，不再参与构建。

## 生图模式与提示词

生成模式：Codex 内置 `imagegen`，`precise-object-edit`。两张结果只作为配色
与设计方向参考；其抗锯齿、背景、几何和 RGB 像素都不会进入运行时素材。未使用
CLI/API 回退。

主动画提示词：

```text
Use case: precise-object-edit
Asset type: palette-design reference for a production 4x4 pixel-art animation atlas
Input images: Image 1 is the ordinary Frost Sorcerer; Image 2 is its elite Frost Sorcerer counterpart and defines the exact ordinary-to-elite recoloring principle; Image 3 is the authoritative ordinary Lightning Sorcerer edit target.
Primary request: create the elite Lightning Sorcerer by applying the SAME KIND OF FRAME-INDEPENDENT PALETTE SWAP seen between Images 1 and 2. Replace the coherent gold/yellow costume-and-element highlight ramp of Image 3 with a coherent deep-violet through bright-magenta-violet ramp. This is a palette swap of existing source colors, not painted trim and not coordinates reused across frames.
Style/medium: strict native low-resolution pixel art; hard square pixels; flat indexed-looking color ramps; no antialiasing, blur, gradients, dithering, or soft repainting.
Animation invariants: preserve Image 3's exact 4x4 frame layout, all 16 poses and order, silhouette, anatomy, staff, crown, effects, body scale, frame placement, foot baselines, transparent background, and every pixel coordinate. Each source gold shade must always map to one fixed purple shade everywhere and in every frame so purple naturally follows the moving body and effects.
Color palette: readable multi-level purple ramp with dark violet shadows, mid royal-purple body tones, and restrained bright lavender highlights; preserve the original dark neutral/brown shadow ramp unless a source pixel belongs to the gold/yellow highlight ramp.
Constraints: change colors only; no new pixels, no deleted pixels, no trim overlay, no fixed-position decorations, no per-frame artistic variation, no geometry change, no text, no watermark.
Avoid: sparse purple bands, purple blobs, flicker, crawling pixels, identical purple coordinates across different poses, pose drift, silhouette drift, duplicate frames, purple fill without shading.
```

移动动画提示词：

```text
Use case: precise-object-edit
Asset type: palette-design reference for a production eight-frame pixel-art movement strip
Input images: Image 1 is the ordinary Frost Sorcerer movement strip; Image 2 is its elite Frost Sorcerer movement strip and defines the exact ordinary-to-elite palette-swap principle; Image 3 is the authoritative ordinary Lightning Sorcerer eight-frame movement edit target.
Primary request: create the elite Lightning Sorcerer movement strip by applying the SAME fixed source-color-to-target-color palette swap principle. Replace Image 3's coherent gold/yellow costume-and-element highlight ramp with the exact same coherent multi-level purple identity used for the elite Lightning Sorcerer: dark violet, royal purple, bright violet and restrained pale-lavender highlights. Do not paint trim and do not choose purple locations separately per frame.
Style/medium: strict native low-resolution pixel art; hard square pixels; flat indexed-looking color ramps; no antialiasing, blur, gradients, dithering or soft repainting.
Animation invariants: preserve Image 3's exact eight frames, frame order, gait phases, silhouettes, anatomy, staff, crown, body bob, foot contacts, frame placement, transparent background, and every pixel coordinate. One source gold shade must always map to one fixed purple shade everywhere in all eight frames, so the purple areas move naturally with the authored gait.
Constraints: change colors only; preserve dark neutral/brown shadows unless a color is part of the gold/yellow ramp; no new or deleted pixels; no fixed-position overlay; no per-frame variation; no text or watermark.
Avoid: sparse purple bands, purple blobs, flicker, crawling pixels, identical purple coordinates across different poses, duplicate gait frames, pose drift, silhouette drift, flat two-color purple fill.
```

## 确定性色表映射

普通雷电术士的八级金黄/淡黄色阶固定映射到一个 `275°` 色相的八级紫色色阶。
每一级保持原色的 HSV 饱和度和明度，因此暗紫、皇家紫、亮紫和淡薰衣草高光的
层次完整保留；深棕/黑色阴影不变。

| 普通色 | 精英色 |
| --- | --- |
| `#9A7121` | `#68219A` |
| `#DFB82A` | `#942ADF` |
| `#F8D838` | `#A838F8` |
| `#FBE246` | `#B046FB` |
| `#FDEC50` | `#B550FD` |
| `#F8EFAB` | `#D8ABF8` |
| `#FDF9AD` | `#DCADFD` |
| `#FDFACB` | `#E8CBFD` |

主图每帧改色数量为：

```text
(167, 155, 172, 151, 147, 119, 126, 163,
 187, 117, 143, 165, 138, 145, 186, 75)
```

移动每帧改色数量为：

```text
(178, 150, 154, 175, 165, 144, 146, 169)
```

数量随姿势自然变化，不再追求错误的“每帧相同坐标/相同数量”。两张运行时图的
alpha、轮廓、动作、帧位置以及所有未列入映射的像素均与普通版逐字节一致；可见
色表仍为 23 色。

- 主动画 RGBA SHA-256：
  `4a8bebf01e2e5aa7c4357329809d31d00b07b9cd6942d48ebf906d28f90d8fd3`
- 移动 RGBA SHA-256：
  `b01fecc50a83b526af526688a54f9878a4f96f3bba66c56bbeab1eaabb1f3992`

## 可复现构建

```powershell
python dev_tools/process_lightning_sorcerer_elite_assets.py
python dev_tools/process_lightning_sorcerer_elite_assets.py --check-only
```

构建脚本锁定普通版和输出图的解码后 RGBA/alpha 指纹，逐像素验证固定色表映射，
并继续执行八帧移动的轮廓唯一性、身体中心漂移、半周期差异、地线、单脚接触与
雷电术士步态契约。
