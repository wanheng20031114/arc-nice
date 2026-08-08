# Dual Grid Terrain Sources

- These resources were imported from the `cometARC_cardgame` project. Its authoring toolchain procedurally generated the grass, soil, and water textures from the reference repository's dual-grid atlas coordinate contract and rounded mask shape.
- `meadow_grass_dual_grid_atlas_16.png`, `tilled_soil_dual_grid_atlas_16.png`, `sky_blue_water_dual_grid_atlas_16.png`, and `terrain_dual_grid_placeholders_16.png` are the 16 px companion set matching the reference repository scale.
- `scene/game_modes/tower_defense/test_arenas/terrain/dual_grid_paint_demo.tscn` uses the 16 px set by default so it matches the existing arcnice terrain scale.
- `meadow_grass_dual_grid_atlas_32.png`, `tilled_soil_dual_grid_atlas_32.png`, `sky_blue_water_dual_grid_atlas_32.png`, and `terrain_dual_grid_placeholders_32.png` are retained as the compatible 32 px companion set.
- `sky_blue_water_reference_tile_32.png` is the approved single-tile water style reference used to tune the static water atlas.
- `gray_metal_floor_reference_tile_32.png` is the approved imagegen-authored single-tile gray mechanical-floor source used for the dual-grid atlases; its outer seam is removed deterministically so repeated metal cells do not show a grid line.
- `gray_metal_floor_dual_grid_atlas_16.png` and `gray_metal_floor_dual_grid_atlas_32.png` are the approved reference tile composited through the stored binary alpha masks without additional texture or edge treatment.
- `grass_flower_details_16.png`, `grass_flower_details_32.png`, `dirt_clay_details_16.png`, and `dirt_clay_details_32.png` are transparent six-variant terrain-detail atlases derived from the source project's imagegen references.
- `terrain_dual_grid_tileset_16.tres` and `terrain_dual_grid_tileset_32.tres` are the official TileSet resources for these atlases.
- `dual_grid_alpha_masks_16.png` is the binary black/white alpha channel extracted from `dual-grid-tilemap-system-godot/Assets/DemoGrassTiles.png`; `dual_grid_alpha_masks_32.png` is its exact nearest-neighbour 2x companion for authoring 32 px terrain atlases.
- The atlas coordinate contract follows `dual-grid-tilemap-system-godot`: a 4x4 atlas where the all-empty mask is represented by `Vector2i(-1, -1)` rather than a visible tile.
- The copied mask is MIT-licensed by jess-hammer (2024). The required license text is preserved in `LICENSE-dual-grid-tilemap-system-godot.txt`.
