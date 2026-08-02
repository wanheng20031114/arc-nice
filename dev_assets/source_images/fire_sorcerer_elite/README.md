# 精英火焰术士 imagegen 素材记录

运行时角色严格派生自当前已验收的
`resources/texture/enemy/sorcerer/fire_sorcerer.png`；蓝火球严格派生自
`resources/texture/enemy/sorcerer/fire_sorcerer_fireball.png`。两张原版贴图是唯一的
几何、姿势、中心锚点、逐帧边界和透明轮廓来源，不能用旧版生图素材替换。
八帧 move 同样以 `resources/texture/enemy/sorcerer/fire_sorcerer_move.png` 为唯一运行时几何
来源；独立生图只负责提供金边和蓝色杖火的配色设计。

## 文件

- `fire_sorcerer_elite_gold_trim_imagegen_reference.png`：内置
  `imagegen` 生成的金边与蓝火设计参考，不直接进入运行时。
- `fire_sorcerer_elite_blue_fireball_imagegen_reference.png`：内置
  `imagegen` 生成的蓝火配色参考，不直接进入运行时。
- `fire_sorcerer_elite_gold_trim_overlay.png`：在原生 160×160 像素层级
  逐帧验收的三阶金色透明叠加层。
- `fire_sorcerer_elite_blue_spell_overlay.png`：在原生 160×160 像素层级
  逐帧验收的角色杖端蓝火与攻击蓝焰透明叠加层。
- `fire_sorcerer_elite_move_8pose_imagegen_reference.png`：4×2 八相位 move
  的金边与蓝色杖火设计参考。
- `fire_sorcerer_elite_move_8pose_alpha_reference.png`：上述参考的透明版本。
- `resources/texture/enemy/sorcerer/fire_sorcerer_elite_move.png`：普通版几何与精英设计配色
  合成得到的 320×40、8×1 运行时横条。

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

## 八相位移动设计参考

生成模式：Codex 内置 `imagegen`，`precise-object-edit`。

```text
Use case: precise-object-edit
Asset type: elite game enemy movement sprite design reference
Input images: Image 1 is the authoritative newly generated 4x2 eight-phase Fire Sorcerer movement sheet and the edit target. Image 2 is the authoritative Elite Fire Sorcerer color and trim reference only.
Primary request: Convert Image 1 into the ELITE FIRE SORCERER visual variant while preserving all eight movement poses and the exact 4 columns by 2 rows layout. Change only internal costume trim and the existing staff-tip fire colors.
Color palette: add restrained gold trim using deep ochre, warm gold and pale gold along existing garment construction such as hat band, collar/shoulder edge, robe opening, belt and lower hem. Convert only the already-present orange-yellow staff-tip flame crystal to a compact blue/cyan/white fire ramp. Retain the original charcoal-purple hat, dark iron closed visor, ember-red robe, dark outline, wooden staff and shadow colors everywhere else.
Constraints: preserve all eight complete poses exactly in row-major order; preserve character identity, apparent body size, outer silhouette, anatomy, clothing construction, staff geometry, common ground line, cell placement and pixel density. Keep the face fully concealed with no visible eyes, mouth or skin. Do not move, enlarge, shrink, rotate, mirror, crop, add or remove any character or flame pixels. No new armor, particles, objects, detached fireballs, text, labels, grid lines, border or watermark. Strict hard-edged low-resolution pixel art with square pixel clusters only; no antialiasing, gradients, blur or glow haze. Keep the background perfectly flat uniform #00FF00 with no shadows, texture or lighting variation, and do not use #00FF00 inside the subject.
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
4. 八帧 move 参考先按普通版相同尺度栅格化，再只把重叠区域的精英配色投影
   到普通版 move；最终 alpha、逐帧包围盒、锚点和步态姿势与普通版逐像素相同。
5. 角色和火球的二值 alpha、16 帧包围盒、画布尺寸及动画区域必须与原版
   完全一致。
6. 输入、叠加层和最终输出均由解码后 RGBA SHA-256 锁定。

当前角色共改动 924 个原生像素，其中金边 560 个、角色蓝火 364 个；
最终角色仍为 160×160、每帧 40×40。蓝火球仍为 128×128、每帧
32×32，体积与原版完全一致。
精英 move 仍为 320×40、8×1、12 fps，完整循环 0.667 秒；与普通版的
alpha 和逐帧边界完全一致。
