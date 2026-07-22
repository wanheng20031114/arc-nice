# 寒冰术士 imagegen 素材记录

运行时角色贴图由 Codex 内置 `imagegen` 重新生成。2026-07-22 的尺寸修复没有
缩放旧的 38 像素高角色，而是按火焰术士的原生占位重新绘制四条动画；运行时
仅进行生成稿到 40×40 原生帧所必需的栅格化。火焰术士用于约束体型、脚底线、
逐帧边界和动作阶段，寒冰服装、冰冠、法杖与法术轮廓保持独立设计。

## 当前角色源文件

每个动作同时保留 imagegen 绿色背景原稿和去背透明稿：

- `frost_sorcerer_move_fire_scale_v2_imagegen_source.png`
- `frost_sorcerer_move_fire_scale_v2_alpha.png`
- `frost_sorcerer_windup_fire_scale_imagegen_source.png`
- `frost_sorcerer_windup_fire_scale_alpha.png`
- `frost_sorcerer_attack_fire_scale_imagegen_source.png`
- `frost_sorcerer_attack_fire_scale_alpha.png`
- `frost_sorcerer_death_fire_scale_imagegen_source.png`
- `frost_sorcerer_death_fire_scale_alpha.png`

早期的 `frost_sorcerer_imagegen_source.png`、`frost_sorcerer_alpha.png` 与攻击
修正版保留为历史原稿，但已不参与角色运行时构建。冰锥仍使用
`frost_sorcerer_ice_spike_imagegen_source.png` 和
`frost_sorcerer_ice_spike_alpha.png`。

## 最终角色提示词

生成模式：Codex 内置 `imagegen`；`precise-object-edit`；绿色背景便于确定性去背。

### 移动

```text
Using the existing Frost Sorcerer only for identity and the native Fire
Sorcerer sheet for scale, create exactly one horizontal four-frame right-facing
walk strip. Redraw the Frost Sorcerer with a compact near-square silhouette at
the Fire Sorcerer's native visual size: about 27-28 pixels wide by 29 pixels
tall after rasterization, one common ground line, four genuinely distinct walk
poses. Keep the navy robe, pale-cyan angular ice crown/hood and short crystal
staff. Use coarse deliberate square pixel clusters, hard edges, no glow,
antialiasing, blur, gradients, shadows, labels or grid lines, at most 18 colors,
and a flat #00FF00 background with generous separation between frames.
```

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

四张原稿使用 imagegen 技能自带的 `remove_chroma_key.py`，以 border 自动取色、
soft matte、12/220 阈值和 despill 生成透明稿。随后运行：

```powershell
python dev_tools/process_frost_sorcerer_assets.py
python dev_tools/process_frost_sorcerer_assets.py --check-only
```

脚本逐帧调用 `dev_tools/pixel_grid_analyzer.py` 记录视觉网格分析，再把四条新绘制
源图栅格化到 4×4、每帧 40×40 的运行时图集。寒冰术士 16 帧的 alpha 边界逐帧
精确采用火焰术士对应帧的边界，因此体型、水平锚点和脚底线都不会再次漂移；输出
强制二值 alpha、透明 RGB 清零和 24 色角色调色板。`--check-only` 会在内存中
重建并确认角色运行时贴图逐像素没有过期；冰锥则精确比较 alpha 几何并验证输出
契约，避免不同 Pillow 版本对等深色量化结果造成误报。

冰锥仍按独立固定尺度生成 128×128 图集（每帧 32×32），不受角色边界约束影响。

## 冰锥提示词

```text
Create an exact 4x4 sprite sheet for one tiny right-facing magical ice-spike
projectile. Rows are fly, spawn, impact and expire, each with four coherent
frames. Use crisp square pixel clusters, a compact pale-cyan core and deep-blue
outline, consistent apparent projectile scale, no text, borders or grid lines,
on a perfectly flat chroma-green background.
```
