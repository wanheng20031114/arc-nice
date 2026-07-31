# 火焰术士 imagegen 素材记录

生成模式：Codex 内置 `imagegen`。

最终生产管线使用以下源图：

- `fire_sorcerer_generated_v2.png`
- `fire_sorcerer_attack_1_generated_v1.png`
- `fire_sorcerer_move_8pose_imagegen_source.png`
- `fire_sorcerer_move_8pose_alpha.png`
- `fire_sorcerer_fireball_generated_v1.png`

`fire_sorcerer_generated_v1.png` 是首次生成但被像素网格硬门槛拒绝的留档，
没有进入任何运行时素材。最终源图由
`dev_tools/process_fire_sorcerer_assets.py` 做绿幕移除、逐帧逻辑网格分析和
整数像素采样。

2026-08-01 起，运行时 move 不再读取主图第一行的旧四帧。新 move 使用独立
`resources/texture/fire_sorcerer_move.png`，规格为 320×40、8×1 帧、12 fps；
八帧完整周期仍为 `8 / 12 = 0.667` 秒，与旧四帧 6 fps 的周期一致。
`fire_sorcerer_move_generated_v1.png`、两张 opposite 重绘和
`fire_sorcerer_move_native_v1.png` 仅保留为历史原稿及主图第一行兼容来源。

旧移动条带的生图源是三张 1983×793 横条，近似网格置信度不足以进入通用压缩
入口，因此由 `dev_tools/process_fire_sorcerer_move_asset.py` 锁定每张原图的
SHA-256、验收格边界和目标原生尺寸，并使用最近邻采样。第 0/1 帧取自主横条
中的完整“接触/通过”人物，第 2 帧取自反相接触重绘的完整人物，第 3 帧取自
反相通过重绘的完整人物。严禁对腰部以下做局部镜像或在人物内部拼接。

脚本验证二值 alpha、单一四邻接连通块、相邻腰线的中心/重叠连续性、`y=38`
基线、质心漂移、落地段数量、接触/通过姿势的落地宽度和 RGBA 指纹。安装时
只无掩码覆盖角色表第一行，其余三行由解码后 RGBA 哈希保护。

## 当前八相位移动（最终运行时来源）

```text
Use case: stylized-concept
Asset type: production pixel-art game enemy movement sprite source sheet
Input images: Image 1 is the authoritative Fire Sorcerer identity, scale, palette, right-facing silhouette, hat, closed helmet, robe, boots and staff reference. Image 2 is only the authoritative eight-phase locomotion timing and 4x2 layout reference; do not copy its Frost Sorcerer clothing, crown, colors or staff.
Primary request: Create one exact 4 columns by 2 rows sheet containing a coherent eight-phase right-facing walk cycle for the SAME Fire Sorcerer from Image 1.
Animation order, row-major: frame 0 right-foot contact, frame 1 right-foot down/compression, frame 2 right-foot passing, frame 3 right-foot up; frame 4 left-foot contact, frame 5 left-foot down/compression, frame 6 left-foot passing, frame 7 left-foot up.
Subject: compact faceless Fire Sorcerer with fully closed dark iron helmet/visor, absolutely no visible eyes, mouth or skin; crooked broad-brim charcoal-purple wizard hat with scorched-orange band; ember-red robe with orange trim; armored gloves and heavy boots; short wooden fire staff tipped with a small compact orange-yellow flame crystal.
Style/medium: strict low-resolution pixel art, coarse deliberate square pixel clusters, hard edges, globally consistent logical pixel density, at most 18 opaque subject colors, one-logical-pixel near-black outline.
Composition/framing: exact 4x2 layout with eight equal roomy cells, one stable body root and common ground line. Keep unchanged apparent body scale and proportions across all eight frames. Every pose must be a genuine locomotion phase, never a translated or duplicated idle pose. Staff remains carried diagonally forward; robe hem and hat tip move subtly. Keep subjects clearly separated and centered inside their cells.
Scene/backdrop: perfectly flat solid #00FF00 chroma-key background.
Constraints: preserve Image 1 character identity; use Image 2 only for gait semantics and phase ordering. Background must be one uniform #00FF00 with no shadows, gradients, texture, reflections, floor plane or lighting variation. Do not use #00FF00 in the character. No cast shadow, contact shadow, antialiasing, blur, gradients, glow haze, labels, text, grid lines, borders, watermark, detached fireballs, extra characters or objects. Nothing may cross a cell boundary.
```

生成稿通过 imagegen 技能的 `remove_chroma_key.py` 去背，再由
`dev_tools/process_fire_sorcerer_assets.py` 按行优先拆成八帧。每帧保持原始
宽高比，以 `(17, 27)` 为身体锚点、`y=38` 为共同地线；目标高度依次为
`29, 28, 29, 30, 30, 28, 29, 30`。输出强制二值 alpha、透明 RGB 清零、
角色既有调色板与不超过 1 像素的横向质心漂移。

## 角色初稿（已拒绝）

```text
Create a production-ready 2D pixel-art sprite sheet for a brand-new game enemy named “Fire Sorcerer”. Output one perfectly square image divided into an invisible, exact 4 columns × 4 rows grid of equal-size cells. The background must be one single perfectly flat chroma green color #00FF00 everywhere, with no grid lines, no shadows on the background, no labels, no text, no borders, and nothing crossing cell boundaries.

TRUE LOW-RES PIXEL ART REQUIREMENT: render with crisp square pixel clusters only, no anti-aliasing, no blur, no semi-transparent edge pixels, no painterly texture, no high-resolution illustration detail. The intended logical canvas of EACH frame is exactly 40×40 pixels, and the complete character silhouette in every frame must fit inside at most 34 logical pixels wide × 38 logical pixels tall with safe empty green padding. Use a restrained game palette and consistent 1-logical-pixel dark outline. Every frame must keep identical character proportions, palette, light direction, staff length, and grounding.

Character design: a compact medium-small humanoid magical construct, not cute-animal and not graphic or brutal. Its face is completely concealed by a dark iron closed helmet/visor under a crooked broad-brim spellcaster hat; absolutely no visible eyes, mouth, skin, or face. The hat is deep charcoal-purple with a scorched orange band. It wears a dark ember-red robe with simple angular folds, heavy boots, short armored gloves, and holds a wooden fire staff tipped by a small orange-yellow flame crystal. Readable Minecraft-inspired blocky proportions, but original 2D sprite design. Silhouette must clearly communicate helmet + wizard hat + robe + fire staff at tiny scale.

Animation layout, left to right:
Row 1 — WALK, 4 coherent loop frames: planted step, passing pose, opposite planted step, passing pose. Staff carried diagonally; robe hem and hat tip move subtly.
Row 2 — WIND-UP, 4 progressive frames: stop and brace, pull staff back, raise staff with growing ember at tip, fully charged anticipation. No detached projectile.
Row 3 — ATTACK, 4 progressive frames: begin staff swing, strong forward swing, release pose with a short attached flame arc at staff tip, recoil/settle. No detached fireballs inside this character sheet.
Row 4 — DEATH/DISPEL, 4 non-graphic frames: stagger, kneel, armor/robe collapse into ember fragments, small extinguished heap. No blood, no gore.

Side/three-quarter view facing right, suitable for horizontal flip in engine. Feet share a consistent baseline in rows 1–3. Do not add extra characters, creatures, icons, UI, captions, letters, numbers, diagrams, glow haze, cast shadows, checkerboard, or scenery. Maintain exact animation continuity and clear frame separation using only green empty space.
```

## 角色像素网格重制（最终主体源图）

```text
Edit the supplied Fire Sorcerer sprite sheet while preserving the same character identity, the exact 4×4 animation order, and the overall poses, but REBUILD the entire sheet as strict low-resolution production pixel art.

Critical correction: the supplied sheet currently looks like high-resolution pixel-styled art. Replace every contour, fill, highlight, and shadow with a regular, globally aligned square pixel grid. Use ONLY hard-edged, solid-color square clusters; no anti-aliasing, no subpixel edges, no gradients, no blur, no texture noise, no thin high-resolution lines. Every logical pixel must be represented by one exact 8×8 physical-pixel square, aligned to the same global 8-pixel grid across the entire image. Use at most 18 opaque character colors total, including outlines and flame colors. Use a 1-logical-pixel near-black outline.

Keep one exact invisible 4 columns × 4 rows grid. Each animation cell represents exactly 40×40 logical pixels (320×320 physical pixels at 8× integer scale). Keep the whole character/effect in each cell within 34 logical pixels wide × 38 logical pixels tall, with at least 1 logical pixel of empty background on every edge. No frame content may cross into another cell. Use a single perfectly uniform #00FF00 background with no noise, gradients, grid lines, labels, text, or shadows.

Preserve design: compact medium-small helmeted fire sorcerer, closed dark iron visor completely hiding face with absolutely no eyes/skin/mouth, crooked broad-brim charcoal-purple spell hat, scorched-orange hat band, ember-red robe, armored gloves and boots, wooden fire staff with a small orange-yellow flame crystal. Original 2D blocky/Minecraft-inspired silhouette. Facing right for engine mirroring.

Preserve animation rows exactly: row 1 four-frame walk loop; row 2 four progressive staff wind-up poses without detached projectile; row 3 four progressive staff swing/release/recoil poses with only a short attached flame arc; row 4 four non-gory dispel/death frames ending as an extinguished ember heap. Consistent proportions, baseline, palette, staff, and lighting. Do not add anything else.

The required improvement is strict measurable native pixel structure, not extra detail. Deliberately simplify shapes until every frame can be losslessly center-sampled to a native 40×40 frame.
```

## 攻击帧定点重制（最终替换源图）

```text
Edit the supplied single animation frame into a strict production pixel-art replacement frame for the same Fire Sorcerer. Preserve the exact character identity, proportions, colors, right-facing stance, staff-swing pose, closed eyeless helmet, crooked charcoal-purple wizard hat, ember-red robe, and the general forward crescent flame action.

Critical pixel correction: rebuild EVERY visible contour and fill on one globally aligned square logical-pixel grid. Use only solid hard-edged square blocks, no anti-aliasing, no gradients, no blur, no texture noise, no thin 1-physical-pixel marks, no high-resolution jagged detail. Every intended logical pixel must appear as one uniform integer-sized square block. Use at most 18 opaque colors and a consistent 1-logical-pixel near-black outline.

This is exactly ONE sprite frame, not a sheet. The intended native canvas is exactly 40×40 logical pixels. Keep all visible content, including the entire attached crescent flame arc and ember specks, within at most 38 logical pixels wide × 34 logical pixels tall, with at least 1 logical pixel of empty background on all four edges. Simplify the flame arc into chunky 2–4 logical-pixel-wide clusters so it shares the same logical grid as the character; use no isolated specks smaller than one full logical pixel.

Use one perfectly uniform flat #00FF00 background everywhere outside the sprite, with no gradient, noise, shadow, text, border, grid line, scenery, second character, or detached projectile. Feet remain on the same baseline as the reference. The goal is measurable native low pixel density that can be losslessly center-sampled to one 40×40 frame, not additional detail.
```

## 移动动画初次重制（保留前两帧）

前两轮整表编辑仍让第 0/2 帧和第 1/3 帧过于相似，因此改为只生成四帧
横条。该图最终只提供第 0/1 帧；曾经在原生像素阶段局部镜像下半身的方案会
撕裂腰部，已经完全移除。内置 `imagegen` 的提示词：

```text
Use case: precise-object-edit
Asset type: standalone four-frame native pixel-art MOVE strip for a Godot sprite sheet
Input images: Image 1 is the authoritative fire sorcerer identity/style reference. Image 2 shows the latest draft, but its first and third contact poses still look too similar.
Primary request: Create ONE HORIZONTAL ROW ONLY containing exactly four equal square animation cells. Draw the same right-facing fire sorcerer walking in place. No other animation rows and no extra sprites.
Critical leg readability: the robe must part enough to show TWO distinct boots/legs. Track the same two legs by color across the cycle: the NEAR leg has a brighter orange-brown boot with a small gold toe highlight; the FAR leg has a darker purple-brown boot with no gold toe. The colors identify the leg and must not randomly change.
Frames left to right:
1. CONTACT A, wide: bright NEAR boot is farthest forward on screen-right and planted; dark FAR boot is back on screen-left and planted.
2. PASSING A, narrow: bright NEAR boot is planted directly under the pelvis; dark FAR boot is clearly airborne moving forward, with at least one full logical transparent pixel between its sole and the ground.
3. CONTACT B, wide and truly opposite: dark FAR boot is now farthest forward on screen-right and planted; bright NEAR boot is back on screen-left and planted. The screen positions of the bright and dark boots are visibly exchanged from frame 1.
4. PASSING B, narrow and truly opposite: dark FAR boot is planted directly under the pelvis; bright NEAR boot is clearly airborne moving forward, with at least one full logical transparent pixel between its sole and the ground.
Anchor invariants: hat, face, chest, pelvis, staff hand and staff base stay on the same horizontal anchor; maximum one logical pixel horizontal drift. Regular vertical bob only [0,-1,0,-1]. Every planted boot uses the same ground line. Staff and robe hem may counter-swing by only one logical pixel.
Identity/style: exactly match Image 1's dark-purple pointed hat, gray shadowed face, orange-red robe/armor, purple accents, brown staff and orange-yellow flame, chunky low-detail native pixels, outline thickness, proportions and apparent size. Facing right in all frames.
Layout: four clearly separated equal square cells in one row, equivalent to four 40x40 logical frames, generous padding, nothing crosses cell boundaries.
Scene/backdrop: perfectly flat solid #00ff00 chroma-key background, uniform with no shadows, gradients, texture, reflections or lighting variation. Do not use #00ff00 in the character.
Constraints: crisp hard-edged pixel art; no antialiasing, blur, smooth vector curves, text, labels, arrows, grid lines, watermark, extra rows or extra characters. Avoid fused boots, both boots touching ground in passing poses, repeated contact silhouette, skating, hopping, random body drift, staff-side changes or character redesign.
```

## 移动动画反相帧完整重绘（最终第 2/3 帧）

首先生成两个完整人物帧，明确禁止局部翻转和上下身拼接：

```text
Use case: precise-object-edit
Asset type: two full-body replacement frames for a native pixel-art MOVE animation
Input images: Image 1 is the authoritative Fire Sorcerer sprite sheet and identity/palette reference. Image 2 is the previous four-frame walk strip and size/composition reference.
Primary request: Create ONE HORIZONTAL ROW ONLY with exactly TWO equal square cells. These are complete replacement frames for the third and fourth frames of the right-facing Fire Sorcerer's walk loop. Redraw the WHOLE character in each cell from hat tip through torso, belt, robe, pelvis, both legs, and both boots. Do not copy, reflect, flip, paste, or splice only the lower body.

Frame 1 — opposite CONTACT pose: the dark far boot is clearly forward on screen-right and planted; the brighter orange-brown near boot is clearly back on screen-left and planted. Both boots share one ground line. The robe opening and folds must flow naturally and continuously from the belt/pelvis into the two legs.
Frame 2 — opposite PASSING pose: the dark far boot is planted under the pelvis; the brighter orange-brown near boot swings forward and is clearly airborne with at least one logical transparent pixel beneath its sole. The belt, pelvis, robe panels, legs, and boots must form one coherent anatomy.

Critical structural constraints: no horizontal tear at the waist, no seam at the belt, no disconnected torso and lower body, no inverted lower half, no mirrored-only legs, no backward knees, no duplicate leg emerging from the robe. The centerline of chest, belt, pelvis, and planted foot must read as one connected pose. Robe folds must continue across the waist without an abrupt left/right reversal.

Anchor invariants: match Image 1 exactly for the same eyeless dark helmet/face, crooked purple hat and orange band, orange-red robe, purple accents, brown staff and yellow-orange flame. Same character proportions, apparent scale, outline thickness, right-facing orientation, staff hand, and staff direction. Keep hat, helmet, chest, belt, staff hand, and staff base on the same horizontal anchor with at most one logical pixel of drift. Allow only subtle one-pixel vertical walking bob.

Style/medium: strict chunky low-resolution pixel art intended to be reduced with nearest-neighbor sampling into 40×40 native frames. Use hard-edged square pixel clusters, restrained existing palette, near-black one-logical-pixel outline, no anti-aliasing, no gradients, no smooth vector curves, no texture noise.
Layout: exactly two clearly separated equal square cells in one row, generous padding, nothing crosses the cell boundary, no extra sprites or rows.
Scene/backdrop: perfectly flat uniform solid #00ff00 chroma-key background, with no shadow, gradient, floor plane, reflection, texture, labels, grid lines, text, or watermark. Do not use #00ff00 inside the character.
```

随后单独收紧通过帧的单脚离地结构；最终第 3 帧取自这次完整人物重绘：

```text
Use case: precise-object-edit
Input image: Image 1 is a two-cell pixel-art walk strip.
Primary request: Keep the ENTIRE LEFT CELL exactly unchanged. In the RIGHT CELL only, redraw the same complete Fire Sorcerer as a coherent passing-step pose.

Right-cell pose correction: the dark brown/purple FAR boot must be the only planted boot, directly under the pelvis on the common ground line. The bright orange-red NEAR boot must swing forward toward screen-right and be visibly AIRBORNE: its entire sole must have a clear band of at least one full logical green pixel between it and the ground line. Bend that lifted leg naturally from the pelvis. The robe opening and folds must connect continuously from belt to pelvis to both legs.

Critical integrity constraints: redraw the whole right-cell character as one connected figure from hat through boots; no partial reflection, no lower-body-only flip, no waist seam, no horizontal tear, no inverted lower half, no backward knee, no duplicated leg. Chest, belt, pelvis, planted leg and planted foot must form one readable centerline. Preserve the exact eyeless helmet, purple hat, orange-red robe, palette, staff, flame, proportions, scale, outline thickness, right-facing direction, and upper-body anchor from Image 1.

Keep exactly two equal square cells in one horizontal row. Preserve the perfectly flat uniform solid #00ff00 background. No shadow, floor plane, gradient, texture, grid, text, watermark, extra frame or extra character. Strict chunky hard-edged low-resolution pixel art; no antialiasing or smooth curves.
```

最后单独收紧反相接触帧的腿部身份；最终第 2 帧取自这次完整人物重绘：

```text
Use case: precise-object-edit
Input image: Image 1 is a two-cell pixel-art walk strip.
Primary request: Keep the ENTIRE RIGHT CELL exactly unchanged. In the LEFT CELL only, redraw the same COMPLETE character as one coherent full-body opposite contact pose. Do not make a local cut-and-paste edit.

Mandatory leg identity and screen placement in the LEFT CELL:
- SCREEN-LEFT / rear leg and boot: BRIGHT ORANGE-RED with a GOLD toe highlight, planted behind.
- SCREEN-RIGHT / forward leg and boot: DARK PURPLE-BROWN with NO gold highlight, extended forward and planted.
The two boots must visibly exchange both screen positions AND colors compared with a normal contact pose. The dark boot must be the rightmost boot. The bright boot must be the leftmost boot. Both soles share one ground line.

Redraw the whole left-cell figure from hat through chest, belt, robe, pelvis, legs and boots so anatomy remains continuous. The robe opening must lead naturally from the belt to these swapped leg positions. No waist seam, no horizontal tear, no lower-body-only flip, no inverted lower half, no backward knee, no duplicated leg, no disconnected body. Preserve the exact eyeless helmet, purple hat, orange-red robe, palette, staff, flame, proportions, scale, outline thickness, right-facing direction, and upper-body anchor.

Keep exactly two equal square cells in one horizontal row and preserve the flat solid #00ff00 background. No shadow, gradient, floor, grid, text, watermark, extra sprite or extra row. Strict chunky hard-edged low-resolution pixel art; no antialiasing or smooth curves.
```

## 火球动画（最终源图）

```text
Create a production-ready strict low-resolution pixel-art sprite sheet for one small homing fireball projectile. Output one perfectly square image divided into an invisible exact 4 columns × 4 rows grid of equal square cells. Background must be a single perfectly uniform flat #00FF00 chroma green everywhere, with no grid lines, labels, text, borders, shadows, gradients, or noise.

TRUE LOW-RES PIXEL ART: every intended logical pixel must be a globally aligned uniform square physical block, approximately 20×20 physical pixels per logical pixel across the entire sheet. Use only hard-edged opaque solid colors, no anti-aliasing, no blur, no glow haze, no soft transparency, no gradients, no thin high-resolution marks. Use at most 8 projectile colors total: near-black/dark red outline, dark orange, orange, golden yellow, pale yellow-white. One-logical-pixel dark outline. Each frame represents an exact 16×16 logical-pixel canvas, and every visible fireball/effect must fit within at most 14×14 logical pixels with one logical pixel of green padding on all edges. Nothing crosses cell boundaries.

Design: a tiny compact magical fireball, readable at very small scale, with a round bright core and a short blocky flame tail pointing left so the projectile visually travels right. Original game sprite, energetic but not realistic.

Animation rows, left to right:
Row 1 — FLY loop, 4 coherent frames: compact bright core, flame tail flickers in four distinct but size-consistent poses. Projectile remains centered and points right.
Row 2 — SPAWN FLICKER loop, 4 coherent frames: tiny ember core to brighter charged core; keep each sprite centered. Do not depict scale growth by changing canvas or crossing cells; just flame flicker.
Row 3 — FIRST-CONTACT DISPEL, 4 non-AOE visual frames: compact hit flash, broken flame petals close to center, small embers, gone. Effect must never read as a large explosion.
Row 4 — LIFETIME EXPIRE, 4 visual frames: fireball dims, collapses inward, becomes a few embers, fully extinguishes. No shockwave, no blast radius.

No character, weapon, scenery, smoke cloud, shockwave, circle outline, UI, letters, numbers, checkerboard, or extra icons. Maintain strict animation continuity and measurable integer pixel structure; deliberately simplify instead of adding detail.
```
