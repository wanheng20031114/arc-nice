# 精英雷电术士紫纹素材记录

精英雷电术士保留普通版的金黄闪电识别，只在既有服装内部加入深紫、亮紫和
少量淡紫色织纹。两张运行时贴图严格从普通雷电术士逐像素派生，因此主图的
16 个动作、独立移动横条的 8 个步态、轮廓、中心点、地线和后脚交替全部不变。

## 文件

- `lightning_sorcerer_elite_purple_texture_imagegen_reference.png`：使用 Codex
  内置 `imagegen` 生成的 4×4 主图紫纹设计参考，不直接进入运行时。
- `lightning_sorcerer_elite_move_8pose_imagegen_reference.png`：使用内置
  `imagegen` 生成的八相位步态紫纹设计参考，不直接进入运行时。
- `lightning_sorcerer_elite_purple_texture_overlay.png`：按主图设计参考在
  原生 160×160 像素层级验收的紫纹透明叠加层。
- `lightning_sorcerer_elite_move_purple_texture_overlay.png`：按移动设计参考
  在原生 320×40 像素层级验收的八帧紫纹透明叠加层。
- `resources/texture/lightning_sorcerer_elite.png`：从普通版 160×160 主图
  确定性派生的精英运行时贴图。
- `resources/texture/lightning_sorcerer_elite_move.png`：从任务 1 修复后的
  320×40 普通移动横条确定性派生的精英八帧贴图。
- `resources/animation/lightning_sorcerer_elite.tres`：独立 SpriteFrames。

## 最终生图提示词

生成模式：Codex 内置 `imagegen`，`precise-object-edit`。主图与移动图分别调用，
运行时素材没有使用 CLI/API 回退。

主图核心提示词：

```text
Create the ELITE LIGHTNING SORCERER visual variant while preserving all sixteen
poses, silhouette, staff, gold lightning identity, scale and 4x4 order. Add
restrained purple textile accents inside existing garment areas only: deep
royal purple #44146D, mid purple #6D27AF, bright violet #A944ED and sparse pale
lavender #F7E9FC. Use hat-band stitching, sleeve cuffs, waist sash, lower robe
insets and tiny angular lightning-rune/chevron motifs. Purple occupies roughly
15-25% of costume pixels and never replaces gold metal or spell pixels. Keep
strict hard-edged pixel art on uniform #00FF00; no silhouette or pose changes.
```

移动核心提示词：

```text
Preserve the authoritative repaired eight-frame Lightning Sorcerer walk cycle,
including exact phase order, rear-leg alternation, contacts, root and ground
line. Keep gold lightning dominant and add the same restrained purple woven
accents inside existing cloth only. Do not collapse, duplicate, reorder,
mirror or redraw any gait pose. Exactly eight separated frames in one row on
uniform #00FF00; strict hard-edged pixel art, no effects, text or grid.
```

## 确定性构建

```powershell
python dev_tools/process_lightning_sorcerer_elite_assets.py
python dev_tools/process_lightning_sorcerer_elite_assets.py --check-only
```

脚本只在两张透明叠加层指定的位置，把普通版既有的深棕布料换成八阶紫纹；叠加
层以外的 RGBA 逐字节保持普通版不变，金黄金属、法杖水晶和闪电像素保持原色。
主图有 1216 个原生像素变化，移动横条有 729 个原生像素变化，分别占可见像素
约 18.7% 与 23.4%。构建锁定普通版输入、叠加层与精英输出的解码后 RGBA
SHA-256，并验证叠加层只覆盖普通版可见棕色像素、逐帧数量固定、二值 alpha
完全一致。移动输出还复用普通雷电的中心/地线契约及 F2、F5、F6 脚底相位
契约，确保精英版继承任务 1 修好的真实双脚交替。
