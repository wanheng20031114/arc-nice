# 本机 CS2 Mirage 官方雷达参考

审计日期：2026-09-07。此目录仅供本次地图忠实度审查，受上级 `.gdignore` 排除；图像没有加入游戏运行时资源。

## 已核实的安装版本

- Steam App ID：730 / Counter-Strike 2。
- Steam manifest：`E:/SteamLibrary/steamapps/appmanifest_730.acf`。
- `buildid` 与 `TargetBuildID`：**25000182**。
- 安装根：`E:/SteamLibrary/steamapps/common/Counter-Strike Global Offensive`。
- 正式 Source 2 地图：`game/csgo/maps/de_mirage.vpk`，178,972,399 字节，VPK v2，757 个目录项。
- 地图 VPK SHA-256：`dc8f0d125014b00218582d0ab9a2f684638fa17054924fba34d07c2ef479e268`。

Steam 目录中的旧 `csgo/` 下另有第三方/历史 Mirage 文件；这些没有作为本次原版参考。

## 官方雷达与坐标配置

主目录索引 `game/csgo/pak01_dir.vpk` 是 VPK v2，共 135,686 个文件项。

| 资源 | VPK 目录内路径 | 数据所在分包 | 字节数 |
| --- | --- | --- | ---: |
| 官方 overview 配置 | `resource/overviews/de_mirage.txt` | `game/csgo/pak01_022.vpk` | 640 |
| 官方雷达纹理 | `panorama/images/overheadmaps/de_mirage_radar_psd.vtex_c` | `game/csgo/pak01_137.vpk` | 177,297 |

使用本目录 `inspect_installed_vpk.py` 只读解析索引和精确读取这两个条目，并对读取结果核验 VPK CRC32。雷达纹理 CRC32 是 `cecbb316`，SHA-256 是 `00171ef3ee89d12038db8341c05c3adcba1d78e9d86371b7586bca921547d6a4`。

- 原配置：`de_mirage_original_overview.txt`。
- 原编译纹理：`de_mirage_radar_psd.vtex_c`。
- 解码图：**`de_mirage_original_radar.png`**，**1024 × 1024 RGBA**。
- PNG SHA-256：`c8032f6c83ffca63c0a20ebdcc598a0e1aa618efd746e381e2db26f33a4a964f`。

配置原值：`pos_x=-3230`，`pos_y=1713`，`scale=5.00`，`rotate=0`，`zoom=0`。
归一化定位标记：CTSpawn `(0.28, 0.70)`，TSpawn `(0.87, 0.36)`，bombA `(0.54, 0.76)`，bombB `(0.23, 0.28)`。
Inset：left `0.135`，top `0.08`，right `0.105`，bottom `0.08`。

解码图保持原图尺寸、颜色、透明度和方向，没有旋转、裁剪、手工描绘或重建。可直接用来审查轮廓、走廊宽度、连接顺序、A/B 区域与出生点位置；它本身是二维雷达，不能独立证明桥下、窗台和箱体的全部三维可通行关系。

## 地图元数据（仅列目录，没有提取整套地图）

`de_mirage.vpk` 内已确认存在：

- `maps/de_mirage.vmap_c`（96,848 字节）。
- `maps/de_mirage.nav`（469,448 字节）。
- `maps/de_mirage/world.vwrld_c`（1,946 字节）。
- `maps/de_mirage/world_physics.vmdl_c`（3,491,176 字节）。
- `maps/de_mirage/entities/default_ents.vents_c`（68,979 字节）。

目录证据在 `cs2_mirage_map_assets.json`；主包 Mirage 相关条目在 `cs2_pak_mirage_assets.json`。

## 解码工具与只读边界

使用 [Source 2 Viewer / ValveResourceFormat](https://github.com/ValveResourceFormat/ValveResourceFormat) 官方仓库的 **20.0** release CLI；它是独立开源项目，**并非 Valve 官方发布的工具**。

- [官方 CLI 文档](https://s2v.app/ValveResourceFormat/guides/command-line.html) 明确提供单纹理解码、指定输入/输出路径，不需要启动游戏。
- [20.0 release](https://github.com/ValveResourceFormat/ValveResourceFormat/releases/tag/20.0)，发布时间 2026-08-17。
- 官方 `cli-windows-x64.zip`，52,735,867 字节，SHA-256：`d32ab327b8bbb42a2528866afb03bb582bdb779d0005488da32b90292afd3ff5`；下载校验与 GitHub release asset 的官方 digest 完全一致。
- CLI 仅接收已提取到本 audit 目录的 `.vtex_c` 为输入，输出也在本目录。没有使用会在 VPK 旁写入文件的 `--vpk_cache` 参数。
- CLI 正常退出，退出码 0；日志为 `vrf_decode.log` / `vrf_decode_errors.log`。临时下载压缩包和解压工具在解码后移除，没有安装到系统。
- 没有写入 Steam/CS2 目录，没有启动 CS2，没有提取整套地图为成品使用。

Decoded for this audit with [Source 2 Viewer](https://s2v.app/) ([ValveResourceFormat](https://github.com/ValveResourceFormat/ValveResourceFormat)).
