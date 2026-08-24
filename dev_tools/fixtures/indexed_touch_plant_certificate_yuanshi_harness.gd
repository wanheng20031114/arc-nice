extends YuanshiInsect
class_name IndexedTouchPlantCertificateYuanshiHarness

## Keeps the production Yuanshi contact geometry and indexed-contact code while
## preventing navigation from moving the fixture behind the test's back. The
## static observations expose only ordering already delivered to Enemy's public
## indexed-contact callbacks; no coordinator internals are read or mutated.

static var contact_visit_order: Array[int] = []
static var synchronized_plant_ids_by_simulation_id: Dictionary = {}


static func reset_contact_observations() -> void:
	contact_visit_order.clear()
	synchronized_plant_ids_by_simulation_id.clear()


static func reset_contact_visit_order() -> void:
	contact_visit_order.clear()


static func get_contact_visit_order() -> Array[int]:
	var result: Array[int] = []
	result.assign(contact_visit_order)
	return result


static func get_synchronized_plant_ids(
	observed_simulation_id: int
) -> Array[int]:
	var result: Array[int] = []
	var stored_ids: Variant = synchronized_plant_ids_by_simulation_id.get(
		observed_simulation_id,
		[]
	)
	for stored_id in stored_ids:
		result.append(int(stored_id))
	return result


func _get_navigation_move_direction(_delta: float) -> Vector2:
	return Vector2.ZERO


func _get_move_speed() -> float:
	return 0.0


func synchronize_indexed_touch_contacts(
	players: Array[Player],
	plants: Array
) -> bool:
	_record_contact_visit()
	var plant_ids: Array[int] = []
	for plant_variant in plants:
		var plant := plant_variant as PlantDefense
		if plant != null and is_instance_valid(plant):
			plant_ids.append(plant.get_instance_id())
	synchronized_plant_ids_by_simulation_id[simulation_id] = plant_ids
	return super.synchronize_indexed_touch_contacts(players, plants)


func refresh_indexed_touch_contact_selection() -> void:
	_record_contact_visit()
	super.refresh_indexed_touch_contact_selection()


func _record_contact_visit() -> void:
	if simulation_id > 0:
		contact_visit_order.append(simulation_id)
