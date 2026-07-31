# 精英雷电术士干净紫色镶边素材记录

本次恢复沿用火焰术士精英化的视觉思路：普通雷电术士的金黄闪电、法杖、
轮廓与动作继续作为主体，只在兜帽带、袖口、腰带和下摆等既有衣料区域加入
少量紫色镶边。旧版大面积八阶紫纹被移除，运行时只保留深紫、中紫和极少亮紫
三阶颜色，不再使用淡紫白、高频棋盘纹、散点和逐帧漂移的符文。

## 文件

- `lightning_sorcerer_elite_clean_trim_v2_imagegen_reference.png`：Codex 内置
  `imagegen` 生成的 4×4 干净主图设计参考。
- `lightning_sorcerer_elite_clean_trim_v2_alpha_reference.png`：主图参考去除统一
  绿幕后得到的透明设计输入。
- `lightning_sorcerer_elite_move_8pose_clean_trim_v2_imagegen_reference.png`：内置
  `imagegen` 生成的 4×2 八相位移动设计参考。
- `lightning_sorcerer_elite_move_8pose_clean_trim_v2_alpha_reference.png`：移动参考
  去除统一绿幕后得到的透明设计输入。
- `lightning_sorcerer_elite_purple_texture_overlay.png`：脚本从主图设计参考投影
  到普通版 160×160 原生衣料像素后生成的受控镶边层。
- `lightning_sorcerer_elite_move_purple_texture_overlay.png`：脚本从八相位参考投影
  到修复后 320×40 普通移动横条的受控镶边层。
- `resources/texture/lightning_sorcerer_elite.png`、
  `resources/texture/lightning_sorcerer_elite_move.png`：最终运行时贴图。
- `resources/animation/lightning_sorcerer_elite.tres`：八帧、12 fps 的独立移动
  SpriteFrames；其余动作仍使用 4×4 主图。

旧的 `lightning_sorcerer_elite_purple_texture_imagegen_reference.png` 与
`lightning_sorcerer_elite_move_8pose_imagegen_reference.png` 只作为问题版本的
历史记录，不再参与构建。

## 最终生图提示词

生成模式：Codex 内置 `imagegen`，`precise-object-edit`。主图与移动图分别调用，
没有使用 CLI/API 回退。

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

脚本只把设计参考中的紫色位置意图投影到普通版既有棕色衣料，最终 alpha、轮廓、
金属、法杖、闪电、步态中心和地线均与普通版逐字节一致。主图变化 521 个原生
像素，移动横条变化 248 个原生像素；每一帧的紫色覆盖率都锁定在可见像素的
8%±0.2%，因此不会因姿势变化出现紫色总量闪烁。深/中/亮三阶色在每帧按固定
60%/35%/5% 预算分配，亮紫只占约 1–2 个像素。脚本同时锁定设计参考、覆盖层、
普通版输入和精英输出的解码后 RGBA SHA-256，并验证覆盖层距离参考紫色区域不
超过 2 个原生像素。

移动输出继续复用普通雷电术士的八帧中心/地线契约，以及 F2、F5、F6 脚底
相位契约，保留已修复的真实双脚交替。
