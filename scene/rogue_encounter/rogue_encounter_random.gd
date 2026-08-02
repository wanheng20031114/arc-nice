extends RefCounted
class_name RogueEncounterRandom

## 遭遇中的每一种随机用途必须使用不同 salt。这样以后新增一次抽签时，
## 不会改变已有的平票、0 元购或接收者结果。


static func choose_index(seed_value: int, salt: StringName, count: int) -> int:
	if count <= 0:
		return -1
	var digest := ("%d|%s" % [seed_value, String(salt)]).sha256_text()
	# 15 个十六进制位小于 INT64_MAX，跨平台转换不会触发符号溢出。
	var stable_value := digest.substr(0, 15).hex_to_int()
	return int(stable_value % count)


static func succeeds(seed_value: int, salt: StringName, chance: float) -> bool:
	var bounded_chance := clampf(chance, 0.0, 1.0)
	var threshold := roundi(bounded_chance * 10000.0)
	if threshold <= 0:
		return false
	if threshold >= 10000:
		return true
	return choose_index(seed_value, salt, 10000) < threshold
