# 靴子收藏品图标源文件

这里保留轮滑鞋与加力轮子的原始生图、抠图 Alpha 和逐格构建清单。最终图标只允许由高分辨率 Alpha 直接生成，禁止先缩到 32×32。

## 构建结果

- `roller_skates_v2_alpha.png`：`approximate`，置信度 `0.828`，主体 `22×23` 逻辑格。
- `power_wheel_v2_alpha.png`：`approximate`，置信度 `0.991`，主体 `24×17` 逻辑格。
- 两者最长边均不超过收藏品图标预算 `26` 格。

## 构建命令

```powershell
python dev_tools/build_collectible_icon_from_alpha.py dev_assets/source_images/collectible_boots/roller_skates_v2_alpha.png resources/texture/collectibles/roller_skates.png --alpha-threshold 24 --min-subject-size 12 --max-subject-size 26 --manifest-path dev_assets/source_images/collectible_boots/roller_skates_v2_build.json
python dev_tools/build_collectible_icon_from_alpha.py dev_assets/source_images/collectible_boots/power_wheel_v2_alpha.png resources/texture/collectibles/power_wheel.png --alpha-threshold 24 --min-subject-size 12 --max-subject-size 26 --manifest-path dev_assets/source_images/collectible_boots/power_wheel_v2_build.json
```

## 生图约束

- 内置 imagegen；绿色纯色抠图背景。
- 主体必须由同一全局方格组成，每格为统一色块。
- 轮滑鞋目标不超过 `22×23` 格；加力轮子目标不超过 `24×17` 格。
- 纯黑一格外轮廓、扁平色块、无抗锯齿、无小于一格的细节。
- 网格分析为 `native_or_unknown`、置信度低于 `0.65` 或最长边超过 `26` 时，必须重绘或重新生成。
