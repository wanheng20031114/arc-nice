# 荧光坑洞图像生成记录

## 运行时目标

- Rouge 神奇遭遇左侧插图。
- 最终素材为 `48×48 RGBA` 透明像素图，在 `336×336` 区域使用 nearest 放大。
- 画面只呈现被青绿荧光矿脉与苔藓照亮的遗址岩坑；不得出现人物、物品、文字、UI、辐射标识或任何提前泄露事件结果的元素。

## ImageGen 母图提示词

```text
Create a square pixel-art game encounter illustration of an ancient ruined rock pit viewed from a slightly elevated three-quarter angle. The pit is deep and ominous, with broken dark masonry and jagged stone around the rim. Cyan-teal fluorescent mineral veins and faint bioluminescent moss illuminate the inner walls and the darkness below. Use a restrained dark blue-gray and cyan-green palette, chunky deliberate pixel clusters, crisp hard edges, strong readable silhouette, and no antialiasing. Center one compact pit as the only subject on a perfectly uniform pure magenta (#ff00ff) chroma-key background. No cast shadow outside the subject. No people, creatures, items, treasure, text, UI, radiation symbols, or narrative outcome clues.
```

## 简化修订提示词

```text
Edit this into a much simpler, production-ready 48-pixel-style sprite. Keep only one compact circular ancient stone pit: a dark broken masonry rim, a deep black-blue center, and a few broad cyan/teal glowing mineral and moss clusters inside the rim. Remove tiny speckles, thin isolated pixels, wispy effects, exterior rubble, and unnecessary texture. Make every contour and highlight use large consistent pixel clusters that can be reduced on an approximately 23-pixel source grid without losing shape. Preserve the perfectly uniform pure magenta (#ff00ff) background, centered composition, hard pixel edges, no antialiasing, and no external cast shadow. No people, creatures, items, treasure, text, UI, radiation symbols, or outcome clues.
```

## 处理产物

- `fluorescent_pit_imagegen_magenta.png`：初版 ImageGen 母图。
- `fluorescent_pit_v2_imagegen_magenta.png`：简化后的 ImageGen 母图。
- `fluorescent_pit_v2_alpha_hd.png`：洋红键色去背后的高分辨率中间稿。
- `resources/texture/rogue_encounter/fluorescent_pit.png`：经网格分析、整格裁切及安全压缩得到的最终运行时素材。

最终采用简化稿；网格分析约为 23 px，置信度 0.858。最终主体边界为 40×34 逻辑像素，画布为 48×48。
