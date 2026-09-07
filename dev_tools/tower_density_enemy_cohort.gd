extends RefCounted

## Shared deterministic fixture roster. Empty wave keeps the original melee
## baseline; a production WaveConfig supplies the exact authored proportions.
static func build_paths(count: int, wave_path: String = "") -> PackedStringArray:
	var paths := PackedStringArray()
	if wave_path.is_empty():
		for index in count:
			paths.append("res://resources/config/enemies/yuanshi_insect_shell.tres" if index % 5 == 0 else "res://resources/config/enemies/yuanshi_insect_basic.tres")
		return paths
	var wave := load(wave_path) as WaveConfig
	assert(wave != null, "Density enemy wave must be an authored WaveConfig")
	var total := 0
	for entry in wave.enemy_entries:
		if entry != null and entry.enemy_config != null:
			total += maxi(entry.count, 0)
	assert(total > 0, "Density enemy wave must contain enemies")
	var cumulative := 0
	for entry in wave.enemy_entries:
		if entry == null or entry.enemy_config == null:
			continue
		cumulative += maxi(entry.count, 0)
		var target := int(float(cumulative) * count / total)
		while paths.size() < target:
			paths.append(entry.enemy_config.resource_path)
	# Shuffle with a private seed so all fixtures use the same spatial mix without
	# consuming gameplay's random stream or changing the authored recipe weights.
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260908
	for index in range(paths.size() - 1, 0, -1):
		var other := rng.randi_range(0, index)
		var path := paths[index]
		paths[index] = paths[other]
		paths[other] = path
	return paths

static func summarize(paths: PackedStringArray) -> Dictionary:
	var counts := {}
	for path in paths:
		counts[path.get_file().get_basename()] = int(counts.get(path.get_file().get_basename(), 0)) + 1
	return counts
