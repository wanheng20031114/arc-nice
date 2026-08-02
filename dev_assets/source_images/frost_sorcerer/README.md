# 寒冰术士 imagegen 素材记录

运行时角色贴图由 Codex 内置 `imagegen` 重新生成。2026-07-22 的尺寸修复没有
缩放旧的 38 像素高角色，而是按火焰术士的原生占位重新绘制角色。2026-07-30
又把移动动画从四帧重做为完整八相位步行循环；移动改用独立的 8×1 运行时横条，
蓄力、攻击和消散仍保留主图中的四帧动画。运行时仅进行生成稿到 40×40 原生帧
所必需的栅格化，寒冰服装、冰冠、法杖与法术轮廓保持独立设计。

## 当前角色源文件

每个动作同时保留 imagegen 绿色背景原稿和去背透明稿。当前移动最终源为：

- `frost_sorcerer_move_8pose_v3_imagegen_source.png`：4×2 八相位绿色背景源图。
- `frost_sorcerer_move_8pose_v3_alpha.png`：对应的透明源图。
- `resources/texture/enemy/sorcerer/frost_sorcerer_move.png`：运行时 320×40、8×1 移动横条。

其余三条四帧动作继续写入角色主图：

- `frost_sorcerer_windup_fire_scale_imagegen_source.png`
- `frost_sorcerer_windup_fire_scale_alpha.png`
- `frost_sorcerer_attack_fire_scale_imagegen_source.png`
- `frost_sorcerer_attack_fire_scale_alpha.png`
- `frost_sorcerer_death_fire_scale_imagegen_source.png`
- `frost_sorcerer_death_fire_scale_alpha.png`

早期的 `frost_sorcerer_move_fire_scale_v2_*`、
`frost_sorcerer_imagegen_source.png`、
`frost_sorcerer_alpha.png` 与攻击修正版保留为历史原稿，但已不参与当前移动
运行时构建。冰锥仍使用
`frost_sorcerer_ice_spike_imagegen_source.png` 和
`frost_sorcerer_ice_spike_alpha.png`。

## 最终角色提示词

生成模式：Codex 内置 `imagegen`；`precise-object-edit`；绿色背景便于确定性去背。

### 移动

```text
Using the accepted compact Frost Sorcerer as the exact identity reference,
create one 4x2 sheet containing a coherent eight-phase right-facing walk cycle.
Use row-major order: right-foot contact, down, passing and up, followed by the
mirrored left-foot contact, down, passing and up phases. Keep one stable body
root, a common ground line, unchanged body scale, the navy robe, pale-cyan
angular ice crown/hood and short crystal staff. Every pose must be a genuine
locomotion phase rather than a translated or duplicated idle pose. Use coarse
deliberate square pixel clusters, hard edges, no glow, antialiasing, blur,
gradients, shadows, labels or grid lines, at most 18 colors, and a flat #00FF00
background with generous separation between frames.
```

八帧按行优先顺序读取。栅格化后，每个 40×40 帧都使用姿态中心 `(17, 27)`，
共同地线为 `y = 38`，八帧横向可见像素质心的峰峰值不超过 1 像素。运行时以
12 fps 播放，`8 / 12 = 0.667` 秒，保持原四帧 6 fps 的完整循环时长。
带红色中心点、绿色地线和洋红质心的三角色对照图保存在
`dev_assets/generated_previews/sorcerer_move_center_audit.png`，循环动图保存在
`dev_assets/generated_previews/sorcerer_move_cycle_preview.gif`。

### 蓄力

```text
Use the accepted compact Frost Sorcerer move strip as the exact identity and
scale reference and the Fire Sorcerer only for action timing. Create one
horizontal four-frame windup strip: brace, pull back, raise/charge compact ice,
fully charged. Keep the actor the same size as move; complete silhouette targets
are approximately 24x29, 29x28, 26x30 and 24x33 native pixels. A raised staff
may add height, but the crown and body must not grow. Use #00FF00, coarse square
pixel clusters, hard edges, no antialiasing, blur, gradients, glow or labels,
and at most 18 colors.
```

### 攻击

```text
Use the accepted compact Frost Sorcerer move strip as the exact identity and
scale reference and the Fire Sorcerer's third row for action timing. Create one
horizontal four-frame attack strip: low thrust, stronger extension/charge,
release a short attached blocky ice burst, recoil. Keep the actor fixed at about
27-29x29 native pixels; complete silhouette targets are approximately 31x29,
33x29, 38x28 and 28x29. Do not add a detached projectile. Use #00FF00, coarse
square pixel clusters, hard edges, no antialiasing, blur, gradients, glow or
labels, and at most 18 colors.
```

### 消散

```text
Use the accepted compact Frost Sorcerer move strip as the exact identity and
scale reference and the Fire Sorcerer's fourth row for timing. Create one
horizontal four-frame non-gory death/dispel strip: hit stagger, kneel/collapse,
compact attached blocky ice fragments, small collapsed icy heap. Complete
silhouette targets are approximately 23x29, 28x27, 32x29 and 28x19 native
pixels. Do not grow the body or scatter long detached particles. Use #00FF00,
coarse square pixel clusters, hard edges, no antialiasing, blur, gradients, glow
or labels, and at most 18 colors.
```

## 去背与确定性运行时构建

各动作原稿使用 imagegen 技能自带的 `remove_chroma_key.py`，以 border 自动取色、
soft matte、12/220 阈值和 despill 生成透明稿。随后运行：

```powershell
python dev_tools/process_frost_sorcerer_assets.py
python dev_tools/process_frost_sorcerer_assets.py --check-only
```

脚本逐帧调用 `dev_tools/pixel_grid_analyzer.py` 记录视觉网格分析。4×2 移动源图
按行优先拆成八帧，分别放入独立的 `resources/texture/enemy/sorcerer/frost_sorcerer_move.png`；
每帧 40×40，最终横条为 320×40。构建会锁定姿态中心 `(17, 27)`、地线
`y = 38` 和不超过 1 像素的横向质心峰峰值，不再把八个姿态分别拉伸到旧四帧
火焰术士边界。蓄力、攻击和消散仍按原有四帧契约写入
`resources/texture/enemy/sorcerer/frost_sorcerer.png` 主图。全部输出继续强制二值 alpha、透明
RGB 清零和受控角色调色板。`--check-only` 会在内存中重建并确认主图、独立移动
横条和冰锥运行时贴图均未过期。

冰锥仍按独立固定尺度生成 128×128 图集（每帧 32×32），不受角色边界约束影响。

## 冰锥提示词

```text
Create an exact 4x4 sprite sheet for one tiny right-facing magical ice-spike
projectile. Rows are fly, spawn, impact and expire, each with four coherent
frames. Use crisp square pixel clusters, a compact pale-cyan core and deep-blue
outline, consistent apparent projectile scale, no text, borders or grid lines,
on a perfectly flat chroma-green background.
```
