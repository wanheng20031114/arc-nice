# 精英冰霜术士素材记录

运行时角色严格派生自当前已验收的普通寒冰术士。四帧的蓄力、攻击和消散动作
派生自 `resources/texture/enemy/sorcerer/frost_sorcerer.png`，八帧移动动画派生自独立的
`resources/texture/enemy/sorcerer/frost_sorcerer_move.png`。普通版运行时贴图是唯一的几何、
姿势、中心锚点、逐帧边界和透明轮廓来源；精英版不重画或缩放任何运行时动画帧。

## 文件

- `frost_sorcerer_elite_cyan_trim_imagegen_reference.png`：使用 Codex 内置
  `imagegen` 生成的主图亮青/淡青设计参考，不直接进入运行时。
- `frost_sorcerer_elite_move_8pose_imagegen_reference.png`：4×2、八相位移动
  的精英配色设计参考。
- `frost_sorcerer_elite_move_8pose_alpha_reference.png`：上述移动设计参考的
  透明版本；同样不直接进入运行时。
- `resources/texture/enemy/sorcerer/frost_sorcerer_elite.png`：主图动作的确定性换色输出。
- `resources/texture/enemy/sorcerer/frost_sorcerer_elite_move.png`：从普通版八帧移动横条
  确定性换色得到的 320×40、8×1 运行时贴图。
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

上面的 4×4 参考继续约束主图配色。八帧移动的 4×2 imagegen 稿也只用于说明
精英亮青、淡青内饰和冰魔法高光应该如何落色；它不是最终轮廓或姿态基准，也不
要求与普通版 v3 的透明轮廓逐像素相同。运行时
`resources/texture/enemy/sorcerer/frost_sorcerer_elite_move.png` 的全部几何、八个步行相位、
姿态中心、脚底线和 alpha 都以普通版 v3 构建出的
`resources/texture/enemy/sorcerer/frost_sorcerer_move.png` 为唯一来源，再进行确定性换色。

## 确定性构建

```powershell
python dev_tools/process_frost_sorcerer_elite_assets.py
python dev_tools/process_frost_sorcerer_elite_assets.py --check-only
```

脚本仅把普通版现有的蓝色高光映射为更明亮的青色、亮青色和淡青色。主图和
独立移动横条都从普通版运行时资产确定性派生；两张 imagegen 移动参考只用于
确认配色意图。构建验证以下契约：

1. 主图继续使用 160×160 画布、4×4 布局与 40×40 原生帧；其中非移动动作
   仍各为四帧。
2. 移动输出为 320×40 的 8×1 横条，八帧按 4×2 源图的行优先顺序排列。
3. 八帧姿态中心统一为 `(17, 27)`、地线统一为 `y = 38`，横向可见像素质心
   峰峰值不超过 1 像素。
4. 移动动画以 12 fps 播放，八帧完整周期为 `8 / 12 = 0.667` 秒，与旧四帧
   6 fps 周期一致。
5. 普通版与精英版的二值 alpha、逐帧包围盒和透明轮廓逐像素相同；变化只允许
   发生在批准的内部高光颜色上。主图既有的 1594 像素换色契约保持不变。
6. 动作、碰撞、锚点和冰锥素材全部复用普通版的既有结构。

三种术士共用的中心点/地线审计图为
`dev_assets/generated_previews/sorcerer_move_center_audit.png`。
