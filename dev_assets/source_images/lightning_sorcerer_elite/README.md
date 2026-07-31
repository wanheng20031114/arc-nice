# 精英雷电术士干净紫色镶边素材记录

本次恢复沿用火焰术士精英化的视觉思路：普通雷电术士的金黄闪电、法杖、
轮廓与动作继续作为主体。紫色不再投影到棕色衣料，而是直接替换角色左侧
领口、袖口和下摆中原本存在的连续黄色服装包边。运行时只保留深紫和中紫
两阶颜色，不再使用淡紫白、高频棋盘纹、散点或逐帧独立摆放的紫色区域。

## 文件

- `lightning_sorcerer_elite_clean_trim_v2_imagegen_reference.png`：Codex 内置
  `imagegen` 生成的 4×4 干净主图设计记录，不再参与运行时构建。
- `lightning_sorcerer_elite_clean_trim_v2_alpha_reference.png`：主图参考去除统一
  绿幕后得到的透明存档。
- `lightning_sorcerer_elite_move_8pose_clean_trim_v2_imagegen_reference.png`：内置
  `imagegen` 生成的 4×2 八相位移动设计记录，不再参与运行时构建。
- `lightning_sorcerer_elite_move_8pose_clean_trim_v2_alpha_reference.png`：移动参考
  去除统一绿幕后得到的透明存档。
- `lightning_sorcerer_elite_purple_texture_overlay.png`：脚本从普通版主图现有
  黄色服装包边确定性派生的紫色替换层。
- `lightning_sorcerer_elite_move_purple_texture_overlay.png`：脚本从修复后的
  普通移动横条现有黄色服装包边确定性派生的八帧替换层。
- `resources/texture/lightning_sorcerer_elite.png`、
  `resources/texture/lightning_sorcerer_elite_move.png`：最终运行时贴图。
- `resources/animation/lightning_sorcerer_elite.tres`：八帧、12 fps 的独立移动
  SpriteFrames；其余动作仍使用 4×4 主图。

旧的 `lightning_sorcerer_elite_purple_texture_imagegen_reference.png` 与
`lightning_sorcerer_elite_move_8pose_imagegen_reference.png` 只作为问题版本的
历史记录，不再参与构建。

## 设计存档的生图提示词

生成模式：Codex 内置 `imagegen`，`precise-object-edit`。主图与移动图分别调用，
没有使用 CLI/API 回退。这些提示词仅记录视觉探索，当前运行时不读取生图结果。

主图提示词：

```text
Use case: precise-object-edit
Asset type: 4x4 elite Lightning Sorcerer animation-sheet design reference
Input images: Image 1 is authoritative Lightning Sorcerer identity, sixteen poses,
exact 4x4 order, silhouette, gold lightning armor, staff, scale, green layout;
edit target. Image 2 only clean elite garment-accent design reference from fire elite.
Primary request: remove dirty mottled purple texture/checker/scattered speckles/
alternating rune noise/broad purple fills. Replace with small clean repeatable
purple accents.
Approved placement: narrow deep-purple hood band beneath gold crown; narrow
collar/shoulder-underlay stripe; compact sleeve cuffs; stable waist sash/belt
inset; narrow lower-robe inner seam/hem. Same body-relative location all 16 poses;
omit if occluded.
Palette: #44146D dominant, #6D27AF one-pixel lit edge, #A944ED very sparse. No
pale lavender/white-purple. 6–10% visible pixels per normal full-body frame.
Preserve exact poses/order/gold/yellow magic/face/staff/anatomy/scale/baseline/
silhouette. Do not recolor metal/lightning/magic/staff/face/boots/gloves/outline.
No geometry change.
Cross-frame purple construction stable; no blinking dots/checker/migrating
highlights/motifs.
Strict hard pixel art, no dither/AA/gradient/blur/noise, flat #00FF00.
```

移动提示词：

```text
Use case: precise-object-edit
Image 1 is the authoritative repaired eight-phase Lightning Sorcerer move and
layout. Image 2 is the new clean main elite visual language. Apply the same small
purple bands and seams. Highest priority: the same body-relative topology and
thickness across all eight frames; omit when occluded. Use #44146D, #6D27AF and
very sparse #A944ED, occupying 6–10% per frame with stable coverage. Preserve the
exact eight gait poses, playback order, gold lightning, staff, face, anatomy,
root and ground line. Do not recolor other parts. Avoid broad panels, checker
patterns, dither, speckles, blinking or migrating highlights, and pale lavender.
Strict hard-edged pixel art on flat #00FF00.
```

两张透明参考通过以下命令去除绿幕：

```powershell
python C:/Users/wanheng/.codex/skills/.system/imagegen/scripts/remove_chroma_key.py `
  <imagegen-reference.png> <alpha-reference.png> --auto-key border --soft-matte `
  --transparent-threshold 12 --opaque-threshold 220 --despill
```

## 确定性构建与防闪烁契约

```powershell
python dev_tools/process_lightning_sorcerer_elite_assets.py
python dev_tools/process_lightning_sorcerer_elite_assets.py --check-only
```

脚本不再按“每帧凑足固定紫色比例”寻找棕色像素，因为那会把颜色补到不同衣料
块上，造成视觉上的随机闪现。现在每个 40×40 帧都只读取普通版在固定角色区域
`x=7..17, y=18..35` 中已经存在的黄色服装包边，并把其中至少连续 3 像素的
八邻域组件替换成深紫或中紫。孤立的一两个黄色高光不会变紫，皇冠、法杖、
闪电、棕色衣料和区域右侧的金色结构也完全不变。

主图变化 762 个原生黄色包边像素，移动横条变化 327 个；数量随真实遮挡自然
变化，不再通过随机补点维持比例。脚本锁定普通版输入、覆盖层和精英输出的
解码后 RGBA SHA-256，并逐像素验证每一个紫色输出的源像素都属于批准的黄色
包边色板。运行时紫色只有 `#44146D` 与 `#6D27AF` 两色。

移动输出继续复用普通雷电术士的八帧中心/地线契约，以及 F2、F5、F6 脚底
相位契约，保留已修复的真实双脚交替。
