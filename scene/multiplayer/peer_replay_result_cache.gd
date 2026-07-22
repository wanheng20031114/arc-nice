extends RefCounted
class_name PeerReplayResultCache

## A per-peer, insertion-ordered replay-result cache.
##
## Each peer owns one fixed-capacity bucket. Values remain exposed as ordinary
## Dictionaries through [member results_by_peer] for diagnostics, while a
## fixed-size key ring makes insertion, replacement, oldest eviction and
## peer/session cleanup O(1) without allocating an array during eviction.
## Replacing an existing result deliberately keeps its original FIFO position,
## matching Dictionary insertion-order semantics.


class PeerBucket:
	extends RefCounted

	var results: Dictionary = {}
	var key_ring: Array
	var oldest_index := 0
	var entry_count := 0

	func _init(capacity: int) -> void:
		key_ring.resize(capacity)


var results_by_peer: Dictionary = {}

var _capacity_per_peer: int
var _buckets_by_peer: Dictionary = {}


func _init(capacity_per_peer: int) -> void:
	assert(capacity_per_peer > 0)
	_capacity_per_peer = capacity_per_peer


func get_result(peer_id: int, cache_key: Variant) -> Dictionary:
	if peer_id <= 0:
		return {}
	var bucket := _buckets_by_peer.get(peer_id) as PeerBucket
	if bucket == null:
		return {}
	return (bucket.results.get(cache_key, {}) as Dictionary).duplicate(true)


func store_result(
	peer_id: int,
	cache_key: Variant,
	result: Dictionary
) -> void:
	if peer_id <= 0:
		return
	var bucket := _buckets_by_peer.get(peer_id) as PeerBucket
	if bucket == null:
		bucket = PeerBucket.new(_capacity_per_peer)
		_buckets_by_peer[peer_id] = bucket
		results_by_peer[peer_id] = bucket.results
	if bucket.results.has(cache_key):
		bucket.results[cache_key] = result.duplicate(true)
		return
	if bucket.entry_count < _capacity_per_peer:
		var insert_index := bucket.oldest_index + bucket.entry_count
		if insert_index >= _capacity_per_peer:
			insert_index -= _capacity_per_peer
		bucket.key_ring[insert_index] = cache_key
		bucket.entry_count += 1
	else:
		var evicted_key: Variant = bucket.key_ring[bucket.oldest_index]
		bucket.results.erase(evicted_key)
		bucket.key_ring[bucket.oldest_index] = cache_key
		bucket.oldest_index += 1
		if bucket.oldest_index == _capacity_per_peer:
			bucket.oldest_index = 0
	bucket.results[cache_key] = result.duplicate(true)


func clear_peer(peer_id: int) -> void:
	if peer_id <= 0:
		return
	_buckets_by_peer.erase(peer_id)
	results_by_peer.erase(peer_id)


func clear() -> void:
	_buckets_by_peer.clear()
	results_by_peer.clear()


func get_peer_entry_count(peer_id: int) -> int:
	var bucket := _buckets_by_peer.get(peer_id) as PeerBucket
	return bucket.results.size() if bucket != null else 0


func get_peer_count() -> int:
	return _buckets_by_peer.size()
