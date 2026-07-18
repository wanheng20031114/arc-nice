# 精英火焰术士 imagegen 素材记录

运行时角色严格派生自当前已验收的
`resources/texture/fire_sorcerer.png`；蓝火球严格派生自
`resources/texture/fire_sorcerer_fireball.png`。两张原版贴图是唯一的
几何、姿势、中心锚点、逐帧边界和透明轮廓来源，不能用旧版生图素材替换。

## 文件

- `fire_sorcerer_elite_gold_trim_imagegen_reference.png`：内置
  `imagegen` 生成的金边与蓝火设计参考，不直接进入运行时。
- `fire_sorcerer_elite_blue_fireball_imagegen_reference.png`：内置
  `imagegen` 生成的蓝火配色参考，不直接进入运行时。
- `fire_sorcerer_elite_gold_trim_overlay.png`：在原生 160×160 像素层级
  逐帧验收的三阶金色透明叠加层。
- `fire_sorcerer_elite_blue_spell_overlay.png`：在原生 160×160 像素层级
  逐帧验收的角色杖端蓝火与攻击蓝焰透明叠加层。

## 角色设计参考

生成模式：Codex 内置 `imagegen`，`precise-object-edit`。

```text
Use case: precise-object-edit
Asset type: 4×4 native pixel-art enemy animation sheet design reference
Input image: Image 1 is the authoritative, already-approved Fire Sorcerer sprite sheet. It is the exact identity, pose, silhouette, frame order, animation timing, center anchor and pixel-density reference.
Primary request: Create the ELITE FIRE SORCERER visual variant by changing only internal costume trim and spell-fire colors. Preserve all sixteen full character poses exactly: row 1 move, row 2 windup, row 3 attack, row 4 death, left to right.
Costume edit: add restrained one-logical-pixel antique-gold edging that follows the existing clothing construction—hat band edge, collar/shoulder edge, sleeve cuff, belt, robe front opening and lower hem. The gold must read as narrow sewn or armored trim, never as large flat gold panels. Use dark gold, warm gold and pale-gold highlights. Keep the dark purple hat, gray eyeless helmet, red/orange robe, purple accents, boots and wooden staff otherwise unchanged.
Spell edit: change only visible magical flame attached to the staff or attack arc from orange fire to saturated blue/cyan flame with a pale icy-white core. Do not change ordinary cloth colors into blue.
Critical invariants: preserve the exact outer alpha silhouette, black outline, anatomy, upper/lower-body continuity, foot baseline, body center, staff angle, frame bounding boxes and all animation poses from Image 1. No mirroring, no body-part splice, no added armor, no new gems, no extra particles beyond existing pixels, no change in apparent size. Keep the face completely hidden and eyeless.
Style: strict chunky low-resolution pixel art, hard square pixels only, no antialiasing, gradients, blur or smooth curves. One consistent logical-pixel outline.
Layout: exactly four columns by four rows of equal square cells, same framing and spacing as Image 1, nothing crossing cell boundaries.
Backdrop: perfectly flat uniform #00ff00 chroma-key green, no shadow, floor, grid lines, labels, text, border or watermark. Do not use #00ff00 inside the sprites.
```

## 蓝火球设计参考

生成模式：Codex 内置 `imagegen`，`precise-object-edit`。

```text
Use case: precise-object-edit
Asset type: 4×4 native pixel-art blue-fire projectile animation sheet design reference
Input image: Image 1 is the authoritative Fire Sorcerer fireball sheet. Preserve its exact 4×4 frame layout, all sixteen frame silhouettes, frame bounding boxes, centers, animation progression, empty final frame, apparent size and pixel density.
Primary request: Recolor only the fire itself into elite BLUE FIRE. Convert the dark red outer flame into deep navy/cobalt, the orange body into saturated royal blue, the yellow highlights into bright cyan, and the hottest near-white core into pale icy blue-white. The result must clearly read as magical blue flame, not water or electricity.
Critical invariants: do not redraw, enlarge, shrink, rotate, move, crop, add or remove any projectile/effect pixel. Preserve the exact fly, spawn, impact and expire silhouettes and their intensity hierarchy. No new glow haze, smoke, shockwave or particles.
Style: strict hard-edged low-resolution pixel art, square pixel clusters only, no antialiasing, gradients, blur or smooth curves.
Layout: exactly four columns by four rows of equal square cells, same spacing and framing as Image 1, nothing crossing cell boundaries.
Backdrop: perfectly flat uniform #00ff00 chroma-key green, no shadow, floor, grid lines, labels, text, border or watermark. Do not use #00ff00 inside the fire.
```

## 确定性运行时构建

```powershell
python dev_tools/process_fire_sorcerer_elite_assets.py
```

脚本执行以下受约束操作：

1. 角色仅在两张透明叠加层指定的位置替换像素；叠加层以外的 RGBA
   逐字节保持原版不变。
2. 金边只允许深金、暖金和淡金三阶固定色表，不覆盖外轮廓。
3. 蓝火球逐像素把暖色 HSV 色相映射到蓝/青色域，同时保持 alpha 与
   HSV value 不变。
4. 角色和火球的二值 alpha、16 帧包围盒、画布尺寸及动画区域必须与原版
   完全一致。
5. 输入、叠加层和最终输出均由解码后 RGBA SHA-256 锁定。

当前角色共改动 924 个原生像素，其中金边 560 个、角色蓝火 364 个；
最终角色仍为 160×160、每帧 40×40。蓝火球仍为 128×128、每帧
32×32，体积与原版完全一致。
