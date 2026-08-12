# J1 起跳：批准主视觉独立生成记录

- 工具：内置 ImageGen
- 唯一图像输入：`combat_robot_main_battle_elite_user_approved_main_visual_20260812.png`
- 输入 SHA-256：`9739b978a73f471d844a3325632b2d33ac4d68627724d1bb7cb9a4283118d3f7`
- ImageGen 原始输出：`C:\Users\wh\.codex\generated_images\019fbc5c-62ba-7bf3-a786-3d3893d315aa\exec-95869c95-ecbb-4279-a4b9-e4479d179bb6.png`
- 项目 raw：`combat_robot_main_battle_elite_anim_j1_takeoff_user_anchor_only_v1_imagegen.png`
- 输出 SHA-256：`9ad07d220650c5a85f6c05f3561469cbef9bc6fbeaa943a11c88113d8788800e`
- 字节关系：ImageGen 原始输出与项目 raw 逐字节相同
- 状态：未经抠底、切帧、缩放、调色板量化或 native 化；等待动画人工门

## 完整提示词

```text
Use case: identity-preserve
Asset type: pixel-art game animation sprite strip
Input images: Image 1 is the sole approved main-visual identity source. Do not use or infer any previous animation.
Primary request: Generate J1 skill-2 takeoff as one independent horizontal strip of exactly 5 complete frames.
Identity lock: Preserve Image 1 exactly in all five frames: two orange head eyes, two tall shoulder pods with lamps, orange V core, separated hip and two segmented legs, broad feet, two arms/hands, and exactly two matching heavy swords—one per side and continuously connected to its hand.
Animation: Frame 1 is grounded anticipation with knees bending and both swords angled slightly outward. Frame 2 compresses into a deep crouch. Frame 3 pulls both knees upward while the swords form a clear V around the body. Frame 4 launches upward rapidly with legs tucked; frame 5 is the highest visible ascending pose, still a complete robot with both swords. The sequence must read as monotonic upward acceleration. Preserve the relative vertical trajectory across the strip; do not re-center each pose to erase the rise.
Pixel style: match Image 1's coarse blocky hard-edged pixel art, exact design language and colors; continuous black edges, large square clusters and simple staircase diagonals. No tiny pixels, antialiasing, gradients, blur, texture noise, smooth illustration or 3D.
Layout: exactly five visual cells in one row; one complete pose per cell; generous green separation; identical character scale; no pose touches another; full robot and both sword tips in every cell; enough top padding for the rising trajectory.
Scene/backdrop: visually flat bright chroma green only; no floor, shadow, jump trail, dust, glow, crosshair, text, border, frame number, UI or watermark.
Avoid: missing/merged swords, both swords on one side, cropped head or sword, shoulder redesign, fused legs, duplicated limbs, connected cells, sheet with more or fewer than five poses.
```
