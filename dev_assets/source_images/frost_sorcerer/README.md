# 寒冰术士 imagegen 素材记录

运行时贴图由 Codex 内置 `imagegen` 生成的独立寒冰设计构建。已有火焰术士
只用于说明 4×4 布局、朝向、脚底锚点和动作阶段；服装、头部、法杖、配色与
冰系法术轮廓均重新设计，未把火焰术士当作像素级身份模板。

## 文件

- `frost_sorcerer_imagegen_source.png`：首次验收的 4×4 角色源图。
- `frost_sorcerer_alpha.png`：首次源图去除绿色背景后的透明版本。
- `frost_sorcerer_attack_scale_refined_imagegen_source.png`：只修正第三行
  攻击动作角色尺度的定向编辑结果。
- `frost_sorcerer_attack_scale_refined_alpha.png`：定向编辑的透明版本；运行时
  仅取其第三行，其他三行仍来自首次验收源图。
- `frost_sorcerer_ice_spike_imagegen_source.png`：4×4 冰锥源图。
- `frost_sorcerer_ice_spike_alpha.png`：冰锥透明版本。

## 角色生成约束

生成模式：Codex 内置 `imagegen`，新图生成。

```text
Create a distinct Frost Sorcerer 4×4 pixel-art animation sheet. Use the
provided Fire Sorcerer only as a structural reference for the right-facing
layout, grounded center anchor and action progression; do not copy its visual
identity. Design a faceted navy visor, pale-cyan angular crystal crown/hood,
glacier-and-midnight robes and an ice-crystal staff. Row 1 is a genuinely
readable four-pose walk cycle (contact, passing, opposite contact, opposite
passing); row 2 windup; row 3 attack; row 4 non-gory defeat/dispel. Keep one
consistent character scale, strict hard-edged low-resolution pixel art and an
exact 4×4 grid on a flat chroma-green background, with no labels or borders.
```

第三行定向修正使用 `precise-object-edit`：保留第 1、2、4 行，只让第 3 行
角色身体与行走帧保持相同视认尺度、锚点和脚底线，并缩短过长的法杖/冰霜
拖尾，避免特效包围盒把角色本体整体缩小。

## 冰锥生成约束

生成模式：Codex 内置 `imagegen`，新图生成。

```text
Create an exact 4×4 sprite sheet for one tiny right-facing magical ice-spike
projectile. Rows are fly, spawn, impact and expire, each with four coherent
frames. Use crisp square pixel clusters, a compact pale-cyan core and deep-blue
outline, consistent apparent projectile scale, no text, borders or grid lines,
on a perfectly flat chroma-green background.
```

## 确定性运行时构建

```powershell
python dev_tools/process_frost_sorcerer_assets.py
```

脚本会逐格调用项目的逻辑像素网格分析器，记录 imagegen 源图属于
`native_or_unknown` 的低置信度结果，再使用人工验收后的同族固定尺度进行最近邻
采样。最终角色为 160×160（每帧 40×40），冰锥为 128×128（每帧
32×32）；输出强制二值 alpha、透明 RGB 清零、固定角色脚底线。角色前三行
统一使用行走帧确定的固定尺度，并按参考火焰术士动作节奏验收过的下半身锚点
落位；攻击冰芒超出 40×40 的部分由画布裁切，不再把「角色本体 + 特效」的
整格包围盒逐帧缩小。脚底以下与主体远离的微小抠图残片会被确定性剔除，避免
游离像素错误地拉高包围盒；第四行消散碎片仍只允许缩小、不允许放大。
