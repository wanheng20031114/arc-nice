# 火焰术士 imagegen 素材记录

生成模式：Codex 内置 `imagegen`。

最终生产管线只使用以下三份源图：

- `fire_sorcerer_generated_v2.png`
- `fire_sorcerer_attack_1_generated_v1.png`
- `fire_sorcerer_fireball_generated_v1.png`

`fire_sorcerer_generated_v1.png` 是首次生成但被像素网格硬门槛拒绝的留档，
没有进入任何运行时素材。最终源图由
`dev_tools/process_fire_sorcerer_assets.py` 做绿幕移除、逐帧逻辑网格分析和
整数像素采样；脚本不存在跳过分析或强行缩放的入口。

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
