# 精英雷电术士完整重设计素材记录

当前版本不再从普通雷电术士贴图叠加紫色，也不再读取旧的紫色覆盖层。
普通版只提供角色身份、动作语义与每个 40×40 帧的稳定边界；精英版角色的
兜帽、双侧袖片、肩部、腰带和袍身内衬均由 Codex 内置 `imagegen` 重新绘制。
紫色因此属于完整服装结构，不会在帧间随机变成污渍或散点。

## 当前权威文件

- `lightning_sorcerer_elite_full_redesign_v3_imagegen_reference.png`：内置
  `imagegen` 生成的 4×4 完整主动画设计。
- `lightning_sorcerer_elite_full_redesign_v3_alpha.png`：主动画去除绿幕后的
  确定性构建输入。
- `lightning_sorcerer_elite_move_8pose_full_redesign_v4_imagegen_reference.png`：
  内置 `imagegen` 第二次逐帧姿势描摹得到的 4×2 八相位移动设计。
- `lightning_sorcerer_elite_move_8pose_full_redesign_v4_alpha.png`：移动设计去除
  绿幕后的确定性构建输入。
- `resources/texture/lightning_sorcerer_elite.png`：160×160 运行时主图。
- `resources/texture/lightning_sorcerer_elite_move.png`：320×40、八帧运行时移动
  横条。
- `resources/animation/lightning_sorcerer_elite.tres`：八帧、12 fps 的独立移动
  SpriteFrames；蓄力、攻击和死亡仍从 4×4 主图读取。

目录中的 v2、旧移动参考和旧紫色纹理参考只作为问题版本历史记录，不再参与
构建。旧的 `*_purple_texture_overlay.png` 已删除，以免再次把覆盖层误当成精英
角色设计。

## 生图方式与完整提示词

生成模式：Codex 内置 `imagegen`，`precise-object-edit`。未使用 CLI/API 回退。

主动画提示词：

```text
Use case: precise-object-edit
Asset type: production pixel-art 4x4 animation sheet for an elite Lightning Sorcerer enemy
Input images: Image 1 is the authoritative normal Lightning Sorcerer edit target and pose/layout identity; Image 2 is only a clean elite-design language reference showing coherent costume hierarchy.
Primary request: completely redesign Image 1 as a polished ELITE LIGHTNING SORCERER. This must be a genuinely new coherent costume design derived from the normal Lightning Sorcerer, not a recolor overlay and not purple marks painted on top.
Character design: retain the normal sorcerer's golden lightning crown, golden staff crystal, dark face opening, long robe silhouette and lightning-mage identity. Build a balanced elite costume with clean deep-violet garment structures: a continuous hood lining around the face, matching shoulder mantle, both sleeve panels/cuffs, a centered waist sash or clasp, and a symmetrical inner-robe panel visible between gold-trimmed outer robe halves. Purple belongs to complete garment pieces and follows anatomy; gold trim remains continuous and dominant around those pieces. Use dark near-black/brown robe shadows to separate surfaces. Design must read as intentional royal storm regalia, sharp and prestigious.
Animation/layout: preserve all sixteen pose meanings, exact 4x4 playback order, body scale, facing direction, staff hand, baseline and clear pose progression from Image 1. Row 1 four movement/idle poses; row 2 four windup poses; row 3 four attack poses; row 4 four death poses. Every frame must show the same costume topology and the same purple panels, naturally occluded by the pose rather than changing design.
Style/medium: strict native pixel art, hard square pixels, about 32px-tall character inside each logical 40x40 frame, consistent 1-pixel outline and line weight, no antialiasing, no soft brushwork.
Color palette: bright lightning gold and pale-gold highlights; deep violet #44146D, royal violet #6D27AF, tiny controlled #A944ED highlight only on the same garment edges; dark brown/near-black shadows. Flat colors, no gradients.
Scene/backdrop: perfectly flat solid #00FF00 chroma-key background, one uniform color, no shadows, no floor, no texture, no grid lines.
Composition/framing: exact 4x4 equal-cell contact sheet, one separated full character per cell, generous padding, no frame may touch another cell.
Constraints: preserve character identity and animation semantics; maintain costume consistency across all 16 frames; purple must form clean connected garment panels on both sides/center, not random pixels. No text, no labels, no watermark.
Avoid: the rejected dirty result with a purple blob concentrated on the character's left; mottled stains; random purple speckles; checker patterns; migrating highlights; asymmetrical one-sided purple mass; purple painted over arbitrary pixels; broad featureless purple silhouette; redesigning the staff, face, pose, anatomy or lightning effects; blur, dithering, gradients, antialiasing.
```

移动动画最终修订提示词：

```text
Use case: precise-object-edit
Asset type: production pixel-art eight-frame move animation sheet for the redesigned elite Lightning Sorcerer
Input images: Image 1 is the mandatory exact pose-tracing reference: normal Lightning Sorcerer eight-frame horizontal walk strip, playback order left-to-right. Image 2 is only the authoritative elite costume and color reference.
Primary request: redraw Image 1 frame by frame as the elite costume from Image 2. Treat every opaque pixel silhouette and every foot/robe/staff location in each Image 1 frame as pose geometry that must be visibly preserved. Do not invent a generic idle sequence. This is a full coherent character redraw, not a purple overlay.
Mandatory gait differences: output exactly eight visibly unique poses in playback order. F0 and F4 must have clearly different opposite leading legs and robe-hem silhouettes; F1 and F5 must be opposite down/weight-transfer poses; F2 and F6 must be opposite one-foot passing poses with one planted sole and the other leg visibly lifted/hidden; F3 and F7 must be opposite up poses. Make the lower 35 percent of the silhouette clearly alternate left/right exactly like Image 1. Crown, torso and staff may bob subtly but body root remains stable. No duplicate or near-duplicate alpha silhouettes, especially F0 versus F4.
Elite costume identity in every frame: golden lightning crown and staff crystal; dark face opening; continuous deep-violet hood lining; matching shoulder mantle; both sleeve panels/cuffs; centered waist clasp/sash; symmetrical violet inner-robe panel between gold-trimmed outer robe halves. Gold trim stays continuous and dominant. The purple topology, panel boundaries, shade placement and thickness must remain the same across all eight poses, moving only with the body and being naturally occluded.
Style: strict native pixel art, hard square pixels, consistent one-pixel dark outline, flat colors, no antialiasing, no blur, no soft brush, no dithering, no gradients. Character should downsample cleanly to about 30 pixels tall in each 40x40 runtime frame.
Palette: bright lightning gold/pale-gold highlights; deep violet #44146D and royal violet #6D27AF, with extremely sparse #A944ED only on stable garment edges; dark brown/near-black shadows.
Backdrop: perfectly flat solid #00FF00 chroma-key background, one uniform color, no shadow, floor, texture or grid lines.
Layout: exact 4 columns x 2 rows equal-cell contact sheet, ordered F0 F1 F2 F3 on row 1 then F4 F5 F6 F7 on row 2. One full separated character per cell with generous padding.
Avoid: duplicated poses; generic idle frames; collapsing opposite gait phases; identical F0/F4; random purple pixels; purple stains or one-sided blobs; checker patterns; migrating highlights; changing costume panel sizes; broad featureless purple mass; spell effects; text; labels; watermark.
```

两张透明输入都通过 imagegen 技能自带的 `remove_chroma_key.py` 去除统一绿幕，
参数为 `--auto-key border --soft-matte --transparent-threshold 12
--opaque-threshold 220 --despill`。

## 确定性构建与防闪烁契约

```powershell
python dev_tools/process_lightning_sorcerer_elite_assets.py
python dev_tools/process_lightning_sorcerer_elite_assets.py --check-only
```

脚本锁定两张透明生图输入与两张最终运行时输出的解码后 RGBA SHA-256。主动画按普通版每帧边界
缩放，以保持碰撞和画面占位；移动图按逻辑 4×2 网格读取并生成八个 40×40
相位。运行时图使用不超过 25 色的统一调色板，并删除每帧少于 3 像素的孤立
紫色组件。每帧紫色服装像素数量被测试锁定，因此散点重新出现或紫色区域突然
膨胀都会让构建失败。

移动横条同时执行八帧唯一轮廓、身体中心漂移、半周期差异、地线与脚底接触
约束。F2/F6 都必须只有一只脚着地，F5 必须显示左脚承重与分离的右脚尖，
避免角色再次退化成双脚滑行。
