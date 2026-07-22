# 雷电术士角色素材

雷电术士角色使用 `imagegen` 的参考图引导模式生成。角色动作沿用火焰/寒冰术士的体型与四行动画契约，识别色改为金黄、亮黄和淡黄；闪电链本身是运行时纯特效，不画进角色图集。

## 文件

- `lightning_sorcerer_move_imagegen_source.png`：移动四帧的绿色背景原图。
- `lightning_sorcerer_windup_imagegen_source.png`：蓄力四帧的绿色背景原图。
- `lightning_sorcerer_attack_imagegen_source.png`：施法四帧的绿色背景原图。
- `lightning_sorcerer_death_imagegen_source.png`：死亡四帧的绿色背景原图。
- 对应的 `*_alpha.png`：通过 imagegen 技能的 `remove_chroma_key.py` 去除绿色背景后的透明源图。

## 生成方式

四个动作分别生成，均参考现有 `frost_sorcerer.png`、`fire_sorcerer.png`、对应寒冰术士动作源图，以及前一步已接受的雷电术士角色图。提示词共同约束如下：

- 单行、严格四帧、完整角色、互不重叠并共用脚底线；
- 紧凑兜帽术士造型、面向右侧、金黄兜帽和袍服、深棕黑阴影、闪电水晶法杖；
- 真像素画、硬边像素块、无抗锯齿、无文字、无格线；
- 背景为纯绿色 `#00FF00`，角色内不使用绿色；
- 移动只做步态起伏；蓄力仅允许法杖附近少量电火花；攻击不绘制长闪电或投射物；死亡按四帧逐步倒下。

## 可复现处理

```powershell
python C:\Users\wh\.codex\skills\.system\imagegen\scripts\remove_chroma_key.py --input <source> --out <alpha> --auto-key border --soft-matte --transparent-threshold 20 --opaque-threshold 100 --spill-cleanup --force
python dev_tools/process_lightning_sorcerer_assets.py
python dev_tools/process_lightning_sorcerer_assets.py --check-only
```

处理脚本逐帧调用 `pixel_grid_analyzer.py`，以 nearest 重采样到现有火焰术士逐帧透明边界，最终输出 `resources/texture/lightning_sorcerer.png`：160×160、4×4、每帧 40×40、二值 alpha、透明像素 RGB 为零。
