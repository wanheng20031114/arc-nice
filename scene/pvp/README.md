# Mirage / 荒漠迷城 PVP

多人大厅选择 **Mirage · CT / T 对抗** 后建房。每位玩家必须在房间中选择 CT 或 T，双方至少各有一人，房主才可开局。角色固定为 `weishidaier`，沿用原有角色动画；不会改变冒险模式中的角色与武器数值。

| 操作 | 按键 |
| --- | --- |
| 移动 / 瞄准射击 | WASD / 鼠标左键 |
| 打开、关闭武器库 | B |
| 丢出当前枪械 | G |
| 拾取附近枪械 | F |
| 换弹 | R |
| 主武器 / 副武器 | 1 / 2 |
| 查看比分 | 按住 Tab |
| 退出菜单 | Esc |

| 武器 | 身体伤害 | 爆头伤害 | 弹速 | 弹匣 | 获得方式 |
| --- | ---: | ---: | ---: | ---: | --- |
| 沙漠之鹰 | 25 | 100 | 500 px/s | 7 | 开局自带 |
| AK-47 | 20 | 100 | 500 px/s | 30 | $2700，CT/T 均可购买 |

每人 100 生命、初始 $4000；冻结购买 15 秒、交战 90 秒、回合结算 5 秒，先赢 7 回合获胜。消灭敌队赢得回合，到时由 CT 获胜。当前为团队淘汰对抗，A/B 点用于地图辨识与交战路线，未包含安放/拆除炸弹规则。友军子弹不造成伤害。购买须处于冻结阶段和本队出生区；掉落枪械保留弹药，阵亡时掉落所持枪械。幸存者保留装备，下一回合补满弹药；阵亡者重新获得沙鹰。击杀奖励 $300，胜方回合奖励 $3250、败方 $1900，余额上限 $16000。

## 场景与地图

**复刻状态（2026-09-07 检查）**：当前地图尚未达到 CS2 Mirage 复刻要求。已确认 A1 门柱堵路、下水道与 VIP/梯子房错误合并、超市与 VIP 间薄墙缺失，以及标志性掩体和美术投影不一致。详见 [复刻检查记录](../../dev_tools/mirage_fidelity_audit.md)。下方功能校验不代表复刻质量验收通过。

- 游戏入口：`res://scene/pvp/mirage_pvp.tscn`，根节点 `MpGame`。
- 可直接在 Godot 编辑器编辑的地图：`res://scene/pvp/maps/mirage_map.tscn`。
- 地图尺寸 1920 × 1600；1001 个地面瓦片，64 组墙体、25 组道具/拱柱碰撞体，23 处独立道具。两队各有 8 个安全出生 Marker，适配最多 8 人的任意选队分配。
- 地面使用原生 `TileMapLayer` / `TileSetAtlasSource`；建筑与特殊物件采用静态场景节点、`StaticBody2D`、`CollisionShape2D`、`LightOccluder2D`、`Sprite2D`。
- 已搭建 A/B、中路、猫道、VIP、梯子房、拱门、丛林、A 坡、宫殿、公寓、后巷、市场和两队出生区。现有单层地面合并造成额外贯通，窗口和公寓落差也被简化为双向台阶，连接关系仍需按原版重建。
- 不可见区域以射线对应的几何阴影变成黑灰；墙后的敌人及其名牌隐藏。小地图只显示己方。死亡后观战存活队友。

原始布局参考：[Total CS Mirage callouts](https://totalcsgo.com/callouts/mirage)。实现参考 Godot 官方 [TileSets](https://docs.godotengine.org/en/stable/tutorials/2d/using_tilesets.html) 与 [2D 灯光与阴影](https://docs.godotengine.org/en/stable/tutorials/2d/2d_lights_and_shadows.html)。所有新环境和枪械图像均由 ImageGen 生成，非从 Counter-Strike 提取的游戏资产。

美术源为 `resources/texture/pvp/mirage_surfaces.png`、`mirage_props.png`。道具源具有原生 Alpha；脚本只切帧、按 Alpha 裁透明边、对齐和无损打包，不根据 RGB 推断透明度。`dev_tools/build_mirage_map.py` 是离线场景创作工具，运行后会重写地图场景；手动编辑场景后请同步维护该创作源再重建。运行时不生成地图节点。

## 联网与校验

房间模式 ID 为 `9`，wire key 为 `mirage_pvp`，协议 **v97**。主机决定移动碰撞、射击间隔、弹药、购买、拾取、身体/头部命中与比分。500 px/s 子弹使用逐段物理射线扫掠，避免穿过薄墙或头部区域。20 Hz 状态快照经压缩、1024 字节分片和有界重组；游戏 RPC 只发给玩家，不发给中继服务 peer。

公网使用前须配套更新本仓库 `relay_servers` 的大厅 API 模式白名单、Relay NetManager RPC stub 和 v97 Relay 服务端。客户端及服务端必须使用同一版本；本次只完成代码和本地认证中继验证，没有部署远端。部署步骤见 `relay_servers/README.md`。

PVP 地图、规则、人物、武器、网络脚本与目录加入 runtime content manifest，防止不同内容构建加入同一局。修改后使用现有 `dev_tools/generate_runtime_content_manifest.gd -- --write` 重建，再用 `-- --check` 验证。

## 验证与预览

- `dev_tools/verify_mirage_lobby.tscn`：选队、角色限制、roster revision、开始门、版本准入。
- `dev_tools/verify_mirage_lan.tscn`：真实 ENet 注册及临开局换队时序。
- `dev_tools/verify_mirage_match.tscn`：两个独立进程通过正式加载器进入对局，验证买/丢/拾枪与离场；也支持本地认证 Relay。
- `scene/pvp/tests/test_mirage_pvp.gd`：真实物理扫掠、头身伤害、购买与弹药、回合、输入验证、压缩分片。
- `scene/pvp/ui/tests/pvp_ui_vision_test.tscn`：遮挡几何与射线比对、敌人隐藏、观战、购买界面、渲染和窗口缩放。
- `dev_tools/mirage_map_preview.tscn`：检查地面与障碍数量、安全出生和购买区，保存完整地图图像后自动退出。
- `dev_tools/mirage_gameplay_preview.tscn`：使用真实游戏场景保存购买层、A 点和中路画面后自动退出。

直接从编辑器运行游戏入口会启动一个本地演练场（CT 玩家和静止 T 训练靶）；正式多人对局从大厅进入。
