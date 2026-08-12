# J1 drop + bilateral slash — anchor-only independent ImageGen v6

- Mode: built-in ImageGen
- Intent: the single targeted regeneration, locking the bilateral sword-angle ladder
- Sole referenced image: `C:/Users/wh/Documents/arc-nice/dev_assets/source_images/combat_robot_main_battle_elite/combat_robot_main_battle_elite_user_approved_main_visual_20260812.png`
- Input SHA-256: `9739B978A73F471D844A3325632B2D33AC4D68627724D1BB7CB9A4283118D3F7`
- Built-in raw output: `C:/Users/wh/.codex/generated_images/019ff46f-f94d-71d0-b25d-caa1297a62d7/exec-16aa4aa5-0815-4696-87a1-4fc3157e99c1.png`
- Workspace raw copy: `C:/Users/wh/Documents/arc-nice/dev_assets/source_images/combat_robot_main_battle_elite/combat_robot_main_battle_elite_anim_j1_drop_bilateral_slash_user_anchor_only_v6_independent_imagegen.png`
- Output SHA-256: `BC4D1B46132A2F3BA54DE24F71698E3334DAF919231A820CD94D005E7E011371`
- Copy byte equality: true
- No v5 image, v3, v4, old J1 sheet, GIF, direct-native asset, or any other image was supplied.

## Full prompt

```text
Use case: stylized-concept
Asset type: raw game-character animation sprite-sheet source for human review
Input images: Image 1 is the sole approved robot identity and pixel-art design reference. Generate a new independent sprite sheet from Image 1 only; do not redesign the character.

Primary request: exactly eight complete front-facing full-body frames in a clean 4 columns × 2 rows sheet, read F1–F4 across the top and F5–F8 across the bottom. Action: airborne fall, first landing, then a bilateral mechanically synchronized twin-heavy-sword fan slash.

F1: high airborne descent; both knees tightly tucked, lower legs folded back, feet compact and unplanted; two swords raised outside the torso as perfect mirrors.
F2: lower mid-air descent; knees and lower legs still tucked; feet still unplanted; two swords remain mirrored outside the torso.
F3: immediately above ground but unmistakably still airborne. Both lower legs fold back/up, neither foot unfolds into a flat sole, and a clearly visible green band remains below both feet.
F4: first ground contact. For the first time both flat feet plant on one baseline in a wide stance. The slash has already started at this same instant: both hands are outside the torso and both swords point up-and-out, never inward across the chest.
F5–F7: both arms and swords continue one simultaneous mirrored outward rotation toward a clear wide hit.
F8: both arms and swords recover down-and-out symmetrically.

EXACT MIRROR ANGLE LADDER, measured from each hand toward its sword tip relative to the outward horizontal direction:
- F4: both swords exactly 60 degrees upward. Left vector is up-left; right vector is its exact reflected up-right twin.
- F5: both swords exactly 45 degrees upward. Left and right are exact reflected twins.
- F6: both swords exactly 20 degrees upward. Left and right are exact reflected twins.
- F7: both swords exactly horizontal, one pointing directly left and one directly right, at the same height.
- F8: both swords exactly 35 degrees downward. Left and right are exact reflected twins.
Treat every F4–F8 pose as a bilateral engineering diagram: the entire left sword, hand, wrist, forearm, elbow, and shoulder pose must be the exact horizontal reflection of the entire right side. Both grip points must have identical height and identical distance from the body center. Both sword tips must have identical height and identical distance from the center. Both blades must have identical pixel length, width, outline, and angle. Both sides must advance to the next listed angle on the same frame. No side may lead, lag, pause, or use an intermediate angle.

CHEST CLEARANCE: keep the vivid orange V core and the full dark chest plate around it completely visible in every frame. Reserve a clear empty vertical corridor over the entire central torso. No hand, arm, hilt, sword, or outline may enter this corridor. The swords never cross each other, never cross the torso centerline, never overlap the V core, and always remain outside their own side of the torso.

Identity invariants: same compact reliable robot as Image 1; narrow dark head with exactly two orange eyes visible; two separate large shoulder pods each retaining one orange rectangular light; cold steel-gray and charcoal armor; bright orange chest V; dark separated waist/hip; segmented independent legs; same matching heavy sword in each hand. Preserve proportions, palette, logical pixel-block size, thick continuous black outline, and identical overall body scale in all eight cells. Both eyes, both shoulder pods, and the complete orange V must be visible every frame.

Pixel-art contract: coarse deliberate hard-edged square pixel clusters at one consistent logical grid; crisp nearest-neighbor appearance; complete continuous outlines. No blur, antialiasing, soft brushwork, compression artifacts, motion trails, impact effects, tiny subpixel texture, or resampling damage.

Layout: eight equal independent cells with generous bright-green separation. One complete robot and exactly two complete swords per cell, with no touching, overlap, clipping, or crossing into neighboring cells. F1 highest, F2 lower, F3 lowest but still visibly airborne, F4–F8 planted on one common ground baseline. Descent is shown by vertical placement and tucked legs, not by changing character scale.

Backdrop: plain bright chroma-key green, visually equivalent to #00ff00. No scene, floor line, shadow, horizon, gradient, texture, text, labels, numbers, borders, or watermark. Do not use green inside the robot.

Output intent: one new raw 4×2 eight-frame sheet for direct human review before any crop, GIF, or native conversion.
```

## Audit note

The targeted v6 output is 1536×1024 and contains exactly eight separated connected subjects. Subject bottoms descend 343 → 393 → 443 → 465 from F1 through F4; F3 retains tucked lower legs and a visible green air gap, while F4 is the first flat-foot planted pose. F4–F8 bright-blade PCA bilateral angle differences are 0.23°, 0.77°, 0.28°, 0.38°, and 0.32° respectively. Both sword sequences advance together from up-and-out through a near-horizontal damage pose to down-and-out recovery. All orange V cores, two eyes, and both shoulder pods remain visible; swords never cross the chest.
