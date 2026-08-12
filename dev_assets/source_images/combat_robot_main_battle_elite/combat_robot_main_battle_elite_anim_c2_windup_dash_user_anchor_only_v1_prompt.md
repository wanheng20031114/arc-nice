# C2 前摇与冲锋：批准主视觉独立生成记录

- 工具：内置 ImageGen
- 唯一图像输入：`combat_robot_main_battle_elite_user_approved_main_visual_20260812.png`
- 输入 SHA-256：`9739b978a73f471d844a3325632b2d33ac4d68627724d1bb7cb9a4283118d3f7`
- ImageGen 原始输出：`C:\Users\wh\.codex\generated_images\019fbc5c-62ba-7bf3-a786-3d3893d315aa\exec-f74e6983-ceeb-46dd-85cf-1ebcef93da7d.png`
- 项目 raw：`combat_robot_main_battle_elite_anim_c2_windup_dash_user_anchor_only_v1_imagegen.png`
- 输出 SHA-256：`02a9008d3acbc04fe5eb37f08d13d55fe4419a6febe8183a17f1d1a2f3b90250`
- 字节关系：ImageGen 原始输出与项目 raw 逐字节相同
- 状态：未经抠底、切帧、缩放、调色板量化或 native 化；等待动画人工门

## 完整提示词

```text
Use case: identity-preserve
Asset type: pixel-art game animation sprite sheet
Input images: Image 1 is the sole approved main-visual identity source. Do not use or infer any previous animation sheet.
Primary request: Generate C2 skill-1 windup-and-dash as one independent 4-column × 2-row sprite sheet with exactly 8 complete frames in left-to-right, top-to-bottom order.
Identity lock: In every frame preserve Image 1's exact main-battle-robot design: the same horizontal black sensor head with two orange eyes, paired tall shoulder pods with small orange lamps, cold-steel trapezoid chest and orange V core, separate dark hip assembly, two segmented load-bearing legs and broad feet, and exactly two matching broad heavy swords—one held by the visual-left hand and one by the visual-right hand. Never redesign, simplify away, fuse, swap, hide, or duplicate those parts.
Animation: Frames 1–4 are anticipation. The robot lowers its center slightly and brings both heavy swords inward into a clear X-shaped cross guard in front of the chest while keeping both hands and both blades readable. Frames 5–8 are a fast locked-direction dash pose: torso leans forward consistently, legs drive backward, the same crossed guard remains braced, and the facing direction never changes. Pose-only sheet; do not draw world translation, speed lines, dust, or VFX.
Pixel style: Match Image 1's coarse hard-edged pixel-art construction, palette, black outlines, large square clusters, simple staircase diagonals and restrained flat steel shading. Preserve clean continuous armor and blade edges. Do not introduce smaller pixels, antialiasing, blur, gradients, texture noise, painterly detail, or 3D rendering.
Layout: exactly 4 equal visual columns × 2 equal visual rows; exactly one complete robot per cell; generous flat-green gutter around every frame; no foreground pixel may touch or cross another frame; identical character scale and registration; full head, feet, hands, guards and both sword tips inside every cell.
Scene/backdrop: one visually flat bright chroma-green field only; no floor, shadow, glow, reflection, border, labels, text, frame numbers or watermark.
Avoid: old square-screen robot, missing eyes, missing shoulder pod, one sword, both swords on one side, hidden hand, thin rods instead of heavy swords, fused legs, cropping, connected adjacent frames, extra poses, motion trails or effects.
```
