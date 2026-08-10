# 敌人精灵 Pipeline 参考

本文保留少量历史案例来解释技术原因；其中角色名、帧数、画布、背景色和动作编排都不是默认参数，实际任务必须重新测量和确认。

先选择且只选择一种素材来源分支：

- **确定性原生像素分支**：ImageGen 只提供结构语言，显式重建后的原生帧才是 canonical texture，任何生成图像素都不得静默进入运行素材。
- **批准后直接使用分支**：只有用户明确批准直接使用生成的 alpha/sheet 时，干净源图才可成为 canonical texture，并执行本参考中的锚点切分与导入审计。

后文提到保留 alpha 源图时，均只适用于“批准后直接使用分支”；确定性原生像素分支只借用测量与锚点方法。

## 目录

- 成功模式
- 设计阶段
- 主体锚点策略
- 背景色选择
- 动画 Sheet Prompt 契约
- 攻击动作 Prompt 复盘
- 安全框契约
- 切图策略
- 缩放与居中
- 压缩与导入
- Godot 接入 Checklist
- 什么时候重生图

## 成功模式

一次非均匀动画 sheet 替换成功的关键，是不再把整张图当成普通固定网格，而是把每一帧当成“由主体锚点控制的 sprite”：

- 直接使用分支保留干净 alpha 源图作为 canonical texture，不要过早缩小；确定性分支保留重建后的原生帧。
- 每帧独立测量。
- 从稳定主体部位提取脚底/身体锚点，不从武器、帽子、投射物或 VFX 提取。
- 所有帧使用一致的逻辑帧尺寸。
- 源图区域限制在当前源格子内，再用 `AtlasTexture.margin` 补回稳定逻辑帧。
- 根据逻辑帧锚点重新计算 `AnimatedSprite2D` 的 scale 和 position。
- 用带锚点十字线的预览图先发现串帧、裁切和主体漂移。

这是直接使用非均匀 sheet 时的默认锚点模式，不是所有低分辨率敌人的固定素材来源。

## 设计阶段

先生成一个高质量单帧样例，再生成动画 sheet。检查：

- 敌人在游戏实际缩放下是否可读。
- 轮廓是否足够清楚，不依赖过细细节。
- 主体颜色是否能和服装、武器、发光、投射物、背景分离。
- 武器、帽子、背包、法杖、尾巴、法阵等可以伸出 idle 外形，但主体必须作为尺寸基准。
- 当前设计是否支持需要的动作幅度，例如移动、蓄力、攻击、受击、死亡。

单帧样例弱时直接重生图，不要因为已经有 sheet 就勉强进入处理阶段。

## 主体锚点策略

用最稳定的身体部位做锚点来源。不要直接用整帧 alpha bbox，因为攻击特效、法杖、尾巴会拉偏中心。

推荐顺序：

1. 已知主体颜色范围内的最大连通块。
2. 无法稳定分离主体颜色时，使用最大 alpha 连通块。
3. 只有在没有更好方案时，才 fallback 到整帧可见 alpha bbox。

对脚底对齐的敌人，锚点 x 使用主体连通块水平中心，锚点 y 使用主体连通块底部。主体锚点和身体中心应该在每个逻辑帧中的相对位置一致。

## 背景色选择

优先要求内置 `image_gen` 输出透明 alpha。必须使用纯色 chroma 背景时，先根据样例图测量主体调色板，再选和主体、描边、武器、VFX、服装、眼睛距离最远的颜色。

常见风险：

- 绿色不适合绿色眼睛、毒、草木、绿色魔法。
- 洋红不适合粉色/紫色魔法、花瓣、红蓝高光。
- 青色不适合蓝色主体、冰、浅色魔法。
- 黄色不适合金边、火焰、闪电。
- 红色不适合火焰、红眼、危险 VFX。

纯色背景 prompt 要明确：

```text
纯平 [背景色] 背景，无渐变、无阴影、无接触阴影、无背景发光、无纹理、无文字、无边框。
```

抠背景时只移除从图像边缘连通到背景色的像素，不要全局删除所有相似颜色；否则会误伤眼睛、装饰和特效内部颜色。

## 动画 Sheet Prompt 契约

只有单帧样例通过后才生成动画 sheet。帧数、行列、每行动作都由当前资源需求决定，不存在通用固定帧数，也不存在固定 `2x3`、`3x2`、`4x4`。例如某个 attack 可以是 6 帧，某个 idle 可以是 8 帧，某个技能也可以更多；关键是动作连贯、可循环或能自然结束。

必须写清楚：

- 实际需要的网格行列，例如 `[列数]列 x [行数]行`。
- 实际动作名和行/列语义，例如 `idle`、`move`、`attack`、`death`，或中文 `站立`、`横向移动`、`举杖攻击`、`死亡`。
- 每格一个完整帧，帧之间不重叠、不串格。
- 同一镜头距离，同一主体人物像素大小，同一身体高度和宽度。
- 主体脚底锚点和身体中心在每格中的相对位置一致。
- 武器、尾巴、帽子、法杖、道具、VFX 可以移动或扩大，但不能改变主体缩放。
- 每格必须给所有可见元素留安全框，不能裁掉尾巴、法杖、帽子、武器或特效。
- 透明 alpha，或测量后选择的纯平 chroma 背景。

通用中文模板：

```text
使用内置 image_gen 生成像素风敌人动画源图。
[列数]列 x [行数]行，每格一个完整帧，透明 alpha 或纯平 [背景色] 背景。
动作：[描述本次需要的动作节奏和每帧变化]。
所有帧使用同一镜头距离，同一主体人物像素大小，同一身体高度和身体宽度。
主体脚底锚点和身体中心在每个格子的相对位置必须一致，不要主体漂移。
武器、法杖、尾巴、帽子、道具和技能特效可以移动并扩大，但必须完整留在当前格子的安全框里，不得被裁切。
每格周围保留足够空白安全边距，帧之间不重叠、不串格。
硬边像素、无背景阴影、无渐变背景、无文字、无边框。
```

如果必须使用英文 prompt，也要保留等价约束：`same body pixel size`, `same body center`, `same feet/body anchor`, `large safe padding inside every cell`, `props and VFX fully inside the cell`, `no cropped tail/staff/effects`。

## 攻击动作 Prompt 复盘

某次攻击源图风格可用，是因为 prompt 成功约束了角色身份、武器动作、攻击节奏和跨帧一致性。该任务采用 6 帧，只是因为当次动作适合 6 个关键姿势，不应写成通用规则。

暴露的问题：

- 使用绿色 chroma 背景，而角色眼睛也有绿色，增加了过度抠图风险。
- 约束了整帧可见范围，但没有足够强调 body-only anchor，导致法杖和 VFX 容易拉偏 bbox。
- 没有明确要求每帧主体身体高度/宽度一致。
- 没有明确要求每个源格子给尾巴、法杖、挥击弧光、花瓣特效留安全框。

以后 boss 动作应使用“主体锁定”的表达：主体是尺寸和锚点不变量，道具和特效围绕主体运动，并被更大的安全框完整容纳。

## 安全框契约

安全框是当前源格子或逻辑帧中刻意保留的空白边距，它和主体居中是两件事：

- 主体中心和脚底锚点保持稳定。
- 主体像素大小保持稳定。
- 道具、尾巴、武器、帽子、VFX 可以超出 idle 外形。
- 扩展元素仍必须完整位于当前格子内。
- 如果动作道具碰到格子边缘，应重生图、扩大源格子，或扩大最终逻辑帧。

至少测量：

- `body_anchor_in_cell` 的帧间漂移。
- `body_bbox` 宽高的帧间变化。
- `alpha_bbox` 到源格子边缘的距离。
- 整帧可见像素量和主体连通块像素量。

边缘警告不一定让已经手工确认的 alpha sheet 作废，但对新生成素材来说，通常应该先重生图再接入。

## 切图策略

不要相信粗网格本身已经足够；粗网格只负责给出每帧的大致源格子。

每格处理顺序：

1. 按粗网格裁出当前源格子。
2. 找可见 alpha bbox。
3. 找主体连通块 bbox。
4. 计算全局主体锚点。
5. 围绕锚点创建目标逻辑帧。
6. 验证目标逻辑帧能包含当前格子的所有可见像素。
7. 如果逻辑帧跨到相邻源格子，就把实际 `AtlasTexture.region` 限制在当前源格子内，再用 `margin` 还原统一逻辑尺寸。

`.tres` 推荐模式：

```text
[sub_resource type="AtlasTexture" id="AtlasTexture_move_0"]
atlas = ExtResource("1_texture")
region = Rect2(actual_left, actual_top, actual_width, actual_height)
margin = Rect2(offset_x_inside_logical_frame, offset_y_inside_logical_frame, missing_width, missing_height)
filter_clip = true
```

所有帧的 `region.size + margin.size` 应等于统一逻辑帧尺寸。

## 缩放与居中

切图后，从逻辑帧计算 Godot 场景里的 transform。

定义：

- `logical_frame_size`：`AtlasTexture.get_size()` 的结果，包含 margin。
- `body_anchor`：逻辑帧里的稳定主体锚点。
- `sprite_scale`：Godot 里的 `AnimatedSprite2D.scale`。
- `desired_world_anchor`：主体锚点应该落到的场景局部位置。

公式：

```text
local_anchor_offset = (body_anchor - logical_frame_size / 2) * sprite_scale
sprite_position = desired_world_anchor - local_anchor_offset
```

如果碰撞体居中且下沿是脚底，`desired_world_anchor.y` 通常接近碰撞体半高。最终用锚点十字预览和 Godot smoke test 验证。

## 压缩与导入

像素图规则：

- 只使用无损或 nearest-neighbor 操作。
- 不要在最终切图策略确定前缩放源图。
- 直接使用分支优先保留干净 alpha 源图；确定性分支以批准后的原生重建图为 canonical texture。
- 只做无损 PNG 优化。
- 除非人工检查过，否则不要做会改变 alpha 边缘的 palette conversion。
- Godot 小像素精灵默认关闭 mipmaps，除非项目有明确缩放 pipeline。
- 沿用项目既有 `texture_filter` 约定。

## Godot 接入 Checklist

每次替换敌人或 boss 资源时：

- 保留已有 `Texture2D` 和 `SpriteFrames` UID。
- 动画名必须和配置、场景脚本一致；不要从示例里照搬固定动画名。
- 优先直接编辑 `.tscn` / `.tres`，不要把视觉节点动态生成塞进运行时代码。
- PNG 改动后重新导入 Godot。
- 跑聚焦 smoke test。
- 根据影响面检查：
  - texture size；
  - animation names；
  - frame counts；
  - `AtlasTexture` logical frame size；
  - region 是否在 atlas 内；
  - `AnimatedSprite2D.position`；
  - `AnimatedSprite2D.scale`。
- 最后检查并清理验证用 Godot 进程，尤其是 `--headless`、`--check-only`、`--import`。

## 什么时候重生图

这些情况优先重生图：

- 主体缩放在帧间明显变化。
- 多帧道具或特效被裁切。
- 背景严重污染描边。
- chroma 色出现在眼睛、主体细节或关键特效里。
- 同一格里出现多个姿势重叠。
- 游戏实际缩放下不可读。

这些情况适合代码处理：

- 美术质量好，但格子位置不均匀。
- 主体锚点稳定，但粗网格不准。
- 背景能用边缘连通 chroma 移除。
- 只需要轻微 despill 或 alpha 清理。
