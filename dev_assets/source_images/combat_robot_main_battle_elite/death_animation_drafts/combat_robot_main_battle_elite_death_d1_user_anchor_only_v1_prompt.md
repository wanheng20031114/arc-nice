# D1 用户主视觉单锚点 ImageGen 记录（v1）

- 生成方式：Codex 内置 ImageGen（一次生成，未 refine）
- 用途：第二门动画结构参考，`D1 熄灭跪倒解体`
- 状态：`raw_reference_only`；不是 native、atlas 或运行资源
- 唯一图像输入：`C:/Users/wh/AppData/Local/Temp/codex-clipboard-f6c75c62-1fac-41e2-9a80-1d54dd7f6390.png`
- 输入角色：唯一角色身份与视觉设计参考
- 输入 SHA-256：`9739b978a73f471d844a3325632b2d33ac4d68627724d1bb7cb9a4283118d3f7`
- 输入尺寸：`1254x1254`
- ImageGen 原始输出：`C:/Users/wh/.codex/generated_images/019feffc-160d-7422-96bf-08c0cd44442c/exec-3ccf65b9-ece9-4516-948f-c10bd1d640d7.png`
- 工作区无损副本：`dev_assets/source_images/combat_robot_main_battle_elite/death_animation_drafts/combat_robot_main_battle_elite_death_d1_user_anchor_only_v1_imagegen.png`
- 输出 SHA-256：`a3b13792973dd7faabffbb82f5aed8411542af43a0de446e8004114184465754`
- 输出尺寸：`1536x1024`
- 原始输出与工作区副本：字节完全相同
- 其他图像输入：无；未向 ImageGen 输入旧动画、direct-native、旧候选或点表

## 完整提示词

```text
Use case: stylized-concept
Asset type: game enemy animation structure sheet, D1 death animation
Input images: Image 1 is the ONLY character identity and visual-design reference. Do not use or infer any other animation, native sprite, point table, character image, or external reference.
Primary request: Create one new 4 columns × 2 rows sprite-animation sheet containing exactly 8 distinct frames, read left-to-right across the top row as frames 1–4, then left-to-right across the bottom row as frames 5–8. The action is "core extinguishes, robot kneels, then disassembles."
Character identity: preserve Image 1's same main battle robot design—the compact front-facing wedge-visor head with two separate orange eyes, cold steel-gray segmented armor, orange V-shaped chest furnace, clearly separated torso/hips/legs, two shoulder pods, and two matching broad heavy swords, one held by each hand on opposite sides.
Frame semantics:
F1: fully intact standing combat-ready pose; orange eyes and V furnace lit.
F2: fully intact, power fading; torso drops slightly, knees begin bending, orange energy dimmer.
F3: fully intact, deeper controlled kneel; both feet planted and both swords still firmly connected to their own hands.
F4: fully intact, one-knee-near-ground kneel; head lowers, energy almost out, both swords still connected.
F5: fully intact final kneeling pose; eyes and V furnace extinguished/dark, but NO detached part yet; both complete swords remain connected to both hands.
F6: the FIRST frame where disassembly begins; only a few armor plates and one shoulder component separate slightly from the kneeling core. Both swords remain visually present and traceable.
F7: further controlled disassembly around the collapsed kneeling core; head, torso, limbs, and both swords remain recognizable as belonging to one character, with parts separated but not scattered into neighboring cells.
F8: final compact pile of recognizable robot parts and both heavy swords; no explosion, no debris cloud, no disappearance.
Style/medium: genuinely coarse low-logical-resolution pixel art from the first glance; large consistent square pixel blocks, hard 90-degree and staircase edges, crisp continuous black/dark outlines, flat 12–16 color palette, no antialiasing, no smooth gradients, no blur, no tiny rendered details, no 3D softness. Match Image 1's cold steel gray, black, white highlight, and orange furnace palette and its chunky pixel language.
Layout: eight equal generous cells with wide flat-green gutters; each frame centered independently; absolutely no character pixels crossing cell boundaries and no frame-to-frame overlap. Keep consistent scale, camera, registration, and front/near-front viewpoint in all frames.
Backdrop: perfectly flat uniform solid #00ff00 chroma-key background across the entire sheet, including gutters. No shadows, floor, grid lines, panel borders, labels, text, frame numbers, watermark, gradients, glow haze, texture, reflections, or lighting variation. Do not use #00ff00 in the character.
Hard invariants: exactly one robot per frame; exactly two matching heavy swords per frame and one per side through F1–F5; F1–F5 must be complete intact silhouettes with no detached pieces; F6 is the first detached-parts frame; preserve two-eye head identity, paired shoulders, orange chest V, hip separation, leg gap, two feet, two hands and sword ownership as long as the body is intact; all silhouettes must be closed, readable, and isolated inside their own cell.
Avoid: extra swords, missing sword, merged swords, a single horizontal eye bar, old square-screen robot head, asymmetrical redesign, parts entering another frame, duplicate characters, text, labels, effects, smoke, fire, floor shadow, motion blur, or a cinematic illustration/render.
```

## 只读视觉审计

- 版式：4×2，恰好 8 帧；帧间有充足绿色间隔，未见跨格串帧。
- F1–F5：均保留完整机体、左右双剑与手部连接；F5 熄灭并跪倒，但尚未出现脱落件。
- F6：首次出现肩部/装甲轻微分离，符合“第六帧才解体”。
- F7：解体加深，头、躯干、四肢和两剑仍可追踪。
- F8：形成紧凑零件堆，双剑仍在左右两侧；无爆炸、烟尘或跨格碎片。
- 身份：双眼楔盔、成对肩舱、橙色胸 V、分体髋腿和双持宽重剑均可辨认。
- 风格：从第一眼即为粗逻辑像素画，硬边连续；未见平滑渲染或文字。
- 绿幕：视觉上为纯绿色无地面阴影；本文件保留原始 ImageGen 字节，未做抠绿、缩放、压缩或其他后处理。
- 结论：通过结构原稿门；无需第二次 refine。后续若制作 native，仍须走独立确定性像素重建与人工确认，不能把本原稿直接缩小或采样。
