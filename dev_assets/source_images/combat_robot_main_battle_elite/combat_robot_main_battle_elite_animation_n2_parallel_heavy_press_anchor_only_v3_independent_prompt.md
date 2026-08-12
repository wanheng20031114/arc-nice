# N2：批准主视觉独立生成 v3

- 工具：内置 ImageGen
- 唯一图像输入：`combat_robot_main_battle_elite_user_approved_main_visual_20260812.png`
- 输入 SHA-256：`9739b978a73f471d844a3325632b2d33ac4d68627724d1bb7cb9a4283118d3f7`
- ImageGen 原始输出：`C:\Users\wh\.codex\generated_images\019fbc5c-62ba-7bf3-a786-3d3893d315aa\exec-d8e33d66-c1a8-47ed-81c8-b0b1e825decd.png`
- 项目 raw：`combat_robot_main_battle_elite_animation_n2_parallel_heavy_press_anchor_only_v3_independent_imagegen.png`
- 输出 SHA-256：`7cb231104872f4e8b6079733faab764094665ca725cdd8902badb780d4e8e68f`
- 字节关系：原始输出与项目 raw 相同
- 说明：这是一次新的独立调用；未输入 v1、v2 或其他动画。
- 状态：未抠底、未切帧、未缩放、未 native 化；等待人工门。

## 完整提示词

```text
Use case: identity-preserve
Asset type: pixel-art game animation sprite sheet
Input images: Image 1 is the sole approved main-visual identity source. Do not use, imitate, or infer any prior animation or derived sprite.
Primary request: Independently generate the selected N2 parallel heavy-press normal attack as exactly one 4-column by 2-row sheet with exactly 8 complete frames, read left-to-right then top-to-bottom.
Identity lock: In every frame preserve Image 1 exactly: horizontal two-orange-eye visor; paired tall shoulder pods and orange lamps; cold-steel chest with orange V core; separate dark hip and two segmented legs with broad feet; two arms, two hands, and exactly two identical broad heavy swords held one per side. Maintain the same scale, proportions and palette.
Strict temporal sequence: F1 low bilateral ready guard. F2 raise both swords in parallel to shoulder height. F3 lift both parallel swords fully overhead for the peak windup. F4 begin one synchronized forceful downward heavy press; both blades remain parallel and are halfway down. F5 is the full low impact/settlement pose and the damage frame: both swords arrive together, clearly low and forward, while the robot compresses under the force. F6 briefly holds that exact impact family with a small rebound. F7 withdraws both swords together toward low guard. F8 returns to F1 ready. Never return to ready between F3 and F5. Never cross the swords and never turn this into alternating attacks.
Critical separation: Each of the eight complete poses is isolated inside its own visual cell with very wide green gutters. No blade, sword tip, foot, outline, shadow or cluster may touch or cross an adjacent pose. Do not draw cell dividers, grid lines, boxes or borders.
Pixel style: Match Image 1's coarse hard-edged pixel construction and apparent logical pixel density: large square clusters, continuous black outline, staircase diagonals, restrained flat cold-steel shading and orange accents. No tiny pixels, antialiasing, smoothing, gradients on the robot, noise, micro-detail, painterly or 3D rendering.
Canvas/backdrop: one uninterrupted visually uniform bright chroma-green background only; no floor, shadow, glow, slash VFX, motion trails, text, frame labels, UI or watermark.
Composition: stable grounded baseline and constant character size; both complete swords, hands, head, shoulder pods and feet fully inside each cell with generous padding.
Avoid: incoherent order, early reset, unrelated crouch, crossed blades, one missing sword, hidden hands, adjacent-frame contact, crop, character redesign, grid lines.
```
