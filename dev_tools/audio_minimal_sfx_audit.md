# 最小音效补全记录

## 本次范围

只补已有播放结构中的明确缺口，不调整现有 BGM、爆炸、拾取、敌人命中/死亡和收藏品触发音效。

- `capoo_sword_slash_light.wav`：剑客轻挥击，由 `heavy_attack.mp3` 处理得到。
- `capoo_sword_slash_heavy.wav`：骑士与精英骑士重挥击，由 `heavy_attack.mp3` 处理得到。
- `capoo_smg_fire.wav`：SMG 短促开火，替换对 AK 长开火声的复用。
- `capoo_rpg_launch.wav`：RPG 发射，替换对 AK 开火声的复用。
- `resources/audio/ui/ui_click.wav`：全局 UI 按钮点击音。

## 设计约束

- 现有混音不重做；新增素材贴合现有节点音量。
- 近战与 RPG 使用已有 `AttackAudio` 节点的 `-14 dB`。
- SMG 使用已有 `AttackAudio` 节点的 `-18 dB`，维持高频射击的低存在感。
- 爆炸仍使用 `cowboy_explosion.wav` 与 `ExplosionAudioLimiter`，因为当前爆炸响度体系已经稳定。

## 源素材

SMG/RPG 音效由仓库内既有音频派生。Slash 与 UI click 使用本次加入的源文件处理得到；处理包含极小的时间/音高偏移和响度整理，用于融入当前项目音色，不作为版权授权替代。

| 输出文件 | 源素材 | 处理意图 |
| --- | --- | --- |
| `capoo_sword_slash_light.wav` | `heavy_attack.mp3` | 裁短、轻微提速，形成剑客轻挥击版本。 |
| `capoo_sword_slash_heavy.wav` | `heavy_attack.mp3` | 裁剪、轻微音高偏移，作为骑士重挥击版本。 |
| `capoo_smg_fire.wav` | `capoo_ak47_fire.wav` | 裁成短促片段，维持已有枪声音色但减少长尾复用感。 |
| `capoo_rpg_launch.wav` | `capoo_sniper_fire.wav` | 降速、低通，形成更短的发射冲击。 |
| `resources/audio/ui/ui_click.wav` | `ui_click.wav` | 极小音高偏移、短淡出、峰值整理，交给全局 UIAudio 以 -8 dB 播放。 |

## 响度记录

`ffmpeg volumedetect` 检查结果：

| 文件 | 时长 | mean | max |
| --- | --- | --- | --- |
| `capoo_sword_slash_light.wav` | 0.30s | -17.9 dB | -1.0 dB |
| `capoo_sword_slash_heavy.wav` | 0.46s | -18.2 dB | -1.0 dB |
| `capoo_smg_fire.wav` | 0.32s | -20.1 dB | -1.0 dB |
| `capoo_rpg_launch.wav` | 0.48s | -14.3 dB | -1.0 dB |
| `resources/audio/ui/ui_click.wav` | 0.12s | -22.2 dB | -2.0 dB |

这些值会再叠加场景中的节点音量。实际播放层面，SMG 仍显著低于玩家主枪声，RPG 发射接近但低于爆炸的功能优先级，近战挥击不会盖过命中和爆炸，UI click 经 `UIAudio/ClickAudio` 以 -8 dB 播放。
