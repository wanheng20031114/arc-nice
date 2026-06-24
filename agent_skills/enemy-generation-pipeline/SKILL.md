---
name: enemy-generation-pipeline
description: 生成、处理、切分并接入高质量 Godot 敌人精灵资源。Use for image generation, enemy sprite sheets, Capoo-style variants, alpha/chroma-key cleanup, SpriteFrames, AtlasTexture slicing, AnimatedSprite2D centering, and Godot enemy scene visual integration.
---

# 敌人生成 Pipeline

## 核心原则

把敌人美术当成可复现的资源 pipeline，而不是一次性的图片修补。优先使用多轮生图、可测量的大图分析、明确的每帧主体锚点，以及 Godot 原生的 `SpriteFrames` / `AtlasTexture` / `AnimatedSprite2D` 资源结构。

动手前先读项目根目录的 `AGENTS.md`。需要新的位图敌人素材时，优先使用 `imagegen` 生图工具。处理像素图、裁空白、分析网格时，优先考虑项目已有工具，例如 `dev_tools/pixel_crop_tool.py`、`dev_tools/pixel_grid_analyzer.py`，以及本 skill 的 `scripts/analyze_enemy_sheet.py`。

## 工作流

1. 明确敌人资源契约。

   先确认敌人定位、可读轮廓、主体颜色、携带道具、VFX、动画名、场景路径、贴图路径、`SpriteFrames` 路径、碰撞形状和投射物依赖。在本项目中，新增或调整节点时优先直接编辑 `.tscn` 和 `.tres`，不要把视觉节点动态生成逻辑塞进运行时代码。

2. 先生成单个成功样例。

   不要一开始就生成整张动画大图。先生成一个代表性姿势，背景必须干净。检查它在游戏内尺寸下是否可读、主体颜色是否容易分离、道具轮廓是否清楚，以及这个设计是否能在多帧动画中保持稳定比例。单样例弱时，重新生图，不要急着用代码补救。

3. 用测量选择背景色。

   能拿到 alpha 就优先用 alpha。必须使用纯色背景时，选择和主体、描边、武器、发光、投射物颜色距离最大的纯平 chroma 色。抠图时优先做边缘连通的背景移除和 despill，不要全局删除所有相似颜色像素。

4. 单样例成立后再生成动画大图。

   生图 prompt 要明确网格行列、稳定镜头、稳定主体大小、每格完整角色、纯平背景、背景无阴影、格子之间不重叠。行语义要直接写清楚，例如 `move`、`windup`、`attack`、`death`。

5. 切分前先分析。

   运行 `scripts/analyze_enemy_sheet.py` 或项目内专用分析脚本。检查整图尺寸、alpha/chroma bbox、每格 bbox、主色、主体锚点，以及固定切片区域是否会裁掉当前帧或吃到相邻帧。

6. 按主体锚点切分，不要只信粗网格。

   这次 Capoo mage 成功的关键是每帧都使用稳定的“主体脚点”锚点。优先从最大主体颜色连通块推导锚点，失败时再用 alpha bbox fallback。不同动画帧必须保持统一的逻辑帧尺寸和主体锚点。

7. 保持主体大小一致。

   除非动画设计本身需要变大变小，否则每帧的主体大小应一致。帽子、武器、法杖、披风、攻击特效可以围绕主体移动或扩展，但主体本身不应在帧之间缩放。

8. 紧密大图使用 `AtlasTexture.margin`。

   如果固定 `region` 会吃到相邻格子的像素，就把实际 `region` 裁到当前源格子内部，再用 `AtlasTexture.margin` 补回统一逻辑帧尺寸，并设置 `filter_clip = true`。这样能避免串帧碎片，同时保持 `AnimatedSprite2D` 的中心稳定。

9. 显式计算 `AnimatedSprite2D` 中心点。

   对居中的 `AnimatedSprite2D`，使用：

   ```text
   local_anchor_offset = (body_anchor - logical_frame_size / 2) * sprite_scale
   sprite_position = desired_world_anchor - local_anchor_offset
   ```

   小体型敌人的 `desired_world_anchor` 通常是碰撞框下沿中心附近。最终要用带十字锚点的预览图和 Godot smoke test 验证。

10. 在 Godot 中验证并清理。

   PNG 变化后要重新导入，运行聚焦 smoke test。结束前检查验证用 Godot 进程是否残留，尤其是带 `--headless`、`--check-only`、`--import` 参数的进程；不要误关用户正常打开的编辑器。

## 生图 Prompt 要点

质量优先时允许多次调用生图工具：

- 第 1 轮：生成单个设计样例。
- 第 2 轮：如果轮廓、颜色或道具弱，修正单样例。
- 第 3 轮：样例认可后，再生成完整动画 sheet。
- 后续轮次：坏行、坏姿势、坏变体优先重生，不要过度修补失败素材。

动画 sheet prompt 可使用类似约束：

```text
pixel art enemy sprite sheet, transparent alpha or pure flat [chosen color] background,
4 columns x 4 rows, rows are move / windup / attack / death,
same camera distance, same body scale, body centered consistently in each cell,
complete character in every cell, no cropped props, no overlap between cells,
clean hard pixel edges, no background shadows, no text
```

## 图像处理要点

像素图只使用无损或 nearest-neighbor 操作。不要用 bilinear/bicubic 缩放。避免有损 PNG 压缩。Godot 导入小像素精灵时，除非项目有明确缩放需求，否则保持 mipmaps 关闭。

移除 chroma 背景时：

- 使用从图像边缘连通传播的背景移除，避免删除角色内部同色细节。
- 移除背景后处理边缘 despill。
- 在 `tmp/` 下保存 alpha debug 图，方便检查。
- 如果已有干净 alpha 大图，优先直接使用 alpha 源图。

写入 `SpriteFrames` 时：

- 替换现有资源时保留已有 UID。
- 动画名保持和敌人配置兼容。
- 用确定性的 `.tres` 生成逻辑，保证资源可复现。
- 加 smoke test 覆盖帧数、贴图尺寸、`AtlasTexture` 逻辑尺寸、region 边界、场景 scale 和 position。

## 资源

- 需要详细 checklist 和 Capoo mage 经验复盘时，读 `references/enemy-sprite-pipeline.md`。
- 需要分析新生成的大图时，运行 `scripts/analyze_enemy_sheet.py --help`，它可以检查主色、背景候选、每格主体锚点，以及 anchor-based `AtlasTexture` region/margin。
