# 雷电术士角色素材

雷电术士角色使用 `imagegen` 的参考图引导模式生成。角色动作沿用术士家族的
体型契约，识别色改为金黄、亮黄和淡黄；闪电链本身是运行时纯特效，不画进角色
图集。2026-07-30 将移动从四帧重做为独立的八相位步行循环；2026-07-31
又依据寒冰术士的成功步态补齐 F2 单脚通过和 F5 反向换重心，蓄力、施法和死亡
仍保留主图中的四帧动画。

## 文件

- `lightning_sorcerer_move_8pose_v5_imagegen_source.png`：4×2、八相位移动的
  绿色背景主体源图；F2 已重画为单脚通过姿态。
- `lightning_sorcerer_move_f5_v5_imagegen_source.png`：单独放大重画的 F5
  反向换重心源图，左脚完整承重、右脚仅脚尖点地。
- `lightning_sorcerer_move_8pose_v5_alpha.png`：去绿后将 F5 精确替换回第二行
  第二格的透明最终源图。
- `resources/texture/lightning_sorcerer_move.png`：320×40、8×1 的运行时
  移动横条。
- `lightning_sorcerer_windup_imagegen_source.png`：蓄力四帧的绿色背景原图。
- `lightning_sorcerer_attack_imagegen_source.png`：施法四帧的绿色背景原图。
- `lightning_sorcerer_death_imagegen_source.png`：死亡四帧的绿色背景原图。
- 其余动作对应的 `*_alpha.png`：通过 imagegen 技能的
  `remove_chroma_key.py` 去除绿色背景后的透明源图。

旧的 `lightning_sorcerer_move_{imagegen_source,alpha}.png` 和
`lightning_sorcerer_move_8pose_v1_{imagegen_source,alpha}.png` 保留为历史稿，
不再参与当前移动运行时构建。

## 生成方式

四个动作分别生成，均参考现有寒冰、火焰术士以及前一步已接受的雷电术士角色图。
移动源图使用 4×2 布局，按行优先排列八个相位：右脚接触、下沉、通过、抬升，
随后是左脚对应的接触、下沉、通过、抬升。最终稿经过三轮整表定向编辑，再把
F5 单帧放大编辑后确定性合回；每轮都保持上半身和中心点不变。其余三个动作仍是
单行四帧。共同约束如下：

- 每帧完整角色、互不重叠并共用脚底线；移动八帧必须形成可无缝循环的真实步态，
  不能用平移或重复待机姿态代替；
- 紧凑兜帽术士造型、面向右侧、金黄兜帽和袍服、深棕黑阴影、闪电水晶法杖；
- 真像素画、硬边像素块、无抗锯齿、无文字、无格线；
- 背景为纯绿色 `#00FF00`，角色内不使用绿色；
- 移动只做步态起伏；蓄力仅允许法杖附近少量电火花；攻击不绘制长闪电或
  投射物；死亡按四帧逐步倒下。

移动栅格化后每帧为 40×40，姿态中心统一为 `(17, 27)`，共同地线为
`y = 38`，八帧横向可见像素质心的峰峰值不超过 1 像素。运行时以 12 fps
播放，`8 / 12 = 0.667` 秒，保持旧四帧 6 fps 的完整循环时长。
带红色中心点、绿色地线和洋红质心的三角色对照图保存在
`dev_assets/generated_previews/sorcerer_move_center_audit.png`，循环动图保存在
`dev_assets/generated_previews/sorcerer_move_cycle_preview.gif`。

## 可复现处理

```powershell
python C:\Users\wh\.codex\skills\.system\imagegen\scripts\remove_chroma_key.py --input <source> --out <alpha> --auto-key border --soft-matte --transparent-threshold 12 --opaque-threshold 220 --despill
python dev_tools/process_lightning_sorcerer_assets.py
python dev_tools/process_lightning_sorcerer_assets.py --check-only
```

处理脚本逐帧调用 `pixel_grid_analyzer.py`。4×2 移动源图按行优先拆成八帧，
使用 nearest 栅格化并按固定姿态中心与地线放入
`resources/texture/lightning_sorcerer_move.png`，最终为 320×40、8×1、每帧
40×40。构建同时验证横向质心峰峰值不超过 1 像素，并锁定步态相位：F2/F6
必须各只有一个落地脚段，F5 左脚落地宽度至少 5 像素且右脚尖不超过 3 像素，
F0/F2 下半身 IoU 必须低于 0.80。蓄力、施法和死亡仍各用四帧并保留在
`resources/texture/lightning_sorcerer.png` 主图中。全部运行时输出均保持二值
alpha，透明像素 RGB 为零。
