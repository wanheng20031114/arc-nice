extends RefCounted
class_name RuntimeContentCatalog

## 多人运行时可加载内容的显式信任根。ID 一经提交便不随路径移动自动变化；
## 生产代码只可加载目录值，不得加载调用方传入的字符串。
const MAX_ID_LENGTH := 128
const MAX_RESOURCE_PATH_LENGTH := 256

const ENEMY_ID_TO_PATH: Dictionary = {
	"enemy.capoo_ak47": "res://resources/config/enemies/capoo_ak47.tres",
	"enemy.capoo_knight_elite": "res://resources/config/enemies/capoo_knight_elite.tres",
	"enemy.capoo_knight": "res://resources/config/enemies/capoo_knight.tres",
	"enemy.capoo_mage": "res://resources/config/enemies/capoo_mage.tres",
	"enemy.capoo_rpg": "res://resources/config/enemies/capoo_rpg.tres",
	"enemy.capoo_smg": "res://resources/config/enemies/capoo_smg.tres",
	"enemy.capoo_sniper": "res://resources/config/enemies/capoo_sniper.tres",
	"enemy.capoo_swordsman": "res://resources/config/enemies/capoo_swordsman.tres",
	"enemy.cardboard_monster_large": "res://resources/config/enemies/cardboard_monster_large.tres",
	"enemy.cardboard_monster": "res://resources/config/enemies/cardboard_monster.tres",
	"enemy.combat_robot_drone_operator_elite": "res://resources/config/enemies/combat_robot_drone_operator_elite.tres",
	"enemy.combat_robot_drone_operator": "res://resources/config/enemies/combat_robot_drone_operator.tres",
	"enemy.combat_robot_elite": "res://resources/config/enemies/combat_robot_elite.tres",
	"enemy.combat_robot_gunner_elite": "res://resources/config/enemies/combat_robot_gunner_elite.tres",
	"enemy.combat_robot_gunner": "res://resources/config/enemies/combat_robot_gunner.tres",
	"enemy.combat_robot_main_battle_elite": "res://resources/config/enemies/combat_robot_main_battle_elite.tres",
	"enemy.combat_robot_ninja_elite": "res://resources/config/enemies/combat_robot_ninja_elite.tres",
	"enemy.combat_robot_ninja": "res://resources/config/enemies/combat_robot_ninja.tres",
	"enemy.combat_robot_shield_bearer_elite": "res://resources/config/enemies/combat_robot_shield_bearer_elite.tres",
	"enemy.combat_robot_shield_bearer": "res://resources/config/enemies/combat_robot_shield_bearer.tres",
	"enemy.combat_robot": "res://resources/config/enemies/combat_robot.tres",
	"enemy.fire_sorcerer_elite": "res://resources/config/enemies/fire_sorcerer_elite.tres",
	"enemy.fire_sorcerer": "res://resources/config/enemies/fire_sorcerer.tres",
	"enemy.frost_sorcerer_elite": "res://resources/config/enemies/frost_sorcerer_elite.tres",
	"enemy.frost_sorcerer": "res://resources/config/enemies/frost_sorcerer.tres",
	"enemy.lightning_sorcerer_elite": "res://resources/config/enemies/lightning_sorcerer_elite.tres",
	"enemy.lightning_sorcerer": "res://resources/config/enemies/lightning_sorcerer.tres",
	"enemy.linglan_boss": "res://resources/config/enemies/linglan_boss.tres",
	"enemy.slime_fire": "res://resources/config/enemies/slime_fire.tres",
	"enemy.slime_frost": "res://resources/config/enemies/slime_frost.tres",
	"enemy.slime_golden": "res://resources/config/enemies/slime_golden.tres",
	"enemy.slime_green": "res://resources/config/enemies/slime_green.tres",
	"enemy.slime": "res://resources/config/enemies/slime.tres",
	"enemy.stone_eroded_capoo_ak47": "res://resources/config/enemies/stone_eroded_capoo_ak47.tres",
	"enemy.stone_eroded_capoo_knight_elite": "res://resources/config/enemies/stone_eroded_capoo_knight_elite.tres",
	"enemy.stone_eroded_capoo_knight": "res://resources/config/enemies/stone_eroded_capoo_knight.tres",
	"enemy.stone_eroded_capoo_mage": "res://resources/config/enemies/stone_eroded_capoo_mage.tres",
	"enemy.stone_eroded_capoo_rpg": "res://resources/config/enemies/stone_eroded_capoo_rpg.tres",
	"enemy.stone_eroded_capoo_smg": "res://resources/config/enemies/stone_eroded_capoo_smg.tres",
	"enemy.stone_eroded_capoo_sniper": "res://resources/config/enemies/stone_eroded_capoo_sniper.tres",
	"enemy.stone_eroded_capoo_swordsman": "res://resources/config/enemies/stone_eroded_capoo_swordsman.tres",
	"enemy.stone_eroded_slime_fire": "res://resources/config/enemies/stone_eroded_slime_fire.tres",
	"enemy.stone_eroded_slime_frost": "res://resources/config/enemies/stone_eroded_slime_frost.tres",
	"enemy.stone_eroded_slime_golden": "res://resources/config/enemies/stone_eroded_slime_golden.tres",
	"enemy.stone_eroded_slime_green": "res://resources/config/enemies/stone_eroded_slime_green.tres",
	"enemy.stone_eroded_slime": "res://resources/config/enemies/stone_eroded_slime.tres",
	"enemy.stone_eroded_yuanshi_insect_basic": "res://resources/config/enemies/stone_eroded_yuanshi_insect_basic.tres",
	"enemy.stone_eroded_yuanshi_insect_bomber": "res://resources/config/enemies/stone_eroded_yuanshi_insect_bomber.tres",
	"enemy.stone_eroded_yuanshi_insect_fast": "res://resources/config/enemies/stone_eroded_yuanshi_insect_fast.tres",
	"enemy.stone_eroded_yuanshi_insect_fire_ranged": "res://resources/config/enemies/stone_eroded_yuanshi_insect_fire_ranged.tres",
	"enemy.stone_eroded_yuanshi_insect_green_shell": "res://resources/config/enemies/stone_eroded_yuanshi_insect_green_shell.tres",
	"enemy.stone_eroded_yuanshi_insect_guardian": "res://resources/config/enemies/stone_eroded_yuanshi_insect_guardian.tres",
	"enemy.stone_eroded_yuanshi_insect_purple_bomber": "res://resources/config/enemies/stone_eroded_yuanshi_insect_purple_bomber.tres",
	"enemy.stone_eroded_yuanshi_insect_shell": "res://resources/config/enemies/stone_eroded_yuanshi_insect_shell.tres",
	"enemy.stone_golem_elite": "res://resources/config/enemies/stone_golem_elite.tres",
	"enemy.stone_golem": "res://resources/config/enemies/stone_golem.tres",
	"enemy.yuanshi_insect_basic": "res://resources/config/enemies/yuanshi_insect_basic.tres",
	"enemy.yuanshi_insect_bomber": "res://resources/config/enemies/yuanshi_insect_bomber.tres",
	"enemy.yuanshi_insect_fast": "res://resources/config/enemies/yuanshi_insect_fast.tres",
	"enemy.yuanshi_insect_fire_ranged": "res://resources/config/enemies/yuanshi_insect_fire_ranged.tres",
	"enemy.yuanshi_insect_green_shell": "res://resources/config/enemies/yuanshi_insect_green_shell.tres",
	"enemy.yuanshi_insect_guardian": "res://resources/config/enemies/yuanshi_insect_guardian.tres",
	"enemy.yuanshi_insect_purple_bomber": "res://resources/config/enemies/yuanshi_insect_purple_bomber.tres",
	"enemy.yuanshi_insect_shell": "res://resources/config/enemies/yuanshi_insect_shell.tres",
}

const PICKUP_ID_TO_PATH: Dictionary = {
	"item.buildings.building_agave_cannon": "res://resources/config/buildings/building_agave_cannon.tres",
	"item.buildings.building_attack_speed_tower": "res://resources/config/buildings/building_attack_speed_tower.tres",
	"item.buildings.building_bamboo_mortar": "res://resources/config/buildings/building_bamboo_mortar.tres",
	"item.buildings.building_corn_machine_gun": "res://resources/config/buildings/building_corn_machine_gun.tres",
	"item.buildings.building_excavator": "res://resources/config/buildings/building_excavator.tres",
	"item.buildings.building_grape_arc_tower": "res://resources/config/buildings/building_grape_arc_tower.tres",
	"item.buildings.building_hydrangea_rain_tower": "res://resources/config/buildings/building_hydrangea_rain_tower.tres",
	"item.buildings.building_life_tower": "res://resources/config/buildings/building_life_tower.tres",
	"item.buildings.building_oak_warehouse": "res://resources/config/buildings/building_oak_warehouse.tres",
	"item.buildings.building_orange_charging_tower": "res://resources/config/buildings/building_orange_charging_tower.tres",
	"item.buildings.building_plant_cultivation_center": "res://resources/config/buildings/building_plant_cultivation_center.tres",
	"item.buildings.building_planting_base": "res://resources/config/buildings/building_planting_base.tres",
	"item.buildings.building_research_center": "res://resources/config/buildings/building_research_center.tres",
	"item.buildings.building_simple_fence": "res://resources/config/buildings/building_simple_fence.tres",
	"item.buildings.building_speed_tower": "res://resources/config/buildings/building_speed_tower.tres",
	"item.buildings.building_stone_mill": "res://resources/config/buildings/building_stone_mill.tres",
	"item.buildings.building_vegetation_stake": "res://resources/config/buildings/building_vegetation_stake.tres",
	"item.buildings.building_water_collector": "res://resources/config/buildings/building_water_collector.tres",
	"item.buildings.building_wood_processing_station": "res://resources/config/buildings/building_wood_processing_station.tres",
	"item.collectibles.collectible_admin_doll": "res://resources/config/collectibles/collectible_admin_doll.tres",
	"item.collectibles.collectible_alchemist_vial": "res://resources/config/collectibles/collectible_alchemist_vial.tres",
	"item.collectibles.collectible_amethyst": "res://resources/config/collectibles/collectible_amethyst.tres",
	"item.collectibles.collectible_apple": "res://resources/config/collectibles/collectible_apple.tres",
	"item.collectibles.collectible_apprentice_scroll": "res://resources/config/collectibles/collectible_apprentice_scroll.tres",
	"item.collectibles.collectible_archer_sigil": "res://resources/config/collectibles/collectible_archer_sigil.tres",
	"item.collectibles.collectible_archer": "res://resources/config/collectibles/collectible_archer.tres",
	"item.collectibles.collectible_auto_loader": "res://resources/config/collectibles/collectible_auto_loader.tres",
	"item.collectibles.collectible_banana": "res://resources/config/collectibles/collectible_banana.tres",
	"item.collectibles.collectible_basketball": "res://resources/config/collectibles/collectible_basketball.tres",
	"item.collectibles.collectible_battle_standard": "res://resources/config/collectibles/collectible_battle_standard.tres",
	"item.collectibles.collectible_blink_crystal": "res://resources/config/collectibles/collectible_blink_crystal.tres",
	"item.collectibles.collectible_blood_trident": "res://resources/config/collectibles/collectible_blood_trident.tres",
	"item.collectibles.collectible_blue_mushroom": "res://resources/config/collectibles/collectible_blue_mushroom.tres",
	"item.collectibles.collectible_blue_quartz": "res://resources/config/collectibles/collectible_blue_quartz.tres",
	"item.collectibles.collectible_bone_needle": "res://resources/config/collectibles/collectible_bone_needle.tres",
	"item.collectibles.collectible_campfire_coal": "res://resources/config/collectibles/collectible_campfire_coal.tres",
	"item.collectibles.collectible_candle_stub": "res://resources/config/collectibles/collectible_candle_stub.tres",
	"item.collectibles.collectible_capacity_spring": "res://resources/config/collectibles/collectible_capacity_spring.tres",
	"item.collectibles.collectible_celestial_ring": "res://resources/config/collectibles/collectible_celestial_ring.tres",
	"item.collectibles.collectible_charged_jade_pendant": "res://resources/config/collectibles/collectible_charged_jade_pendant.tres",
	"item.collectibles.collectible_chipped_ruby": "res://resources/config/collectibles/collectible_chipped_ruby.tres",
	"item.collectibles.collectible_clay_totem": "res://resources/config/collectibles/collectible_clay_totem.tres",
	"item.collectibles.collectible_copper_gear": "res://resources/config/collectibles/collectible_copper_gear.tres",
	"item.collectibles.collectible_copper_sword": "res://resources/config/collectibles/collectible_copper_sword.tres",
	"item.collectibles.collectible_crystal_compass": "res://resources/config/collectibles/collectible_crystal_compass.tres",
	"item.collectibles.collectible_dragon_heart": "res://resources/config/collectibles/collectible_dragon_heart.tres",
	"item.collectibles.collectible_drum_magazine": "res://resources/config/collectibles/collectible_drum_magazine.tres",
	"item.collectibles.collectible_dual_ammo_chamber": "res://resources/config/collectibles/collectible_dual_ammo_chamber.tres",
	"item.collectibles.collectible_dual_row_feeder": "res://resources/config/collectibles/collectible_dual_row_feeder.tres",
	"item.collectibles.collectible_echo_drum": "res://resources/config/collectibles/collectible_echo_drum.tres",
	"item.collectibles.collectible_eclipse_amulet": "res://resources/config/collectibles/collectible_eclipse_amulet.tres",
	"item.collectibles.collectible_ember_leaf": "res://resources/config/collectibles/collectible_ember_leaf.tres",
	"item.collectibles.collectible_emerald": "res://resources/config/collectibles/collectible_emerald.tres",
	"item.collectibles.collectible_extended_magazine": "res://resources/config/collectibles/collectible_extended_magazine.tres",
	"item.collectibles.collectible_flame_trident": "res://resources/config/collectibles/collectible_flame_trident.tres",
	"item.collectibles.collectible_flying_envelope": "res://resources/config/collectibles/collectible_flying_envelope.tres",
	"item.collectibles.collectible_fox_coin": "res://resources/config/collectibles/collectible_fox_coin.tres",
	"item.collectibles.collectible_frost_crystal": "res://resources/config/collectibles/collectible_frost_crystal.tres",
	"item.collectibles.collectible_frost_totem": "res://resources/config/collectibles/collectible_frost_totem.tres",
	"item.collectibles.collectible_glacier_orb": "res://resources/config/collectibles/collectible_glacier_orb.tres",
	"item.collectibles.collectible_glass_marble": "res://resources/config/collectibles/collectible_glass_marble.tres",
	"item.collectibles.collectible_goat_horn": "res://resources/config/collectibles/collectible_goat_horn.tres",
	"item.collectibles.collectible_gold_apple": "res://resources/config/collectibles/collectible_gold_apple.tres",
	"item.collectibles.collectible_gold_wine_cup": "res://resources/config/collectibles/collectible_gold_wine_cup.tres",
	"item.collectibles.collectible_gray_gem": "res://resources/config/collectibles/collectible_gray_gem.tres",
	"item.collectibles.collectible_guardian_badge": "res://resources/config/collectibles/collectible_guardian_badge.tres",
	"item.collectibles.collectible_gun_oil": "res://resources/config/collectibles/collectible_gun_oil.tres",
	"item.collectibles.collectible_heavy_gauntlet": "res://resources/config/collectibles/collectible_heavy_gauntlet.tres",
	"item.collectibles.collectible_herbal_bundle": "res://resources/config/collectibles/collectible_herbal_bundle.tres",
	"item.collectibles.collectible_high_speed_loader": "res://resources/config/collectibles/collectible_high_speed_loader.tres",
	"item.collectibles.collectible_hunters_bow": "res://resources/config/collectibles/collectible_hunters_bow.tres",
	"item.collectibles.collectible_iron_dagger": "res://resources/config/collectibles/collectible_iron_dagger.tres",
	"item.collectibles.collectible_ironwood_seed": "res://resources/config/collectibles/collectible_ironwood_seed.tres",
	"item.collectibles.collectible_jade_fish": "res://resources/config/collectibles/collectible_jade_fish.tres",
	"item.collectibles.collectible_kingslayer_blade": "res://resources/config/collectibles/collectible_kingslayer_blade.tres",
	"item.collectibles.collectible_leaf_cloak": "res://resources/config/collectibles/collectible_leaf_cloak.tres",
	"item.collectibles.collectible_life_crystal": "res://resources/config/collectibles/collectible_life_crystal.tres",
	"item.collectibles.collectible_life_ring": "res://resources/config/collectibles/collectible_life_ring.tres",
	"item.collectibles.collectible_lucky_gem": "res://resources/config/collectibles/collectible_lucky_gem.tres",
	"item.collectibles.collectible_magic_ring": "res://resources/config/collectibles/collectible_magic_ring.tres",
	"item.collectibles.collectible_medieval_shield": "res://resources/config/collectibles/collectible_medieval_shield.tres",
	"item.collectibles.collectible_mirror_shield": "res://resources/config/collectibles/collectible_mirror_shield.tres",
	"item.collectibles.collectible_moon_amulet": "res://resources/config/collectibles/collectible_moon_amulet.tres",
	"item.collectibles.collectible_moon_pin": "res://resources/config/collectibles/collectible_moon_pin.tres",
	"item.collectibles.collectible_moss_agate": "res://resources/config/collectibles/collectible_moss_agate.tres",
	"item.collectibles.collectible_nine_eleven": "res://resources/config/collectibles/collectible_nine_eleven.tres",
	"item.collectibles.collectible_obsidian_key": "res://resources/config/collectibles/collectible_obsidian_key.tres",
	"item.collectibles.collectible_oil_lamp": "res://resources/config/collectibles/collectible_oil_lamp.tres",
	"item.collectibles.collectible_oracle_cube": "res://resources/config/collectibles/collectible_oracle_cube.tres",
	"item.collectibles.collectible_orange": "res://resources/config/collectibles/collectible_orange.tres",
	"item.collectibles.collectible_pebble_shield": "res://resources/config/collectibles/collectible_pebble_shield.tres",
	"item.collectibles.collectible_philosopher_stone": "res://resources/config/collectibles/collectible_philosopher_stone.tres",
	"item.collectibles.collectible_phoenix_feather": "res://resources/config/collectibles/collectible_phoenix_feather.tres",
	"item.collectibles.collectible_physical_ring": "res://resources/config/collectibles/collectible_physical_ring.tres",
	"item.collectibles.collectible_pocket_anvil": "res://resources/config/collectibles/collectible_pocket_anvil.tres",
	"item.collectibles.collectible_power_ring": "res://resources/config/collectibles/collectible_power_ring.tres",
	"item.collectibles.collectible_power_wheel": "res://resources/config/collectibles/collectible_power_wheel.tres",
	"item.collectibles.collectible_prism_lens": "res://resources/config/collectibles/collectible_prism_lens.tres",
	"item.collectibles.collectible_pure_charge_crystal": "res://resources/config/collectibles/collectible_pure_charge_crystal.tres",
	"item.collectibles.collectible_quick_feather": "res://resources/config/collectibles/collectible_quick_feather.tres",
	"item.collectibles.collectible_quick_load_belt": "res://resources/config/collectibles/collectible_quick_load_belt.tres",
	"item.collectibles.collectible_rain_bead": "res://resources/config/collectibles/collectible_rain_bead.tres",
	"item.collectibles.collectible_red_mushroom": "res://resources/config/collectibles/collectible_red_mushroom.tres",
	"item.collectibles.collectible_river_shell": "res://resources/config/collectibles/collectible_river_shell.tres",
	"item.collectibles.collectible_roller_skates": "res://resources/config/collectibles/collectible_roller_skates.tres",
	"item.collectibles.collectible_royal_goblet": "res://resources/config/collectibles/collectible_royal_goblet.tres",
	"item.collectibles.collectible_ruby_crown": "res://resources/config/collectibles/collectible_ruby_crown.tres",
	"item.collectibles.collectible_ruby": "res://resources/config/collectibles/collectible_ruby.tres",
	"item.collectibles.collectible_runed_book": "res://resources/config/collectibles/collectible_runed_book.tres",
	"item.collectibles.collectible_rusty_helm": "res://resources/config/collectibles/collectible_rusty_helm.tres",
	"item.collectibles.collectible_sakura": "res://resources/config/collectibles/collectible_sakura.tres",
	"item.collectibles.collectible_salt_charm": "res://resources/config/collectibles/collectible_salt_charm.tres",
	"item.collectibles.collectible_sapphire_ring": "res://resources/config/collectibles/collectible_sapphire_ring.tres",
	"item.collectibles.collectible_silver_mask": "res://resources/config/collectibles/collectible_silver_mask.tres",
	"item.collectibles.collectible_simple_magazine": "res://resources/config/collectibles/collectible_simple_magazine.tres",
	"item.collectibles.collectible_spark_bottle": "res://resources/config/collectibles/collectible_spark_bottle.tres",
	"item.collectibles.collectible_speed_ring": "res://resources/config/collectibles/collectible_speed_ring.tres",
	"item.collectibles.collectible_spellblade": "res://resources/config/collectibles/collectible_spellblade.tres",
	"item.collectibles.collectible_steel_longsword": "res://resources/config/collectibles/collectible_steel_longsword.tres",
	"item.collectibles.collectible_stone_tablet": "res://resources/config/collectibles/collectible_stone_tablet.tres",
	"item.collectibles.collectible_storm_core": "res://resources/config/collectibles/collectible_storm_core.tres",
	"item.collectibles.collectible_sun_brooch": "res://resources/config/collectibles/collectible_sun_brooch.tres",
	"item.collectibles.collectible_sun_moon_relic": "res://resources/config/collectibles/collectible_sun_moon_relic.tres",
	"item.collectibles.collectible_swift_boot": "res://resources/config/collectibles/collectible_swift_boot.tres",
	"item.collectibles.collectible_swift_crystal": "res://resources/config/collectibles/collectible_swift_crystal.tres",
	"item.collectibles.collectible_tarnished_medal": "res://resources/config/collectibles/collectible_tarnished_medal.tres",
	"item.collectibles.collectible_thorn_shield": "res://resources/config/collectibles/collectible_thorn_shield.tres",
	"item.collectibles.collectible_thunder_crown": "res://resources/config/collectibles/collectible_thunder_crown.tres",
	"item.collectibles.collectible_thunder_crystal": "res://resources/config/collectibles/collectible_thunder_crystal.tres",
	"item.collectibles.collectible_thunder_god_idol": "res://resources/config/collectibles/collectible_thunder_god_idol.tres",
	"item.collectibles.collectible_tianshi_stake": "res://resources/config/collectibles/collectible_tianshi_stake.tres",
	"item.collectibles.collectible_tin_ring": "res://resources/config/collectibles/collectible_tin_ring.tres",
	"item.collectibles.collectible_tiny_bell": "res://resources/config/collectibles/collectible_tiny_bell.tres",
	"item.collectibles.collectible_titan_helm": "res://resources/config/collectibles/collectible_titan_helm.tres",
	"item.collectibles.collectible_topaz_chip": "res://resources/config/collectibles/collectible_topaz_chip.tres",
	"item.collectibles.collectible_topaz": "res://resources/config/collectibles/collectible_topaz.tres",
	"item.collectibles.collectible_training_arrow": "res://resources/config/collectibles/collectible_training_arrow.tres",
	"item.collectibles.collectible_triple_ammo_chamber": "res://resources/config/collectibles/collectible_triple_ammo_chamber.tres",
	"item.collectibles.collectible_void_crown": "res://resources/config/collectibles/collectible_void_crown.tres",
	"item.collectibles.collectible_warm_bread": "res://resources/config/collectibles/collectible_warm_bread.tres",
	"item.collectibles.collectible_wind_charm": "res://resources/config/collectibles/collectible_wind_charm.tres",
	"item.collectibles.collectible_wooden_buckler": "res://resources/config/collectibles/collectible_wooden_buckler.tres",
	"item.collectibles.collectible_wool_charm": "res://resources/config/collectibles/collectible_wool_charm.tres",
	"item.collectibles.collectible_world_seed": "res://resources/config/collectibles/collectible_world_seed.tres",
	"item.consumables.battle_spirit_potion": "res://resources/config/consumables/battle_spirit_potion.tres",
	"item.consumables.focus_potion": "res://resources/config/consumables/focus_potion.tres",
	"item.consumables.guardian_mixture": "res://resources/config/consumables/guardian_mixture.tres",
	"item.consumables.healing_potion": "res://resources/config/consumables/healing_potion.tres",
	"item.consumables.large_healing_potion": "res://resources/config/consumables/large_healing_potion.tres",
	"item.consumables.large_magic_resistance_potion": "res://resources/config/consumables/large_magic_resistance_potion.tres",
	"item.consumables.large_regeneration_potion": "res://resources/config/consumables/large_regeneration_potion.tres",
	"item.consumables.large_rock_potion": "res://resources/config/consumables/large_rock_potion.tres",
	"item.consumables.large_skill_charge_battery": "res://resources/config/consumables/large_skill_charge_battery.tres",
	"item.consumables.magic_resistance_potion": "res://resources/config/consumables/magic_resistance_potion.tres",
	"item.consumables.phantom_potion": "res://resources/config/consumables/phantom_potion.tres",
	"item.consumables.regeneration_potion": "res://resources/config/consumables/regeneration_potion.tres",
	"item.consumables.rock_potion": "res://resources/config/consumables/rock_potion.tres",
	"item.consumables.sea_cucumber": "res://resources/config/consumables/sea_cucumber.tres",
	"item.consumables.skill_charge_battery": "res://resources/config/consumables/skill_charge_battery.tres",
	"item.consumables.void_battery": "res://resources/config/consumables/void_battery.tres",
	"item.consumables.windwalk_potion": "res://resources/config/consumables/windwalk_potion.tres",
	"item.fate.xiaocong_fate_stone": "res://resources/config/fate/xiaocong_fate_stone.tres",
	"item.materials.material_capoo_blue_crystal_powder": "res://resources/config/materials/material_capoo_blue_crystal_powder.tres",
	"item.materials.material_capoo_blue_crystal": "res://resources/config/materials/material_capoo_blue_crystal.tres",
	"item.materials.material_dirt_block": "res://resources/config/materials/material_dirt_block.tres",
	"item.materials.material_gambler_ticket": "res://resources/config/materials/material_gambler_ticket.tres",
	"item.materials.material_gel": "res://resources/config/materials/material_gel.tres",
	"item.materials.material_plank": "res://resources/config/materials/material_plank.tres",
	"item.materials.material_sapling": "res://resources/config/materials/material_sapling.tres",
	"item.materials.material_small_stone": "res://resources/config/materials/material_small_stone.tres",
	"item.materials.material_sorcerer_violet_powder": "res://resources/config/materials/material_sorcerer_violet_powder.tres",
	"item.materials.material_water_bottle": "res://resources/config/materials/material_water_bottle.tres",
	"item.materials.material_white_crystal_powder": "res://resources/config/materials/material_white_crystal_powder.tres",
	"item.materials.material_white_crystal": "res://resources/config/materials/material_white_crystal.tres",
	"item.materials.material_wood": "res://resources/config/materials/material_wood.tres",
	"item.materials.material_wooden_core": "res://resources/config/materials/material_wooden_core.tres",
	"item.pickup_triggered_items.rapid_magazine": "res://resources/config/pickup_triggered_items/rapid_magazine.tres",
	"item.pickup_triggered_items.snow_wolf_pojun": "res://resources/config/pickup_triggered_items/snow_wolf_pojun.tres",
	"item.pickup_triggered_items.speed_boots": "res://resources/config/pickup_triggered_items/speed_boots.tres",
	"item.pickup_triggered_items.tenpura": "res://resources/config/pickup_triggered_items/tenpura.tres",
	"item.production.water_source": "res://resources/config/production/water_source.tres",
}

static var _enemy_path_to_id: Dictionary = {}
static var _pickup_path_to_id: Dictionary = {}
static var _reverse_indexes_ready := false


static func get_enemy_count() -> int:
	return ENEMY_ID_TO_PATH.size()


static func get_pickup_count() -> int:
	return PICKUP_ID_TO_PATH.size()


static func get_enemy_entries() -> Dictionary:
	return ENEMY_ID_TO_PATH.duplicate()


static func get_pickup_entries() -> Dictionary:
	return PICKUP_ID_TO_PATH.duplicate()


static func is_safe_resource_path_text(raw_path: String) -> bool:
	return _is_valid_resource_path_text(raw_path)


static func get_enemy_id_for_path(raw_path: String) -> String:
	if not _is_valid_resource_path_text(raw_path):
		return ""
	_ensure_reverse_indexes()
	return str(_enemy_path_to_id.get(raw_path, ""))


static func get_pickup_id_for_path(raw_path: String) -> String:
	if not _is_valid_resource_path_text(raw_path):
		return ""
	_ensure_reverse_indexes()
	return str(_pickup_path_to_id.get(raw_path, ""))


static func get_enemy_path_for_id(raw_id: String) -> String:
	if not _is_valid_id_text(raw_id, "enemy."):
		return ""
	return str(ENEMY_ID_TO_PATH.get(raw_id, ""))


static func get_pickup_path_for_id(raw_id: String) -> String:
	if not _is_valid_id_text(raw_id, "item."):
		return ""
	return str(PICKUP_ID_TO_PATH.get(raw_id, ""))


static func load_enemy_config_from_path(raw_path: String) -> EnemyConfig:
	var enemy_id := get_enemy_id_for_path(raw_path)
	if enemy_id.is_empty():
		return null
	var trusted_path := str(ENEMY_ID_TO_PATH.get(enemy_id, ""))
	# Exported script resources are binary Resource instances at loader-selection time.
	# Keep the allowlist as the trust boundary, then validate the script class by cast.
	return ResourceLoader.load(trusted_path) as EnemyConfig


static func load_pickup_config_from_path(raw_path: String) -> PickupConfig:
	var pickup_id := get_pickup_id_for_path(raw_path)
	if pickup_id.is_empty():
		return null
	var trusted_path := str(PICKUP_ID_TO_PATH.get(pickup_id, ""))
	# A custom script-class type hint rejects cold binary .res loads in exported builds.
	return ResourceLoader.load(trusted_path) as PickupConfig


static func is_registered_enemy_config(config: EnemyConfig) -> bool:
	return (
		config != null
		and not get_enemy_id_for_path(config.resource_path).is_empty()
	)


static func is_registered_pickup_config(config: PickupConfig) -> bool:
	return (
		config != null
		and not get_pickup_id_for_path(config.resource_path).is_empty()
	)


static func _ensure_reverse_indexes() -> void:
	if _reverse_indexes_ready:
		return
	for raw_id in ENEMY_ID_TO_PATH:
		var enemy_id := str(raw_id)
		var path := str(ENEMY_ID_TO_PATH[raw_id])
		assert(not _enemy_path_to_id.has(path), "敌人目录存在重复作者路径：%s" % path)
		_enemy_path_to_id[path] = enemy_id
	for raw_id in PICKUP_ID_TO_PATH:
		var pickup_id := str(raw_id)
		var path := str(PICKUP_ID_TO_PATH[raw_id])
		assert(not _pickup_path_to_id.has(path), "道具目录存在重复作者路径：%s" % path)
		_pickup_path_to_id[path] = pickup_id
	_reverse_indexes_ready = true


static func _is_valid_id_text(raw_id: String, required_prefix: String) -> bool:
	if (
		raw_id.is_empty()
		or raw_id.length() > MAX_ID_LENGTH
		or not raw_id.begins_with(required_prefix)
	):
		return false
	for index in range(raw_id.length()):
		var code := raw_id.unicode_at(index)
		var allowed := (
			code >= 97 and code <= 122
			or code >= 48 and code <= 57
			or code in [46, 95, 45]
		)
		if not allowed:
			return false
	return true


static func _is_valid_resource_path_text(raw_path: String) -> bool:
	if (
		raw_path.is_empty()
		or raw_path.length() > MAX_RESOURCE_PATH_LENGTH
		or not raw_path.begins_with("res://")
	):
		return false
	for index in range(raw_path.length()):
		var code := raw_path.unicode_at(index)
		if code < 33 or code > 126:
			return false
	return true
