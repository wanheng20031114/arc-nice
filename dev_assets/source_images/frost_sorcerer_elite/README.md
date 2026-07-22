# 精英冰霜术士素材记录

运行时角色严格派生自当前已验收的
`resources/texture/frost_sorcerer.png`。普通版贴图是唯一的几何、姿势、
中心锚点、逐帧边界和透明轮廓来源；精英版不重画或缩放任何动画帧。

## 文件

- `frost_sorcerer_elite_cyan_trim_imagegen_reference.png`：使用 Codex 内置
  `imagegen` 生成的亮青/淡青设计参考，不直接进入运行时。
- `resources/texture/frost_sorcerer_elite.png`：确定性派生的运行时图集。
- `resources/animation/frost_sorcerer_elite.tres`：独立 SpriteFrames。

## 设计参考提示词

生成模式：Codex 内置 `imagegen`，`precise-object-edit`。

```text
Use case: precise-object-edit
Asset type: 4×4 native pixel-art elite enemy animation sheet design reference
Input images: Image 1 is the authoritative, already-approved Frost Sorcerer sprite sheet and the edit target. It defines the exact identity, sixteen poses, silhouette, frame order, center anchor, foot baseline and pixel density.
Primary request: Create the ELITE FROST SORCERER visual variant by adding restrained bright-cyan and pale-cyan costume accents to the existing character. Change only internal trim and selected ice-magic highlights. Add narrow one-logical-pixel bright-cyan edging and pale-cyan highlight pixels along existing garment construction such as the hat band/edge, collar or shoulder edge, sleeve cuffs, belt/robe opening, lower hem, and staff ornament. Enhance only the already-present ice spell pixels with a brighter cyan to pale icy-cyan value ramp. The result should immediately read as a rarer, colder elite version of the same Frost Sorcerer.
Color palette: deep cyan shadow #087F9A, bright cyan #29E7F2, pale cyan #BDFBFF, used sparingly; retain the original dark navy, blue and icy-white palette everywhere else.
Constraints: preserve all sixteen complete poses exactly: row 1 move, row 2 windup, row 3 attack, row 4 death, left to right. Preserve the exact outer alpha silhouette, dark outline, anatomy, clothing construction, staff geometry, upper/lower-body continuity, frame bounding boxes, apparent size, alignment and animation poses. Do not move, redraw, enlarge, shrink, rotate, mirror, crop, add or remove any character or spell-effect pixels. No new armor, particles or objects. Keep face hidden. Exactly four columns by four rows of equal 40×40 cells. Strict hard-edged low-resolution pixel art with square pixel clusters only; no antialiasing, gradients, blur, glow haze, text, grid lines, labels, border or watermark. Transparent areas and canvas dimensions must remain unchanged.
```

## 确定性构建

```powershell
python dev_tools/process_frost_sorcerer_elite_assets.py
python dev_tools/process_frost_sorcerer_elite_assets.py --check-only
```

脚本仅把普通版现有的六阶蓝色高光映射为更明亮的青色、亮青色和淡青色。
它锁定普通版与精英版的解码后 RGBA SHA-256，并验证以下契约：

1. 160×160 画布与 4×4、每帧 40×40 的布局不变。
2. 二值 alpha、全部 16 帧的包围盒和透明轮廓逐像素不变。
3. 仅批准的 1594 个内部高光像素发生变化。
4. 动作、碰撞、锚点和冰锥素材全部复用普通版的既有结构。
