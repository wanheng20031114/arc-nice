# C2 圆斩：批准主视觉独立生成记录

- 工具：内置 ImageGen
- 唯一图像输入：`combat_robot_main_battle_elite_user_approved_main_visual_20260812.png`
- 输入 SHA-256：`9739b978a73f471d844a3325632b2d33ac4d68627724d1bb7cb9a4283118d3f7`
- ImageGen 原始输出：`C:\Users\wh\.codex\generated_images\019fbc5c-62ba-7bf3-a786-3d3893d315aa\exec-50320dd9-c6a6-404f-ab6a-e6c058966461.png`
- 项目 raw：`combat_robot_main_battle_elite_anim_c2_circle_slash_user_anchor_only_v1_imagegen.png`
- 输出 SHA-256：`b97cbc83d003d24f3971517153fae7ef63449a17c4eaec7d415a39b17863d450`
- 字节关系：ImageGen 原始输出与项目 raw 逐字节相同
- 状态：未经抠底、切帧、缩放、调色板量化或 native 化；等待动画人工门

## 完整提示词

```text
Use case: identity-preserve
Asset type: pixel-art game animation sprite sheet
Input images: Image 1 is the sole approved main-visual identity source. Do not use or infer any previous animation sheet.
Primary request: Generate C2 skill-1 dual-sword circular slash as one independent 4-column × 2-row sprite sheet with exactly 8 complete frames in left-to-right, top-to-bottom order.
Identity lock: Every frame must preserve Image 1's exact robot: dual orange eyes, paired tall shoulder pods and lamps, cold-steel chest with orange V core, separate hip and segmented legs, broad feet, two arms/two hands, and exactly two matching broad heavy swords kept connected to their own left/right hands.
Animation: Frame 1 begins in a tight X-shaped cross guard. Frames 2–3 load rotational force. Frames 4–6 open both swords in opposite directions like a mechanical flower and perform one powerful 360-degree dual-sword circular sweep; the two swords stay distinct and describe opposite halves of the sweep without becoming extra weapons. Frames 7–8 decelerate into a low bilateral recovery stance. Keep the body planted and readable; make rotation through explicit pose changes only.
Pixel style: exactly the same coarse hard-edged pixel language, cold-steel plus orange palette, continuous black outline, blocky staircase diagonals and large flat clusters as Image 1. No smoothing, gradients, blur, noise, micro-detail, 3D or painterly rendering.
Layout: exactly 4 visual columns × 2 visual rows, reading left-to-right then top-to-bottom; one complete robot per cell; wide green gutters; no frame-to-frame contact or crossing; constant scale and stable body center; both complete sword tips always inside their own cell.
Scene/backdrop: visually uniform bright chroma green; no floor, shadow, speed arcs, slash trails, particles, glow, text, UI, frame numbers, borders or watermark.
Avoid: character redesign, missing head eyes, missing shoulder pods, one sword, third weapon, hidden hand, thin sword, fused legs, cropped sword, touching adjacent frames, effects obscuring silhouette.
```
