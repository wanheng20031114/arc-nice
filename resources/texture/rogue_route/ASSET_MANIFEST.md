# Rogue Route 素材清单

本目录收录本轮已接入或可直接复用的 Rogue 路线美术素材；路线逻辑、场景和 UI 布局由对应的场景与脚本维护。

## 顶栏图标

- `hud/hud_core_life_v4.png`：塔防核心生命；蓝心为主体，外围仅保留窄铁边
- `hud/hud_action_points_v4.png`：行动力；单只青蓝矿工靴
- `hud/hud_light_stone_v1.png`：全队共享的光石
- `../xirang_icon.png`：复用已有息壤水晶图标

核心生命与行动力为 40×40 透明 PNG；光石为原生 32×32，息壤为原生 37×37。顶部 HUD 统一给它们 40px 对齐格，但使用 `STRETCH_KEEP_CENTERED` 与最近邻过滤，绝不把小图做非整数放大；均未使用平滑插值。

## 当前选定节点（V3）

- 普通作战 B：`nodes/node_normal_combat_b_ref_v3.png`
- 紧急作战 A：`nodes/node_emergency_combat_a_ref_v3.png`
- 神奇遭遇 B：`nodes/node_magical_encounter_b_ref_v3.png`
- 黑市 B：`nodes/node_black_market_b_ref_v3.png`
- 馈赠 B：`nodes/node_gift_b_ref_v3.png`
- 遗址物资：`nodes/node_wilderness_resource_ref_v3.png`
- 空节点：`nodes/node_empty_ref_v4.png`（沿用中性环并补足深色内芯）

这些均为 128×128 的完整、无文字节点状态；没有在节点下方烘焙名称。图标改为参考图的高辨识度居中像素符号：青蓝交叉剑、红橙交叉剑、青蓝问号、紫金店铺、暖金馈赠箱和青蓝遗址物资车，保留了原先的类别配色与语义。

## 当前节点环与状态（V3）

- `nodes/containers/node_ring_neutral_ref_v3.png`：带四向承力块、双层深铁边与弧形分段的空心中性环
- `nodes/containers/node_ring_active_ref_v3.png`：同一环的窄金边激活态
- `nodes/node_normal_combat_b_active_ref_v3.png`：普通作战 B 的完整激活态示例

两个环均为 128×128 透明 PNG，中心保持透明，便于之后叠加任意节点图标；空节点直接使用中性环即可。激活环不是另画的不同几何，而是以同一结构的金边状态制作，避免选中时圆形错位。

## 当前连接件（V3）

- `links/route_link_horizontal_ref_v3.png`：64×24 横向窄轨，含连续方形铆接节
- `links/route_link_vertical_ref_v3.png`：同一横轨无插值旋转得到的 24×64 竖轨
- `links/route_link_junction_ref_v3.png`：40×40 方形交汇接头
- `links/route_link_terminal_ref_v3.png`：40×40 端部接头
- `links/route_link_cross_ref_v3.png`：完整四向连接素材，供固定交叉布局直接使用

本套连接件只用于水平、垂直的方格路线，不再使用任意斜线。圆环的四向承力块与轨道端头均可对齐，视觉结构对应最新参考图。

## 底部背包栏（V3）

- `inventory/inventory_slot_empty_ref_v3.png`：厚深铁双层外框的空物品格
- `inventory/inventory_slot_selected_ref_v3.png`：相同外框的细琥珀金选中态
- `inventory/inventory_bag_frame_ref_v3.png`：与物品格同构的空背包按钮框
- `inventory/inventory_bag_icon_ref_v3.png`：从已认可背包图中保留的背包图标
- `inventory/inventory_bag_button_ref_v3.png`：新外框与保留背包图标的组合按钮
- `inventory/inventory_scroll_left_ref_v3.png`、`inventory/inventory_scroll_right_ref_v3.png`：同材质的横向滚动按钮
- `inventory/inventory_bar_backplate_ref_v4.png`：450×128 完整深色金属栏底板
- `inventory/inventory_bar_center_tile_ref_v4.png`：192×128 可横向重复的中段底板；右侧两列已与左侧匹配，避免拼接处出现透明缝

V3 背包栏改用参考图中的归纳式深色金属矩形轮廓：外框、内凹槽、顶底横梁共享同一套材质语言；背包图案本身保留。

## 版本保留原则

本目录只保留当前 V3/V4 的选定素材和可直接复用的模块化连接件。已替代的 V2、A/B/C 候选图标以及生成过程文件均不入库；后续美术调整应以这里的现行成品为基准，而非回退到旧候选。

## 已清理的中间产物

为避免将无法直接运行或复用的过程文件带入版本库，已移除一次性路线预览，以及生成、去色和裁切阶段的原始工作图。后续需要追溯美术选择时，以本目录中实际接入的 V3/V4 成品 PNG、场景引用和提交历史为准。

所有 V3 最终 PNG 均通过平铺/透明边缘检查，以最近邻整理；未使用平滑缩放。
