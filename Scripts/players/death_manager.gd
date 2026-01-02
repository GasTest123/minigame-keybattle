extends Node
class_name DeathManager

## 死亡管理器
## 管理玩家死亡、复活逻辑和复活次数

## 信号
signal player_died  # 玩家死亡
signal player_revived  # 玩家复活
signal game_over  # 游戏结束（玩家放弃）

## 引用
var player: CharacterBody2D = null
var death_ui: DeathUI = null
var floor_layer: TileMapLayer = null
var grave_instance: Grave = null  # 墓碑实例
var grave_ghost_data: GhostData = null  # 墓碑关联的Ghost数据

## 预加载墓碑场景
var grave_scene: PackedScene = preload("res://scenes/players/grave.tscn")

## 状态
var is_dead: bool = false
var revive_count: int = 0  # 本局累计复活次数
var death_count: int = 0  # 本局累计死亡次数（包括已复活的）
var death_timer: float = 0.0
var death_delay: float = 1.5  # 死亡延迟时间
var death_position: Vector2 = Vector2.ZERO  # 记录死亡位置

func _ready() -> void:
	# 确保在游戏暂停时仍能处理死亡逻辑
	process_mode = Node.PROCESS_MODE_ALWAYS
	
	# 添加到组中方便查找
	add_to_group("death_manager")
	
	print("[DeathManager] 初始化")

## 节点被移除时清理墓碑
func _exit_tree() -> void:
	_remove_grave()
	print("[DeathManager] 已清理")

## 设置玩家引用
func set_player(p: CharacterBody2D) -> void:
	player = p
	
	# 连接玩家HP信号
	if player.has_signal("hp_changed"):
		if not player.hp_changed.is_connected(_on_player_hp_changed):
			player.hp_changed.connect(_on_player_hp_changed)
	
	print("[DeathManager] 设置玩家引用")

## 设置死亡UI
func set_death_ui(ui: DeathUI) -> void:
	death_ui = ui
	
	# 连接UI信号
	if death_ui:
		death_ui.revive_requested.connect(_on_revive_requested)
		death_ui.give_up_requested.connect(_on_give_up_requested)
		death_ui.restart_requested.connect(_on_restart_requested)
	
	print("[DeathManager] 设置死亡UI")

## 设置地图层（用于随机复活位置）
func set_floor_layer(layer: TileMapLayer) -> void:
	floor_layer = layer
	print("[DeathManager] 设置地图层")

func _process(delta: float) -> void:
	# 处理死亡延迟计时
	if is_dead and death_timer > 0:
		death_timer -= delta
		
		if death_timer <= 0:
			_show_death_ui()

## 玩家HP变化回调
func _on_player_hp_changed(current_hp: int, _max_hp: int) -> void:
	if current_hp <= 0 and not is_dead:
		_trigger_death()

## 触发死亡
func _trigger_death() -> void:
	# 联网模式下，服务器角色不触发死亡
	if GameMain.current_mode_id == "online":
		return

	if is_dead:
		return
	
	is_dead = true
	# 设置游戏状态为死亡
	GameState.change_state(GameState.State.PLAYER_DEAD)
	
	# 禁用玩家输入和武器（但不暂停游戏，等待death_delay后再暂停）
	if player:
		# 强制结束无敌状态（如果有）
		if player.has_method("force_end_invincibility"):
			player.force_end_invincibility()
		# 强制停止技能特效（如果有）
		if player.has_method("force_stop_skill_fx"):
			player.force_stop_skill_fx()
		if player.has_method("disable_weapons"):
			player.disable_weapons()
	
	death_timer = death_delay
	death_count += 1  # 增加本局死亡次数
	
	# 增加存档中的总死亡次数
	SaveManager.increment_death_count()
	
	# 记录死亡位置
	if player:
		death_position = player.global_position
	
	# 强制停止之前的救援读条（如果有）
	if grave_instance and is_instance_valid(grave_instance):
		grave_instance.force_stop_reading()
	
	# 创建Ghost数据（用于救援）
	if player:
		# 获取当前地图ID和波次
		var current_map_id = GameMain.current_map_id
		var current_wave = GameMain.current_session.current_wave if GameMain.current_session else 0
		
		grave_ghost_data = GhostData.from_player(player, death_count, current_map_id, current_wave)
		print("[DeathManager] 创建Ghost数据 | 职业:", grave_ghost_data.class_id, " 武器数:", grave_ghost_data.weapons.size(), " 地图:", current_map_id, " 波次:", current_wave)
		
		# Multi模式下：记录到GhostDatabase
		if GameMain.current_mode_id == "multi":
			GhostDatabase.add_ghost_record(grave_ghost_data)
			print("[DeathManager] Multi模式 - 已记录到GhostDatabase")
	
	# 移除旧墓碑（如果有）
	_remove_old_grave()
	
	# 创建新墓碑
	_create_grave()
	
	
	# Multi模式下：清理所有ghost（因为无法复活，必然会离开场景）
	if GameMain.current_mode_id == "multi":
		_cleanup_ghosts_for_multi_mode()
	
	player_died.emit()
	print("[DeathManager] 玩家死亡！", death_delay, "秒后显示死亡界面...")
	print("[DeathManager] 当前复活次数:", revive_count, " 死亡次数:", death_count)

## 创建墓碑
func _create_grave() -> void:
	if not grave_ghost_data:
		push_error("[DeathManager] Ghost数据为空，无法创建墓碑")
		return
	
	# 实例化墓碑场景
	grave_instance = grave_scene.instantiate()
	grave_instance.global_position = death_position
	
	# 添加到场景
	if player and player.get_parent():
		player.get_parent().add_child(grave_instance)
		
		# 设置墓碑数据
		grave_instance.setup(grave_ghost_data, player)
		
		# 连接墓碑信号
		grave_instance.rescue_requested.connect(_on_grave_rescue_requested)
		grave_instance.transcend_requested.connect(_on_grave_transcend_requested)
		grave_instance.rescue_cancelled.connect(_on_grave_rescue_cancelled)
		
		print("[DeathManager] 墓碑已创建于:", death_position)
	else:
		push_warning("[DeathManager] 无法找到合适的父节点放置墓碑")

## 移除墓碑
func _remove_grave() -> void:
	if grave_instance and is_instance_valid(grave_instance):
		grave_instance.cleanup()
		grave_instance = null
		print("[DeathManager] 墓碑已移除")

## 移除旧墓碑（再次死亡时清除上一个墓碑）
func _remove_old_grave() -> void:
	if grave_instance and is_instance_valid(grave_instance):
		grave_instance.cleanup()
		grave_instance = null
		print("[DeathManager] 旧墓碑已移除")

## 墓碑救援请求回调
func _on_grave_rescue_requested(ghost_data: GhostData) -> void:
	print("[DeathManager] 收到墓碑救援请求")
	
	# 检查masterkey
	if GameMain.master_key < 2:
		print("[DeathManager] Master Key不足")
		_restore_game_state_after_rescue()
		return
	
	# 消耗masterkey
	GameMain.master_key -= 2
	print("[DeathManager] 消耗2个Master Key，剩余:", GameMain.master_key)
	
	# 创建Ghost
	_create_ghost_from_grave(ghost_data)
	
	# 清除墓碑
	_remove_grave()
	
	# 恢复游戏状态
	_restore_game_state_after_rescue()
	
	print("[DeathManager] 救援完成")

## 墓碑超度请求回调
func _on_grave_transcend_requested(_ghost_data: GhostData) -> void:
	print("[DeathManager] 收到墓碑超度请求")
	
	# 清除墓碑
	_remove_grave()
	
	# 恢复游戏状态
	_restore_game_state_after_rescue()
	
	print("[DeathManager] 超度完成")

## 墓碑救援取消回调
func _on_grave_rescue_cancelled() -> void:
	print("[DeathManager] 墓碑救援取消")
	# 状态恢复已在Grave中处理

## 恢复游戏状态（救援/超度后）
func _restore_game_state_after_rescue() -> void:
	if GameState.previous_state == GameState.State.WAVE_FIGHTING or GameState.previous_state == GameState.State.WAVE_CLEARING:
		GameState.change_state(GameState.previous_state)
	else:
		GameState.change_state(GameState.State.WAVE_FIGHTING)

## 从墓碑数据创建Ghost
func _create_ghost_from_grave(ghost_data: GhostData) -> void:
	if not ghost_data:
		push_error("[DeathManager] Ghost数据为空")
		return
	
	print("[DeathManager] 开始创建Ghost，职业:", ghost_data.class_id, " 武器数:", ghost_data.weapons.size())
	
	# 获取GhostManager
	var ghost_manager = get_tree().get_first_node_in_group("ghost_manager")
	if not ghost_manager:
		push_error("[DeathManager] 找不到GhostManager")
		return
	
	# 创建Ghost
	var ghost_scene_res = load("res://scenes/players/ghost.tscn")
	var new_ghost = ghost_scene_res.instantiate()
	
	# 设置Ghost数据（在add_child之前）
	new_ghost.class_id = ghost_data.class_id
	new_ghost.ghost_weapons = ghost_data.weapons.duplicate()
	
	# 设置Ghost的名字和死亡次数
	new_ghost.set_name_from_ghost_data(ghost_data.player_name, ghost_data.total_death_count)
	
	# 设置初始位置
	if grave_instance and is_instance_valid(grave_instance):
		new_ghost.global_position = grave_instance.global_position
	elif death_position != Vector2.ZERO:
		new_ghost.global_position = death_position
	
	# 添加到场景
	get_tree().root.add_child(new_ghost)
	
	# 准备目标
	var follow_target = player
	var queue_index = 0
	
	if ghost_manager.ghosts.size() > 0:
		follow_target = ghost_manager.ghosts[ghost_manager.ghosts.size() - 1]
		queue_index = ghost_manager.ghosts.size()
	
	# 添加到GhostManager
	ghost_manager.ghosts.append(new_ghost)
	
	# 初始化Ghost
	if follow_target:
		var player_speed = ghost_manager._get_player_speed() if ghost_manager.has_method("_get_player_speed") else 400.0
		new_ghost.call_deferred("initialize", follow_target, queue_index, player_speed, true)
	
	print("[DeathManager] Ghost创建成功！职业:", ghost_data.class_id, " 武器数:", ghost_data.weapons.size())

## 显示死亡UI
func _show_death_ui() -> void:
	if not death_ui:
		push_error("[DeathManager] 死亡UI未设置！")
		return
	
	# 安全检查
	var tree = get_tree()
	if tree == null:
		return
	
	# 暂停游戏
	tree.paused = true
	
	# 显示死亡界面（传入当前模式，death_ui会自己检查master_key）
	var current_mode = GameMain.current_mode_id
	death_ui.show_death_screen(revive_count, current_mode)
	
	var current_master_key = GameMain.master_key
	print("[DeathManager] 显示死亡UI | 模式:", current_mode, " 主钥匙:", current_master_key, " 复活费用: 2")

## 复活请求
func _on_revive_requested() -> void:
	# 固定复活费用：2个masterkey
	var cost = 2
	
	# 检查主钥匙是否足够
	if GameMain.master_key < cost:
		push_warning("[DeathManager] 主钥匙不足，无法复活")
		return
	
	# 扣除主钥匙
	GameMain.remove_master_key(cost)
	
	# 增加复活次数
	revive_count += 1
	
	# 复活玩家
	_revive_player()
	
	print("[DeathManager] 玩家复活！花费:", cost, " 个主钥匙，剩余主钥匙:", GameMain.master_key, " 累计复活次数:", revive_count)

## 放弃请求
func _on_give_up_requested() -> void:
	print("[DeathManager] 玩家放弃游戏")

	_stop_network_if_online("give_up")

	# 停止计时器（最高波次记录已在波次完成时统一处理）
	_stop_timer_on_game_end()
	
	# 移除墓碑
	_remove_grave()
	
	# 恢复游戏（需要在切换场景前恢复）
	get_tree().paused = false
	
	# 发出游戏结束信号
	game_over.emit()
	
	# 直接使用安全的场景切换（带清理）
	SceneCleanupManager.change_scene_safely("res://scenes/UI/main_title.tscn")

## 再战请求
func _on_restart_requested() -> void:
	var current_mode = GameMain.current_mode_id
	print("[DeathManager] 玩家再战 | 当前模式:", current_mode)

	_stop_network_if_online("restart")
	
	# 停止计时器（最高波次记录已在波次完成时统一处理）
	_stop_timer_on_game_end()
	
	# 移除墓碑
	_remove_grave()
	
	# 恢复游戏（需要在切换场景前恢复）
	get_tree().paused = false
	
	# 发出游戏结束信号
	game_over.emit()
	
	# 直接使用安全的场景切换（带清理，保留模式）
	SceneCleanupManager.change_scene_safely_keep_mode("res://scenes/UI/Class_choose.tscn")

## 复活玩家
func _revive_player() -> void:
	if not player:
		return
	
	# 注意：不移除墓碑！墓碑保留用于救援
	
	# 恢复HP
	player.now_hp = player.max_hp
	player.hp_changed.emit(player.now_hp, player.max_hp)
	
	# 随机复活位置
	_respawn_player_at_random_position()
	
	player.stop = false
	
	# 显示玩家
	player.visible = true
	
	# 启用武器
	if player.has_method("enable_weapons"):
		player.enable_weapons()
	
	# 更新名字显示（因为死亡次数已经增加了）
	if player.has_method("_update_name_label"):
		player._update_name_label()
	
	# 重置死亡状态
	is_dead = false
	death_timer = 0.0
	
	# 恢复游戏状态
	GameState.change_state(GameState.State.WAVE_FIGHTING)
	
	# 恢复游戏
	var tree = get_tree()
	if tree:
		tree.paused = false
	
	# 发出复活信号
	player_revived.emit()
	
	# 启动复活无敌效果（3秒无敌 + 金黄色特效）
	if player.has_method("start_revive_invincibility"):
		player.start_revive_invincibility()
	
	print("[DeathManager] 玩家已复活 | HP:", player.now_hp, "/", player.max_hp, " 位置:", player.global_position)
	print("[DeathManager] 墓碑保留用于救援")
	print("[DeathManager] 复活无敌已启动")

## 在随机位置复活玩家
func _respawn_player_at_random_position() -> void:
	if not player or not floor_layer:
		push_warning("[DeathManager] 无法随机复活：player或floor_layer未设置")
		return
	
	var used_cells = floor_layer.get_used_cells()
	if used_cells.is_empty():
		push_warning("[DeathManager] 地图没有可用格子")
		return
	
	# 随机选择一个位置
	var max_attempts = 50
	for attempt in max_attempts:
		var random_cell = used_cells[randi() % used_cells.size()]
		var world_pos = floor_layer.map_to_local(random_cell) * 6  # 假设缩放为6
		
		# 简单检查：确保不在太边缘
		player.global_position = world_pos
		print("[DeathManager] 复活位置:", world_pos)
		return
	
	push_warning("[DeathManager] 未能找到合适的复活位置，使用原地复活")

## 重置游戏数据（仅在放弃时调用）
func _reset_game_data() -> void:
	revive_count = 0
	death_count = 0
	is_dead = false
	death_timer = 0.0
	
	# 清除墓碑和Ghost数据
	_remove_grave()
	grave_ghost_data = null
	
	print("[DeathManager] 死亡管理器数据已重置")

## 获取当前复活次数
func get_revive_count() -> int:
	return revive_count

## 获取下次复活费用
func get_next_revive_cost() -> int:
	# 固定费用：2个masterkey
	return 2

## Multi模式下清理所有ghost
func _cleanup_ghosts_for_multi_mode() -> void:
	print("[DeathManager] Multi模式 - 开始清理Ghost和墓碑")
	
	# 安全检查
	var tree = get_tree()
	if tree == null:
		return
	
	# 查找GhostManager
	var ghost_manager = tree.get_first_node_in_group("ghost_manager")
	if ghost_manager:
		if ghost_manager.has_method("clear_all_ghosts"):
			ghost_manager.clear_all_ghosts()
			print("[DeathManager] Multi模式 - 已清理所有Ghost")
		else:
			print("[DeathManager] Multi模式 - GhostManager没有clear_all_ghosts方法")
	else:
		print("[DeathManager] Multi模式 - 未找到GhostManager")
	
	# 清理Multi模式的墓碑（如果有）
	var graves_manager = tree.get_first_node_in_group("multi_graves_manager")
	if graves_manager:
		if graves_manager.has_method("clear_all_graves"):
			graves_manager.clear_all_graves()
			print("[DeathManager] Multi模式 - 已清理所有Multi墓碑")
		else:
			print("[DeathManager] Multi模式 - MultiGravesManager没有clear_all_graves方法")
	else:
		print("[DeathManager] Multi模式 - 未找到MultiGravesManager（可能正常，取决于wave）")

## 游戏结束时停止计时器
## 注意：最高波次记录已在 game_initializer._on_wave_flow_step 中统一处理
func _stop_timer_on_game_end() -> void:
	if GameMain.current_session:
		GameMain.current_session.stop_timer()

func _stop_network_if_online(context: String) -> void:
	if GameMain.current_mode_id != "online":
		return
	if NetworkManager.has_method("stop_network"):
		print("[DeathManager] 停止网络连接 | 来源:%s" % context)
		NetworkManager.stop_network()
	else:
		print("[DeathManager] 未找到 NetworkManager 或缺少 stop_network 方法 | 来源:%s" % context)
