# Rogue 物资节点 ImageGen 记录

本批素材使用 Codex 内置 ImageGen 逐张生成，没有使用 CLI 模型。第一版因像素量过高且
带有传统页游式华丽边框被否决。随后分别尝试了自然岩洞与遗址物资场景；用户最终明确选定
遗址物资场景版本。透明素材先在纯色
`#ff00ff` 背景上生成，再使用系统 ImageGen 技能附带的
`remove_chroma_key.py` 去除背景。生产图由
`dev_tools/process_rogue_supply_assets.py` 确定性构建。
共用卡框在系统色键工具处理后仍有一圈边缘色键，因此最终中间稿改由仓库内
`dev_tools/connected_background_remover.py` 直接从 ImageGen 原图生成，只清除与画布边缘
连通的洋红背景，未改动木框主体。完整确定性命令为：

```powershell
python dev_tools/connected_background_remover.py `
  dev_assets/source_images/rogue_supply/supply_choice_panel_shared_imagegen.png `
  dev_assets/source_images/rogue_supply/supply_choice_panel_shared_alpha.png `
  --rgb-tolerance 24 --hue-tolerance 0.08 --radius 1
```

处理脚本和连通背景移除脚本的 SHA-256 同时记录在 `asset_manifest.json`。

## 物资场景

- 输出：`resources/texture/rogue_route/supply/supply_tableau.png`
- 用途：物资节点左侧 `390×520` 画框中的遗址物资场景。
- 最终提示词要点：用户明确选定的遗址物资场景，包含石砌洞口、普通木制矿车、木箱、圆润布袋、
  绳索、镐与少量青蓝矿石；清晰中等大小像素簇、有限色阶，无华丽边框、人物或具体奖励符号；
  纯 `#ff00ff` 色键背景。
- 像素量：先压至 `122×159` 逻辑画布，再最近邻 3 倍显示到 `366×477`，底部补 1px 透明行。

## 共用选项卡背景

- 输出：`resources/texture/rogue_route/supply/supply_choice_panel.png`。
- 用途：右侧三张随机奖励卡共用同一背景；纹理本身不暗示具体奖励，选中、禁用和投票状态
  继续由 Godot 原生节点表达。
- 最终提示词要点：温暖朴素的农场生活 RPG 像素 UI；蜂蜜色木框、深可可描边和浅奶油纸面，
  不复制任何商业游戏的具体边框纹样，不含文字、奖励图标或华丽装饰。
- 像素量：色键移除并人工核对后压至 `130×37`、最多 12 色，再最近邻 4 倍成为原生
  `520×148`。

## 会飞的信封

- 输出：`resources/texture/collectibles/flying_envelope.png`
- 用途：32×32 特殊收藏品图标。
- 最终提示词要点：用户明确认可的第一版——奶油色封口信封、两侧短而清楚的天蓝色像素翅膀、
  深色硬轮廓与青色封蜡；无文字、邮戳、阴影或额外粒子；纯 `#ff00ff` 色键背景。
- 像素量：人工核对后由 `pixel_crop_tool.py` 直接压至 `32×32`，主体 28×14，保留更自然的
  翅膀层次。

## 网格与透明处理

早期 ImageGen 源图的逻辑网格置信度不足 `0.65`；最终共用卡框源图经色键处理后的近似网格
置信度超过 `0.7`。所有生产素材仍由确定性脚本按显式逻辑画布做最近邻缩放与有限色板处理。
透明像素 RGB 归零、Alpha 仅 0/255。
详细输入与输出 SHA-256 见 `asset_manifest.json`。
