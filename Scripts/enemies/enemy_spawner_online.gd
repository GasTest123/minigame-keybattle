extends Node2D
class_name EnemySpawnerOnline

## 敌人生成器 Online（使用 MultiplayerSpawner）- Phase优化版
## 职责：只负责生成敌人，不管理波次逻辑
## 支持多阶段(Phase)刷怪和批量生成

## ========== 配置 ==========
## 默认敌人场景（兜底用，当 scene_path 为空时使用）
@export var fallback_enemy_scene: PackedScene
@export var spawn_delay: float = 0.4  # 生成间隔

## 刷新预警图片
var spawn_indicator_texture: Texture2D = preload("res://assets/others/enemy_spawn_indicator_01.png")

var floor_layer: TileMapLayer = null
var wave_system: WaveSystemOnline = null
var enemies_container: Node = null  # Enemies 节点（MultiplayerSpawner 的 spawn_path）

## ========== 性能优化：缓存 floor_layer.get_used_cells() ==========
var _cached_used_cells: Array[Vector2i] = []
var _used_cells_cache_valid: bool = false

## ========== 场景缓存 ==========
## 缓存已加载的敌人场景，避免重复加载
var scene_cache: Dictionary = {}

## ========== 生成参数 ==========
const SPAWN_MIN_DISTANCE: float = 300.0   # 最小距离：敌人不会在玩家范围内刷新
const SPAWN_MAX_DISTANCE: float = 1200.0  # 最大距离
const SPAWN_CANCEL_DISTANCE_NEAR_PLAYER: float = 100.0  # 生成瞬间二次安全距离

var max_spawn_attempts: int = 30

## ========== 预警配置 ==========
var spawn_indicator_delay: float = 0.5  # 默认预警延迟

## ========== 预警同步 ==========
var _indicator_id_counter: int = 0  # 预警ID计数器
var _client_indicators: Dictionary = {}  # 客户端预警图片 {id: Sprite2D}

## ========== 状态 ==========
var is_spawning: bool = false

## ========== Phase刷怪状态 ==========
var current_wave_config: Dictionary = {}
var current_phase_index: int = 0
var global_spawn_index: int = 0
var phase_enemy_lists: Array = []
var _stop_spawning: bool = false

# special_spawns 对应的全局索引
var _special_spawn_global_indices: Dictionary = {}


func _is_network_server() -> bool:
	return NetworkManager.is_server()


func _ready() -> void:
	add_to_group("enemy_spawner")
	
	# 查找地图
	floor_layer = get_tree().get_first_node_in_group("floor_layer")
	if not floor_layer:
		push_error("[EnemySpawner Online] 找不到floor_layer")
	else:
		_refresh_used_cells_cache()
	
	# 从当前模式获取预警延迟配置
	_load_spawn_indicator_delay()
	
	print("[EnemySpawner Online] 初始化完成 (MultiplayerSpawner 模式)，预警延迟: %s 秒" % str(spawn_indicator_delay))


## 刷新地面格子缓存
func _refresh_used_cells_cache() -> void:
	if not floor_layer:
		_cached_used_cells = []
		_used_cells_cache_valid = false
		return
	var cells: Array[Vector2i] = floor_layer.get_used_cells()
	_cached_used_cells = cells
	_used_cells_cache_valid = not _cached_used_cells.is_empty()


## 从当前模式加载预警延迟配置
func _load_spawn_indicator_delay() -> void:
	var mode_id = GameMain.current_mode_id
	if mode_id and not mode_id.is_empty():
		var mode = ModeRegistry.get_mode(mode_id)
		if mode:
			spawn_indicator_delay = float(mode.spawn_indicator_delay)


## 设置 Enemies 容器节点
func set_enemies_container(container: Node) -> void:
	enemies_container = container
	print("[EnemySpawner Online] Enemies 容器已设置")


## 设置波次系统
func set_wave_system(system: WaveSystemOnline) -> void:
	wave_system = system
	print("[EnemySpawner Online] 连接到波次系统")


## ========== 新的Phase刷怪系统 ==========

## 开始多阶段刷怪
func spawn_wave_phases(wave_config: Dictionary, ws: WaveSystemOnline) -> void:
	if is_spawning:
		push_warning("[EnemySpawner Online] 已在生成中，忽略")
		return
	
	if not _is_network_server():
		print("[EnemySpawner Online] 非服务器节点，等待 MultiplayerSpawner 同步")
		return
	
	if not enemies_container:
		push_error("[EnemySpawner Online] Enemies 容器未设置")
		return
	
	wave_system = ws
	current_wave_config = wave_config
	_stop_spawning = false
	
	var wave_number = wave_config.wave_number
	var phases = wave_config.get("spawn_phases", [])
	var special_spawns = wave_config.get("special_spawns", [])
	
	print("[EnemySpawner Online] 开始Phase刷怪 - Wave %d, %d个Phase" % [wave_number, phases.size()])
	
	# 预构建所有phase的敌人列表
	phase_enemy_lists.clear()
	_special_spawn_global_indices.clear()
	for phase in phases:
		var enemy_list = _build_phase_enemy_list(phase)
		phase_enemy_lists.append(enemy_list)
	
	# 应用special_spawns到全局位置
	_apply_special_spawns(special_spawns)
	
	# 开始异步刷怪
	_spawn_all_phases_async(wave_config)


## 构建单个Phase的敌人列表
func _build_phase_enemy_list(phase_config: Dictionary) -> Array:
	var list = []
	var enemy_types = phase_config.get("enemy_types", {})
	var total = phase_config.get("total_count", 10)
	
	if enemy_types.is_empty():
		push_warning("[EnemySpawner Online] Phase没有配置enemy_types")
		return list
	
	total = int(total)
	if total <= 0:
		return list
	
	# 保证每种怪至少1只
	var keys: Array = enemy_types.keys()
	keys.sort()
	if total >= keys.size():
		for enemy_id in keys:
			list.append(enemy_id)
	
	# 剩余按权重随机选择
	while list.size() < total:
		var enemy_id = _pick_by_probability(enemy_types)
		if enemy_id == "":
			break
		list.append(enemy_id)
	
	# 打乱顺序
	list.shuffle()
	
	return list


## 按概率选择敌人类型
func _pick_by_probability(enemy_types: Dictionary) -> String:
	if enemy_types.is_empty():
		return ""
	
	var keys: Array = enemy_types.keys()
	keys.sort()
	
	var sum := 0.0
	var weights: Dictionary = {}
	for enemy_id in keys:
		var w := float(enemy_types.get(enemy_id, 0.0))
		if w > 0.0:
			weights[enemy_id] = w
			sum += w
	
	if sum <= 0.0 or weights.is_empty():
		return str(keys[randi() % keys.size()])
	
	var roll := randf() * sum
	var cumulative := 0.0
	for enemy_id in keys:
		if not weights.has(enemy_id):
			continue
		cumulative += float(weights[enemy_id])
		if roll < cumulative:
			return str(enemy_id)
	
	for i in range(keys.size() - 1, -1, -1):
		var k = keys[i]
		if weights.has(k):
			return str(k)
	return str(keys[0])


## 应用special_spawns到全局位置
func _apply_special_spawns(special_spawns: Array) -> void:
	if special_spawns.is_empty():
		return
	
	var global_index = 0
	var index_to_phase_local: Array = []
	
	for phase_idx in range(phase_enemy_lists.size()):
		for local_idx in range(phase_enemy_lists[phase_idx].size()):
			index_to_phase_local.append([phase_idx, local_idx])
			global_index += 1
	
	var total_enemies = global_index
	
	special_spawns.sort_custom(func(a, b):
		return int(a.get("position", 0)) < int(b.get("position", 0))
	)
	
	for spawn in special_spawns:
		if not (spawn is Dictionary):
			continue
		var enemy_id = str(spawn.get("enemy_id", ""))
		if enemy_id.is_empty():
			continue
		
		var pos = int(spawn.get("position", 0))
		if pos < 0 or pos >= total_enemies:
			continue
		
		var chance := 1.0
		if spawn.has("spawn_chance"):
			chance = float(spawn.get("spawn_chance", 1.0))
			if chance > 1.0 and chance <= 100.0:
				chance = chance / 100.0
			chance = clamp(chance, 0.0, 1.0)
		
		if randf() <= chance:
			var mapping = index_to_phase_local[pos]
			var phase_idx = mapping[0]
			var local_idx = mapping[1]
			phase_enemy_lists[phase_idx][local_idx] = enemy_id
			_special_spawn_global_indices[pos] = true


## 异步执行所有Phase的刷怪
func _spawn_all_phases_async(wave_config: Dictionary) -> void:
	is_spawning = true
	current_phase_index = 0
	global_spawn_index = 0
	
	var wave_number = wave_config.wave_number
	var hp_growth = wave_config.get("hp_growth", 0.0)
	var damage_growth = wave_config.get("damage_growth", 0.0)
	var min_alive = wave_config.get("min_alive_enemies", WaveSystemOnline.DEFAULT_MIN_ALIVE_ENEMIES)
	var max_alive = wave_config.get("max_alive_enemies", WaveSystemOnline.DEFAULT_MAX_ALIVE_ENEMIES)
	var phases = wave_config.get("spawn_phases", [])
	
	# 是否存在Boss
	var boss_cfg = wave_config.get("boss_config", {})
	var boss_count = int(boss_cfg.get("count", 0))
	var boss_id = str(boss_cfg.get("enemy_id", ""))
	var has_boss: bool = boss_count > 0 and boss_id != ""
	
	for phase_idx in range(phases.size()):
		if _stop_spawning:
			break
		
		current_phase_index = phase_idx
		var phase = phases[phase_idx]
		var enemy_list = phase_enemy_lists[phase_idx]
		
		print("[EnemySpawner Online] 开始Phase %d/%d, 敌人数: %d" % [phase_idx + 1, phases.size(), enemy_list.size()])
		
		# 执行当前Phase的刷怪
		await _spawn_phase_async(
			enemy_list,
			phase,
			wave_number,
			hp_growth,
			damage_growth,
			min_alive,
			max_alive,
			has_boss
		)
		
		if _stop_spawning:
			break
		
		# Phase之间的过渡
		if phase_idx < phases.size() - 1:
			print("[EnemySpawner Online] Phase %d 刷完，等待场上怪物数 <= %d" % [phase_idx + 1, min_alive])
			await _wait_for_enemy_count_below(min_alive)
			print("[EnemySpawner Online] 条件满足，开始下一Phase")
	
	# 所有Phase刷完后，刷新Boss
	if not _stop_spawning:
		await _spawn_boss_async(wave_config, wave_number, hp_growth, damage_growth)
	
	is_spawning = false
	print("[EnemySpawner Online] 所有Phase和Boss刷怪完成")
	
	# 通知波次系统
	if wave_system and wave_system.has_method("on_all_phases_complete"):
		wave_system.on_all_phases_complete()


## 刷新Boss
func _spawn_boss_async(wave_config: Dictionary, wave_number: int, hp_growth: float, damage_growth: float) -> void:
	var boss_cfg = wave_config.get("boss_config", {})
	var boss_count = boss_cfg.get("count", 0)
	var boss_id = boss_cfg.get("enemy_id", "")
	
	if boss_count <= 0 or boss_id == "":
		return
	
	print("[EnemySpawner Online] 刷新Boss: %s x%d" % [boss_id, boss_count])
	
	for i in range(boss_count):
		if _stop_spawning:
			break
		
		var enemy = await _spawn_enemy_with_indicator(boss_id, i == boss_count - 1, wave_number, hp_growth, damage_growth)
		
		if enemy and wave_system:
			wave_system.on_enemy_spawned(enemy)
		elif wave_system and wave_system.has_method("on_enemy_spawn_failed"):
			wave_system.on_enemy_spawn_failed(boss_id)
		
		if i < boss_count - 1:
			var tree = get_tree()
			if tree:
				await tree.create_timer(0.5, false).timeout


## 执行单个Phase的刷怪
func _spawn_phase_async(
	enemy_list: Array,
	phase_config: Dictionary,
	wave_number: int,
	hp_growth: float,
	damage_growth: float,
	min_alive: int,
	max_alive: int,
	has_boss: bool
) -> void:
	var spawn_per_time = phase_config.get("spawn_per_time", 1)
	var spawn_interval = phase_config.get("spawn_interval", 2.0)
	
	var list_index = 0
	var total_in_phase = enemy_list.size()
	
	while list_index < total_in_phase:
		if _stop_spawning:
			break
		
		# 检查max限制
		var current_active = wave_system.get_active_enemy_count() if wave_system else 0
		if current_active >= max_alive:
			await _wait_for_enemy_count_below(max_alive)
			if _stop_spawning:
				break
			continue
		
		# 计算本次刷怪数量
		var remaining = total_in_phase - list_index
		var batch_size = min(spawn_per_time, remaining)
		
		var space_available = max_alive - current_active
		batch_size = min(batch_size, space_available)
		
		if batch_size <= 0:
			await get_tree().create_timer(0.1, false).timeout
			continue
		
		# 收集本批次要刷的敌人
		var batch_enemies = []
		for i in range(batch_size):
			batch_enemies.append(enemy_list[list_index + i])
		
		# 计算是否是最后一批
		var is_last_batch = (not has_boss) and (list_index + batch_size >= total_in_phase) and (current_phase_index >= phase_enemy_lists.size() - 1)
		
		# 批量刷怪
		await _spawn_batch_with_indicators(batch_enemies, wave_number, hp_growth, damage_growth, is_last_batch)
		
		list_index += batch_size
		global_spawn_index += batch_size
		
		if _stop_spawning:
			break
		
		# 检查min
		current_active = wave_system.get_active_enemy_count() if wave_system else 0
		if current_active > min_alive and list_index < total_in_phase:
			await get_tree().create_timer(spawn_interval, false).timeout


## 批量刷怪（带预警图标）
func _spawn_batch_with_indicators(
	enemy_ids: Array,
	wave_number: int,
	hp_growth: float,
	damage_growth: float,
	is_last_batch: bool
) -> void:
	var spawn_data = []
	
	for i in range(enemy_ids.size()):
		var enemy_id = enemy_ids[i]
		var planned_global_index: int = int(global_spawn_index) + int(i)
		var is_special := _special_spawn_global_indices.has(planned_global_index)
		var spawn_pos = _find_spawn_position()
		if spawn_pos == Vector2.INF:
			push_warning("[EnemySpawner Online] 无法找到合适位置：", enemy_id)
			if wave_system and wave_system.has_method("on_enemy_spawn_failed"):
				wave_system.on_enemy_spawn_failed(enemy_id)
			continue
		
		var indicator_data = _create_spawn_indicator(spawn_pos)
		spawn_data.append({
			"pos": spawn_pos,
			"indicator_data": indicator_data,
			"enemy_id": enemy_id,
			"is_last": is_last_batch and (i == enemy_ids.size() - 1),
			"is_special": is_special
		})
	
	# 等待预警延迟
	if spawn_data.size() > 0:
		await get_tree().create_timer(spawn_indicator_delay, false).timeout
	
	# 移除预警并生成敌人
	for data in spawn_data:
		_remove_spawn_indicator(data.indicator_data)
		
		# 二次安全检查
		if (not bool(data.get("is_special", false))) and _should_cancel_spawn_due_to_player_proximity(data.pos):
			if wave_system and wave_system.has_method("on_enemy_spawn_skipped"):
				wave_system.on_enemy_spawn_skipped(str(data.enemy_id), "too_close_to_player")
			elif wave_system and wave_system.has_method("on_enemy_spawn_failed"):
				wave_system.on_enemy_spawn_failed(str(data.enemy_id))
			continue
		
		var enemy = _spawn_single_enemy_at_position(
			data.enemy_id,
			data.pos,
			data.is_last,
			wave_number,
			hp_growth,
			damage_growth
		)
		
		if enemy and wave_system:
			wave_system.on_enemy_spawned(enemy)
		elif wave_system and wave_system.has_method("on_enemy_spawn_failed"):
			wave_system.on_enemy_spawn_failed(data.enemy_id)


## 创建预警图片（服务器端）
func _create_spawn_indicator(pos: Vector2) -> Dictionary:
	# 分配唯一ID
	_indicator_id_counter += 1
	var indicator_id = _indicator_id_counter
	
	# 服务器本地创建
	var indicator = Sprite2D.new()
	indicator.texture = spawn_indicator_texture
	indicator.global_position = pos
	indicator.z_index = 10
	indicator.modulate = Color(1, 1, 1, 0.8)
	add_child(indicator)
	
	# 广播给所有客户端
	rpc("rpc_show_spawn_indicator", indicator_id, pos)
	
	return {"id": indicator_id, "sprite": indicator}


## 移除预警图片（服务器端）
func _remove_spawn_indicator(indicator_data: Dictionary) -> void:
	if indicator_data.has("sprite") and is_instance_valid(indicator_data.sprite):
		indicator_data.sprite.queue_free()
	
	if indicator_data.has("id"):
		rpc("rpc_remove_spawn_indicator", indicator_data.id)


## 客户端显示预警图片
@rpc("authority", "call_remote", "reliable")
func rpc_show_spawn_indicator(indicator_id: int, pos: Vector2) -> void:
	var indicator = Sprite2D.new()
	indicator.texture = spawn_indicator_texture
	indicator.global_position = pos
	indicator.z_index = 10
	indicator.modulate = Color(1, 1, 1, 0.8)
	add_child(indicator)
	_client_indicators[indicator_id] = indicator


## 客户端移除预警图片
@rpc("authority", "call_remote", "reliable")
func rpc_remove_spawn_indicator(indicator_id: int) -> void:
	if _client_indicators.has(indicator_id):
		var indicator = _client_indicators[indicator_id]
		if is_instance_valid(indicator):
			indicator.queue_free()
		_client_indicators.erase(indicator_id)


## 带预警的敌人生成
func _spawn_enemy_with_indicator(enemy_id: String, is_last_in_wave: bool, wave_number: int, hp_growth: float, damage_growth: float) -> Node:
	var spawn_pos = _find_spawn_position()
	if spawn_pos == Vector2.INF:
		push_warning("[EnemySpawner Online] 无法找到合适位置：", enemy_id)
		return null
	
	var indicator_data = _create_spawn_indicator(spawn_pos)
	
	await get_tree().create_timer(spawn_indicator_delay, false).timeout
	
	_remove_spawn_indicator(indicator_data)
	
	var enemy = _spawn_single_enemy_at_position(enemy_id, spawn_pos, is_last_in_wave, wave_number, hp_growth, damage_growth)
	return enemy


## 生成瞬间是否应取消
func _should_cancel_spawn_due_to_player_proximity(spawn_pos: Vector2) -> bool:
	var players = NetworkPlayerManager.players
	if players.is_empty():
		return false
	
	for peer_id in players.keys():
		var player = players[peer_id]
		if player and is_instance_valid(player):
			if spawn_pos.distance_to(player.global_position) < SPAWN_CANCEL_DISTANCE_NEAR_PLAYER:
				return true
	
	return false


## 等待场上敌人数量低于指定值
func _wait_for_enemy_count_below(threshold: int) -> void:
	while not _stop_spawning:
		var current = wave_system.get_active_enemy_count() if wave_system else 0
		if current < threshold:
			break
		await get_tree().create_timer(0.2, false).timeout


## ========== 兼容旧接口 ==========

## 生成一波敌人（旧接口，保持兼容）
func spawn_wave(wave_config: Dictionary) -> void:
	# 如果是新格式，使用新方法
	if wave_config.get("is_phase_format", false) or wave_config.has("spawn_phases"):
		if wave_system:
			spawn_wave_phases(wave_config, wave_system)
		else:
			push_error("[EnemySpawner Online] 使用新格式但wave_system未设置")
		return
	
	# 旧格式处理
	if is_spawning:
		push_warning("[EnemySpawner Online] 已在生成中，忽略")
		return
	
	if not _is_network_server():
		print("[EnemySpawner Online] 非服务器节点，等待 MultiplayerSpawner 同步")
		return
	
	if not wave_system:
		push_error("[EnemySpawner Online] 波次系统未设置")
		return
	
	if not enemies_container:
		push_error("[EnemySpawner Online] Enemies 容器未设置")
		return
	
	var wave_number = wave_config.wave_number
	print("[EnemySpawner Online] 开始生成第 ", wave_number, " 波")
	
	# 构建生成列表
	var spawn_list = _build_spawn_list(wave_config)
	
	# 开始异步生成
	_spawn_enemies_async(spawn_list, wave_number)


## 构建生成列表（旧格式）
func _build_spawn_list(config: Dictionary) -> Array:
	var list = []
	
	# 添加普通敌人
	if config.has("enemies"):
		for enemy_group in config.enemies:
			for i in range(enemy_group.count):
				list.append(enemy_group.id)
	
	# 添加最后的敌人
	if config.has("last_enemy"):
		for i in range(config.last_enemy.count):
			list.append(config.last_enemy.id)
	
	print("[EnemySpawner Online] 生成列表：", list.size(), " 个敌人")
	return list


## 异步生成敌人列表（旧格式）
func _spawn_enemies_async(spawn_list: Array, wave_number: int) -> void:
	is_spawning = true
	
	var index = 0
	for enemy_id in spawn_list:
		var is_last = (index == spawn_list.size() - 1)
		
		var enemy = _spawn_single_enemy(enemy_id, is_last, wave_number)
		if enemy:
			if wave_system:
				if wave_system.has_method("register_enemy_instance"):
					wave_system.register_enemy_instance(enemy)
				elif wave_system.has_method("on_enemy_spawned"):
					wave_system.on_enemy_spawned(enemy)
		
		await get_tree().create_timer(spawn_delay, false).timeout
		index += 1
	
	is_spawning = false
	print("[EnemySpawner Online] 生成完成")
	
	if wave_system and wave_system.has_method("on_all_phases_complete"):
		wave_system.on_all_phases_complete()


## ========== 基础刷怪方法 ==========

## 获取敌人场景
## 注意：联网模式统一使用 fallback_enemy_scene (enemy_online.tscn)
## 单机版的 EnemyData.scene_path 场景使用的是 Enemy 类，不兼容联网模式的 EnemyOnline 类
func _get_enemy_scene(_enemy_data: EnemyData) -> PackedScene:
	# 联网模式始终使用统一的 EnemyOnline 场景
	if fallback_enemy_scene:
		return fallback_enemy_scene
	else:
		push_error("[EnemySpawner Online] fallback_enemy_scene 未设置")
		return null

## 查找生成位置
func _find_spawn_position() -> Vector2:
	if not floor_layer:
		return Vector2.INF

	if not _used_cells_cache_valid:
		_refresh_used_cells_cache()
	if not _used_cells_cache_valid:
		return Vector2.INF
	
	for attempt in max_spawn_attempts:
		var cell: Vector2i = _cached_used_cells[randi() % _cached_used_cells.size()]
		var world_pos: Vector2 = floor_layer.map_to_local(cell) * 6.0
		
		if _is_valid_spawn_distance(world_pos):
			return world_pos
	
	return Vector2.INF


## 检查位置是否在有效刷怪范围内
func _is_valid_spawn_distance(spawn_pos: Vector2) -> bool:
	var players = NetworkPlayerManager.players
	if players.is_empty():
		return true
	
	# 检查所有玩家
	var min_player_distance: float = INF
	for peer_id in players.keys():
		var player = players[peer_id]
		if player and is_instance_valid(player):
			var distance := spawn_pos.distance_to(player.global_position)
			min_player_distance = min(min_player_distance, distance)
	
	return min_player_distance >= SPAWN_MIN_DISTANCE and min_player_distance <= SPAWN_MAX_DISTANCE


## 生成单个敌人（兼容旧接口）
func _spawn_single_enemy(enemy_id: String, is_last_in_wave: bool = false, wave_number: int = 1, hp_growth: float = 0.0, damage_growth: float = 0.0) -> EnemyOnline:
	var spawn_pos = _find_spawn_position()
	if spawn_pos == Vector2.INF:
		push_warning("[EnemySpawner Online] 无法找到合适位置：", enemy_id)
		return null
	return _spawn_single_enemy_at_position(enemy_id, spawn_pos, is_last_in_wave, wave_number, hp_growth, damage_growth)


## 在指定位置生成单个敌人（服务器端）
func _spawn_single_enemy_at_position(enemy_id: String, spawn_pos: Vector2, is_last_in_wave: bool = false, wave_number: int = 1, hp_growth: float = 0.0, damage_growth: float = 0.0) -> EnemyOnline:
	if not floor_layer:
		push_error("[EnemySpawner Online] floor_layer未设置")
		return null
	
	# 获取敌人数据
	var enemy_data = EnemyDatabase.get_enemy_data(enemy_id)
	if enemy_data == null:
		push_error("[EnemySpawner Online] 敌人数据不存在：", enemy_id)
		return null
	
	# 获取敌人场景（支持动态加载）
	var enemy_scene = _get_enemy_scene(enemy_data)
	if not enemy_scene:
		push_error("[EnemySpawner Online] 无法获取敌人场景：", enemy_id)
		return null
	
	# 创建敌人实例
	var enemy := enemy_scene.instantiate() as EnemyOnline
	if not enemy:
		push_error("[EnemySpawner Online] 无法实例化敌人场景")
		return null
	
	# 设置基本属性
	enemy.enemy_id = enemy_id
	enemy.global_position = spawn_pos
	enemy.is_last_enemy_in_wave = is_last_in_wave
	enemy.current_wave_number = wave_number
	
	# 先添加到场景树，让 MultiplayerSpawner 创建对应的客户端实例
	enemies_container.add_child(enemy, true)
	
	# 计算HP和伤害成长
	var hp_multiplier = 1.0 + hp_growth
	var damage_multiplier = 1.0 + damage_growth
	
	# 波次因子成长
	var wave_factor = max(0, wave_number - 1)
	var hp_growth_points = enemy_data.hp_growth_per_wave if enemy_data else 0.0
	var damage_growth_points = enemy_data.damage_growth_per_wave if enemy_data else 0.0
	var hp_bonus = hp_growth_points * wave_factor
	var damage_bonus = damage_growth_points * wave_factor
	
	var final_hp := int((enemy_data.max_hp + hp_bonus) * hp_multiplier)
	enemy.max_enemyHP = final_hp
	enemy.enemyHP = final_hp
	
	# 设置攻击伤害
	enemy.attack_damage = int((enemy_data.attack_damage + damage_bonus) * damage_multiplier)
	
	# 服务器端加载完整敌人数据
	enemy.enemy_data = enemy_data
	enemy.enemy_spawner = self
	
	# 服务器端手动应用敌人数据（因为 _ready 在属性设置前就执行了）
	enemy._apply_enemy_data()
	
	# 应用技能伤害成长
	_apply_skill_damage_growth(enemy, damage_multiplier, damage_bonus)
	
	print("[EnemySpawner Online] 生成敌人：%s 波次:%d HP:%d 伤害:%d 位置:%s" % [enemy_id, wave_number, enemy.enemyHP, enemy.attack_damage, str(spawn_pos)])
	
	return enemy


## 应用技能伤害成长
func _apply_skill_damage_growth(enemy: Node, damage_multiplier: float, damage_growth_points: float = 0.0) -> void:
	if not "behaviors" in enemy:
		return
	
	for behavior in enemy.behaviors:
		if not is_instance_valid(behavior):
			continue
		
		if behavior is ChargingBehavior:
			var charging = behavior as ChargingBehavior
			charging.extra_damage = int((charging.extra_damage + damage_growth_points) * damage_multiplier)
		
		elif behavior is ShootingBehavior:
			var shooting = behavior as ShootingBehavior
			shooting.bullet_damage = int((shooting.bullet_damage + damage_growth_points) * damage_multiplier)
		
		elif behavior is ExplodingBehavior:
			var exploding = behavior as ExplodingBehavior
			exploding.explosion_damage = int((exploding.explosion_damage + damage_growth_points) * damage_multiplier)


## 清理所有敌人（调试用）
func clear_all_enemies() -> void:
	_stop_spawning = true
	if not enemies_container:
		return
	
	for child in enemies_container.get_children():
		if child is EnemyOnline:
			child.queue_free()
	print("[EnemySpawner Online] 清理所有敌人")


## 获取所有活着的敌人
func get_alive_enemies() -> Array[EnemyOnline]:
	var result: Array[EnemyOnline] = []
	
	if not enemies_container:
		return result
	
	for child in enemies_container.get_children():
		if child is EnemyOnline and is_instance_valid(child) and not child.is_dead:
			result.append(child)
	
	return result


## 停止刷怪
func stop_spawning() -> void:
	_stop_spawning = true
	is_spawning = false


## 通知敌人受伤（服务器端调用，广播伤害效果给客户端）
func notify_enemy_hurt(enemy: EnemyOnline, damage: int, is_critical: bool = false, attacker_peer_id: int = 0) -> void:
	if not _is_network_server():
		return
	if not enemy:
		return
	
	print("[EnemySpawner Online] notify_enemy_hurt name=%s hp=%d dmg=%d" % [enemy.name, enemy.enemyHP, damage])
	
	rpc(&"rpc_show_enemy_hurt_effect", enemy.name, damage, is_critical, attacker_peer_id)


## 通知敌人死亡（服务器端调用）
func notify_enemy_dead(enemy: EnemyOnline) -> void:
	if not _is_network_server():
		return
	if not enemy:
		return
	
	print("[EnemySpawner Online] notify_enemy_dead name=%s" % enemy.name)
	
	rpc(&"rpc_show_enemy_dead_effect", enemy.name)


## RPC：显示敌人受伤效果（客户端）
@rpc("authority", "call_remote", "reliable")
func rpc_show_enemy_hurt_effect(enemy_name: String, damage: int, is_critical: bool, attacker_peer_id: int) -> void:
	if _is_network_server():
		return
	
	if not enemies_container:
		return
	
	var enemy = enemies_container.get_node_or_null(enemy_name)
	if enemy and enemy is EnemyOnline and is_instance_valid(enemy):
		enemy.show_hurt_effect(damage, is_critical)


## RPC：显示敌人死亡效果（客户端）
@rpc("authority", "call_remote", "reliable")
func rpc_show_enemy_dead_effect(enemy_name: String) -> void:
	if _is_network_server():
		return
	
	if not enemies_container:
		return
	
	var enemy = enemies_container.get_node_or_null(enemy_name)
	if enemy and enemy is EnemyOnline and is_instance_valid(enemy):
		enemy.show_death_effect()
