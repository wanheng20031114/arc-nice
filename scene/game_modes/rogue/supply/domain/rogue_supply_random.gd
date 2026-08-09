extends RefCounted
class_name RogueSupplyRandom

## 物资节点的每一种随机用途都使用独立 salt，避免以后新增抽签时改变
## 已生成路线上的选项、平票、收藏品候选或信封接收者。


static func choose_index(seed_value: int, salt: StringName, count: int) -> int:
	if count <= 0:
		return -1
	var digest := ("%d|%s" % [seed_value, String(salt)]).sha256_text()
	var stable_value := digest.substr(0, 15).hex_to_int()
	return int(stable_value % count)


static func shuffled_indices(
	seed_value: int,
	salt: StringName,
	count: int
) -> Array[int]:
	var result: Array[int] = []
	for index in range(maxi(count, 0)):
		result.append(index)
	for tail in range(result.size() - 1, 0, -1):
		var swap_index := choose_index(
			seed_value,
			StringName("%s|tail:%d" % [String(salt), tail]),
			tail + 1
		)
		var value := result[tail]
		result[tail] = result[swap_index]
		result[swap_index] = value
	return result
