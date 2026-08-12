# M1 user-anchor-only regeneration lineage (v4 -> v5)

## Execution contract

- Mode: built-in ImageGen.
- Intent: generation with a single identity/style reference; the reference is not an edit target.
- Sole referenced image: `C:/Users/wh/Documents/arc-nice/dev_assets/source_images/combat_robot_main_battle_elite/combat_robot_main_battle_elite_user_approved_main_visual_20260812.png`
- Input SHA-256: `9739b978a73f471d844a3325632b2d33ac4d68627724d1bb7cb9a4283118d3f7`
- No previous M1 sheet, GIF, direct-native draft, derived image, or other image was supplied to either call.
- No crop, resize, chroma-key removal, GIF assembly, native conversion, atlas build, or runtime publication was performed on these raw outputs.

## v4 base generation

- Built-in output: `C:/Users/wh/.codex/generated_images/019ff46f-d1ed-79f3-9549-676368ec82e8/exec-a078f9ae-b0f6-45be-8345-2088a6780e44.png`
- Workspace raw copy: `combat_robot_main_battle_elite_animation_m1_user_anchor_only_v4_upper_body_y_base_imagegen.png`
- Output SHA-256: `6441b48319956d2b437301075d201eeef8ef26288bf07110c6d66a12168bbaa9`
- Audit result: rejected as the recommendation. F4 and F7 visibly lower the head/chest/hip assembly, so the upper-body world-Y invariant failed.

### Exact v4 prompt

```text
Use case: stylized-concept
Asset type: raw pixel-art animation pose sheet for a game character approval gate
Input images: Image 1 is the sole identity, proportions, color, silhouette, equipment, and pixel-style reference. Generate a new pose sheet from it; do not redesign the robot.
Primary request: Create one independent M1 “heavy alternating stomp walk” animation sheet with exactly eight distinct full-body poses arranged as a clean 4-column × 2-row grid, read left-to-right across the top row and then left-to-right across the bottom row.
Scene/backdrop: perfectly flat, single-color solid #00ff00 chroma-key green across the entire sheet. No gradient, texture, vignette, glow, floor, shadows, panel borders, dividers, labels, numbers, or text.
Subject invariants: Preserve the exact approved main robot identity from Image 1 in every cell: front-facing compact reliable main-battle robot; narrow dark head with two orange eyes; orange V-shaped chest core; two tall independent shoulder pods with one orange square each; separated torso and legs connected by a dark hip/piston axis; cold steel gray, charcoal black, white sword edges, and orange accents; two matching broad heavy swords, one firmly held in each hand. Keep both arms, both hands, both complete swords, head, chest core, shoulder pods, hip axis, both legs, and both feet fully visible in every frame. Both sword tips remain below and outside the body, pointing forward/downward as in the reference, never crossing behind the robot. No missing, fused, duplicated, or extra parts.
Animation action, eight frames: F1 neutral wide heavy stance with both feet planted. F2 shift weight onto the right leg while the left knee bends and the left foot begins to lift. F3 left foot clearly lifted for a heavy step while the right leg supports the robot. F4 left foot lands in a weighty stomp and both knees absorb the impact. F5 centered recovery with both feet planted. F6 mirror the action: weight on the left leg while the right knee bends and right foot lifts. F7 right foot lands in a weighty stomp and both knees absorb the impact. F8 return to exactly the same neutral pose, scale, registration, sword angle, and silhouette as F1.
Critical motion constraint: The stomp is expressed by alternating leg bend, foot lift, foot placement, and weight transfer—not by bouncing the upper body. Across all eight cells, keep the entire head, shoulder line, orange chest V, torso block, and dark hip-axis at essentially the same world-space vertical height, with at most one coarse visual logical pixel of vertical variance. The pelvis and torso must look locked to a stable horizontal guide. No frame may make the robot jump, squat its whole body, rise, sink, bob, or change overall character scale. Feet move relative to the stable pelvis; the pelvis does not follow the feet up and down.
Style/medium: authentic coarse native-looking pixel art, hard square pixel clusters, crisp stair-stepped continuous black outer contour, no blur, no painterly shading, no smooth vector curves, no antialias haze, no resampling artifacts, no thin broken edges. Use consistent logical-pixel block size within each pose and across all eight poses.
Composition/framing: landscape sheet, equal-size implicit cells, one centered robot per cell, same facing and same scale. Generous pure-green gutters on every side of every pose; silhouettes and sword tips must not touch neighboring poses, image edges, or each other across cell boundaries. Each full pose must be individually extractable.
Constraints: exactly eight poses and exactly one robot per cell; F1 and F8 visually identical; preserve identity and equipment; stable upper-body Y registration; no text, arrows, effects, dust, impact marks, speed lines, extra props, watermark, or logo.
Avoid: any upper-body vertical bounce; different character scales; cropped heads, feet, arms, shoulder pods, hands, or sword tips; adjacent-frame contact; green reflected into the robot; gradient green; frame boxes; multiple views; side or back view; weapon morphing; extra blades; swords switching hands; silhouette drift.
```

## v5 targeted regeneration

- Built-in output: `C:/Users/wh/.codex/generated_images/019ff46f-d1ed-79f3-9549-676368ec82e8/exec-e1aa59cd-7f0d-4592-8a75-5a9a652c84f3.png`
- Workspace raw copy: `combat_robot_main_battle_elite_animation_m1_user_anchor_only_v5_upper_body_y_targeted_regen_imagegen.png`
- Output SHA-256: `cae3be91dec538c919c7337eeb53f189316592891c084cf90f911ecdd7301942`
- Targeted change: remove upper-body vertical bob while retaining leg-only alternating stomp motion.
- Audit result: recommended raw candidate. All eight connected subjects are complete and separated. Within each row, the detected subject top and bottom are identical except F7 top is one physical source pixel lower; the torso-to-ground height remains visually stable. F1 and F8 return to the same neutral silhouette closely. The generated green remains green-dominant but is not numerically a single exact `#00ff00` value; this is recorded as a raw-source limitation and was not locally altered.

### Exact v5 prompt

```text
Use case: stylized-concept
Asset type: raw pixel-art animation pose sheet for a game character approval gate
Input images: Image 1 is the sole identity, proportions, equipment, palette, silhouette, and pixel-style reference. It is the only reference. Generate a new M1 sheet from Image 1 and do not redesign the robot.
Primary request: Create exactly eight full-body frames of an M1 heavy alternating stomp walk, arranged in a clean landscape 4-column × 2-row sheet, read left-to-right on the top row and then left-to-right on the bottom row.
Single targeted correction and highest priority: LOCK THE UPPER BODY TO ONE HORIZONTAL REGISTRATION LINE. In all eight cells, the top of the head, shoulder-pod tops, orange V chest-core center, waist seam, and dark hip-axis pivot must each sit at the same vertical sheet coordinate within its cell, with no visible vertical shift. Treat the head, shoulders, chest, waist, and hip pivot as a rigid sprite layer copied at exactly the same height into every cell. Maximum allowed variation is one single coarse square logical pixel. The robot must never become shorter or taller in any frame. No upper-body bob, bounce, dip, squat, rise, jump, scale change, or impact compression. Do not lower the torso for landing frames. Animate ONLY the legs below the fixed hip pivot plus tiny horizontal weight cues in the legs.
Scene/backdrop: one perfectly flat uniform solid #00ff00 chroma-key green covering the whole sheet. No gradient, lighting variation, texture, floor, shadow, glow, vignette, frame boxes, borders, dividers, labels, numbers, or text.
Subject invariants: faithfully preserve the approved robot from Image 1 in every frame: front view; narrow dark head with two orange eyes; orange V-shaped chest core; two tall separate shoulder pods with one orange square on each; torso separated from legs by a dark hip/piston axis; cold steel gray and charcoal armor; two matching broad heavy swords with white edges and orange grip details, one continuously held in each hand. Every cell must contain the complete head, both shoulder pods, chest, hip axis, both arms, both hands, two complete swords including both tips, both legs, and both feet. No missing, fused, duplicated, extra, or morphed parts. Both swords remain down and outward at nearly identical angles in all frames; they never cross behind the body.
Eight-frame leg-only motion plan: F1 neutral wide stance, both feet planted. F2 fixed pelvis, right leg supports while left knee bends and left foot just starts to lift. F3 fixed pelvis, left knee lifts higher while right leg remains extended to the same ground. F4 fixed pelvis at the original height, left leg extends down into a planted stomp while the right knee bends just enough to transfer weight—do not compress or lower the body. F5 fixed pelvis, centered recovery with both feet planted. F6 mirror F2: left leg supports and right knee bends, right foot begins to lift. F7 fixed pelvis, right leg extends down into a planted stomp while left knee bends just enough for weight transfer—do not compress or lower the body. F8 must reproduce F1’s neutral stance, character scale, upper-body registration, sword angles, and silhouette as closely as possible.
Style/medium: authentic coarse pixel art made of deliberate hard square logical-pixel clusters; crisp continuous stair-stepped black outline; clear chunky highlights; no blur, no antialias haze, no painterly texture, no smooth vector curves, no broken edges, and no resampling artifacts. Keep one consistent logical-pixel block size across every pose.
Composition/framing: eight equal implicit cells; exactly one same-scale robot centered per cell. Use a single imaginary horizontal guide through all eight chest cores and a single identical hip-axis height in all eight cells. Leave large pure-green gutters around every pose and between all neighboring poses. No sword tip, arm, foot, head, or shoulder may touch another cell’s subject or any outer image edge.
Constraints: exactly eight frames; stable rigid upper-body Y registration is more important than exaggerated motion; leg articulation alone communicates stepping; F1 and F8 match; same front-facing camera; no effects, dust, impact marks, speed lines, arrows, props, text, logo, or watermark.
Avoid: any frame with a lower or higher head/chest/hip; crouched whole-body poses; unequal subject scales; cropped parts; adjacent-frame contact; weapon switching or morphing; extra blades; gradient green; green spill inside the robot; side or rear views.
```
