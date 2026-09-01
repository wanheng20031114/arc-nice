# 地下商店素材清单

本目录只保存需要悬停、按下、显示或隐藏的商店交互 UI 素材。顶部信息区复用
`rogue_route_top_bar.tscn`，商品图标读取现有收藏品与消耗品素材；完整背景直接复用
`rogue_route/underground_ruins_background.png`，小葱直接复用权威立绘
`xiaocong_fate/xiaocong_keypose_hd.png`。这里不复制、不重处理背景、柜台或人物。

正式界面由 `rogue_underground_shop_view.tscn` 直接拼装这些交互素材；购买和出售
共用同一组 4×2 authored 商品卡。专用菱形转场使用
`rogue_underground_shop_diamond_transition.gdshader`，不依赖额外位图。

## UI

| 路径 | 尺寸 | 用途 | 九宫格 / 状态约束 |
| --- | ---: | --- | --- |
| `ui/shop_panel_frame_v1.png` | 136×136 | 商店主面板与详情框 | 四边 16 px；横纵 `TILE`；硬 Alpha |
| `ui/shop_title_plaque_v1.png` | 136×32 | “地下商店”标题底板 | 左右 16 px、上下 12 px；横纵 `TILE`；不含文字 |
| `ui/shop_button_normal_v1.png` | 104×28 | 按钮普通态 | 与其余三态几何一致；样例精确 2×显示 |
| `ui/shop_button_hover_v1.png` | 104×28 | 悬停与焦点态 | 克制的细琥珀边，不改变内容位置 |
| `ui/shop_button_pressed_v1.png` | 104×28 | 按下态 | 仅表现内压，不改变外框尺寸 |
| `ui/shop_button_disabled_v1.png` | 104×28 | 禁用态 | 低饱和、相同外框尺寸 |
| `ui/shop_product_card_normal_v2.png` | 128×128 | 商品卡普通态 | 由现有背包空槽派生；售价底座已画入卡框 |
| `ui/shop_product_card_hover_v2.png` | 128×128 | 商品卡悬停与焦点态 | 由现有背包选中槽派生；售价底座几何不变 |
| `ui/shop_product_card_pressed_v2.png` | 128×128 | 商品卡按下态 | 只改变明暗，不移动售价或图标 |
| `ui/shop_product_card_disabled_v2.png` | 128×128 | 商品卡禁用态 | 去饱和；售价底座几何不变 |

商品卡状态由以下现有素材确定性派生：

- `rogue_route/inventory/inventory_slot_empty_ref_v3.png`
- `rogue_route/inventory/inventory_slot_selected_ref_v3.png`

售价底座位于卡框本体的 `y=78..108`，不再叠加突兀的半透明价格条。所有商品名称、
说明和价格均由 Godot `Label` 绘制；息壤图标与商品图标使用现有资源，商品图标以
32×32 PNG 精确 2×显示。购买页每个报价固定代表 1 件商品，不显示库存或持有数量；
出售页复用同一框体，并只在可堆叠物品上显示玩家背包中的实际数量。
素材不包含购买逻辑，也不依赖 `RunState`、网络会话或肉鸽路线根场景。

## 来源与重建

- 仅交互 UI 的 ImageGen 母稿与处理记录：
  `dev_assets/source_images/rogue_shop/underground_shop/`
- 确定性处理脚本：`dev_tools/process_underground_shop_assets.py`
- Godot 拼装原型：
  `dev_tools/visual_prototypes/underground_shop/underground_shop_preview.tscn`

处理脚本使用项目内 MIT 许可的 PerfectPixel 无 OpenCV 实现统一 UI 母稿的逻辑像素
网格，再验证并保留 ImageGen 原生 Alpha、执行硬 Alpha 规范化与限制色板；商品卡从项目现有背包槽素材派生。
精确输入哈希、输出哈希和可见包围盒会临时写入
`dev_tools/output/underground_shop/asset_build_manifest.json`。
