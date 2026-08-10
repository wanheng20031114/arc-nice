# 稀有宝箱节点 ImageGen 素材记录

## 最终获批版本

- 生成方式：Codex 内置 ImageGen 定向编辑。
- 生成与确认日期：2026-08-10。
- 最终版本：小葱发色 `v2_xiaocong`。
- 用户确认后覆盖了早期低分辨率方案：生产图保留 ImageGen 硬 Alpha 中间稿的原生
  `1097×1434` 分辨率，不再压缩为 `122×159` 或 `366×478`，静态 UI 在场景中等比缩小。
- 完整逐字提示词、参考图角色和输入/输出 SHA-256 见 `prompt_manifest.json`。

最终图保留 v1 宝箱的三分之四视角、微启暗箱、铁制包角、黄铜锁、青白封签、旧木板和
秋叶，仅把朱漆箱板定向改为小葱发色的灰绿、鼠尾草绿与乳白高光。金币、宝石、光柱、
皇冠、华丽 UI 框、传奇页游特效和 Minecraft 式体素场景继续明确排除。

## 色键与透明处理

定向编辑原图：

- `rare_chest_tableau_imagegen_v2_xiaocong.png`
- SHA-256：`f15d7e3f05d4a8b2af698bba68983d682879c9ca9b3d9cc4bd09d8ff390d5081`
- ImageGen 原始输出：
  `C:/Users/wh/.codex/generated_images/019fe451-20f2-77b2-9257-0471f82a8195/exec-99ecc880-8248-46f3-b716-fa3ca8f2eafd.png`

使用仓库内边缘连通背景移除器生成获批硬 Alpha 中间稿：

```powershell
python dev_tools/connected_background_remover.py `
  dev_assets/source_images/rogue_rare_chest/rare_chest_tableau_imagegen_v2_xiaocong.png `
  dev_assets/source_images/rogue_rare_chest/rare_chest_tableau_alpha_connected_v2_xiaocong.png `
  --rgb-tolerance 24 --hue-tolerance 0.08 --radius 1
```

硬 Alpha 中间稿 SHA-256 为
`090d273607664d855f2fd86a233a411e37bad2ca77d274296419415f859ad009`。Alpha 仅为
0/255，透明像素 RGB 全为零，四角透明。

## 确定性生产处理

运行：

```powershell
python dev_tools/process_rare_chest_assets.py
```

脚本会先校验获批硬 Alpha 中间稿的固定 SHA-256，再执行以下唯一处理：

1. 保持原生 `1097×1434` 尺寸，不做任何缩放或裁切；
2. 将可见像素 Alpha 规范为 255，将透明像素规范为 `(0,0,0,0)`；
3. 清除残留的洋红色键边缘像素；
4. 不做调色板压缩、不抖动、不锐化、不模糊；
5. 以无损 PNG 写入
   `resources/texture/rogue_route/prepare_ahead/rare_chest_tableau.png`。

生产图 SHA-256 为
`b3cc638315da2ebc7dff4e9d96803ea700165ed6f52a8dbc18ba4561c7ab0a91`，主体边界框为
`[92, 346, 1007, 1123]`，不存在半透明像素或透明 RGB 残留。

## Godot 静态 UI 契约

- PNG 采用 lossless 导入，关闭 mipmap，保留 Alpha，并启用 `fix_alpha_border`。
- 本图不再遵循 3× 最近邻逻辑网格；在静态 UI 中应保持纵横比缩小，并在承载它的
  `TextureRect` 上显式使用 `CanvasItem.TEXTURE_FILTER_LINEAR`（场景值 `texture_filter = 2`），
  避免约三分之一非整数缩放产生跳线与锯齿。
- 不应在导入阶段设置尺寸上限或重新压缩；运行时场景只负责显示缩放。

早期 v1、20/24/28/32 色和低分辨率审批图均不是生产输入，已在最终高分辨率 v2 获批并
锁定哈希后清理。其原始 v1 SHA-256 与用途仍记录在 `prompt_manifest.json`，但仓库只保留
获批的 v2 ImageGen 原图和硬 Alpha 生产输入，避免把审批预览误当成可发布素材。
