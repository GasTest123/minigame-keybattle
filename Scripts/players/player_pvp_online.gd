extends Node
class_name PlayerPvPOnline

## 玩家 PvP 系统（联网模式）
## 管理 Boss 的所有攻击逻辑：冲刺攻击和技能攻击
## Boss 在移动时会自动攻击附近的非 Boss 玩家
## Boss 技能：发射闪电风暴（360度散射子弹）
##
## 所有Boss攻击相关的配置都集中在此文件中

## ==================== Boss 攻击配置 ====================

## 基础伤害配置
const BOSS_DASH_BASE_DAMAGE := 20   # 冲刺基础伤害
const BOSS_SKILL_BASE_DAMAGE := 20  # 技能基础伤害

## Boss 技能参数（闪电风暴）
const BOSS_SKILL_BULLET_COUNT := 12   # 每轮子弹数量
const BOSS_SKILL_BULLET_ROUNDS := 3   # 发射轮数
const BOSS_SKILL_ROUND_INTERVAL := 0.5  # 每轮间隔
const BOSS_SKILL_BULLET_SPEED := 600.0  # 子弹速度
const BOSS_SKILL_COOLDOWN := 15.0       # 技能冷却

## 每波Boss攻击的额外伤害加成（数组索引对应波数-1，超出数组范围使用最后一个值）
## 冲刺最终伤害 = (20 + bonus) × 属性加成，技能最终伤害 = (15 + bonus) × 属性加成
var boss_damage_per_wave: Array[int] = [0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28]

## Boss 冲刺攻击的特殊效果配置（触发减速）
var boss_dash_special_effects: Array = [
	{
		"type": "slow",
		"params": {
			"chance": 0.3,        # 30% 基础触发率（受 status_chance_mult 加成）
			"duration": 2.0,      # 持续2秒（受 status_duration_mult 加成）
			"slow_percent": 0.5   # 减速50%（受 status_effect_mult 加成）
		}
	}
]

## Boss 技能攻击的特殊效果配置（触发燃烧）
var boss_skill_special_effects: Array = [
	{
		"type": "burn",
		"params": {
			"chance": 0.25,        # 25% 基础触发率（受 status_chance_mult 加成）
			"tick_interval": 1.0,  # 每秒伤害一次
			"damage": 5.0,         # 每次5点伤害（受 status_effect_mult 加成）
			"duration": 3.0        # 持续3秒（受 status_duration_mult 加成）
		}
	}
]

## ==================== 行为参数 ====================

## Boss 移动攻击参数（行为参数，与伤害无关）
@export var boss_attack_cooldown: float = 1.0        # 对同一玩家的攻击冷却
@export var boss_attack_range: float = 120.0         # 攻击判定范围
@export var boss_min_speed_for_attack: float = 100.0 # 触发攻击的最小移动速度

## ==================== 内部状态 ====================

## 引用父节点（玩家）
var player: PlayerCharacter = null

## 记录每个玩家的攻击冷却
var _player_attack_cooldowns: Dictionary = {}  # peer_id -> cooldown_timer

## Boss 技能冷却
var _boss_skill_cooldown_remaining := 0.0


func _ready() -> void:
	# 获取父节点（玩家）
	player = get_parent() as PlayerCharacter
	if not player:
		push_error("[PlayerPvPOnline] 父节点不是 PlayerCharacter")
		return


func _process(delta: float) -> void:
	if not player:
		return

	# Boss 死亡后不应继续造成任何伤害（避免死亡瞬间残留 velocity 导致“靠近墓碑还会掉血”）
	# 注意：boss 死亡时 PlayerOnline 会停止移动逻辑，但 velocity 可能保留上一次值。
	if ("now_hp" in player) and int(player.now_hp) <= 0:
		return
	
	# 更新 Boss 技能冷却
	_update_boss_skill_cooldown(delta)
	
	# 只有本地 Boss 玩家才处理攻击逻辑
	if player.is_local_player and player.player_role_id == "boss":
		_update_boss_attack(delta)


## ==================== Boss 冲刺攻击系统 ====================

## 更新 Boss 移动攻击
func _update_boss_attack(delta: float) -> void:
	# 更新所有玩家的攻击冷却
	_update_attack_cooldowns(delta)
	
	# 检查是否在移动（速度足够快）
	var current_speed = player.velocity.length()
	if current_speed < boss_min_speed_for_attack:
		return
	
	# 检测并攻击附近的非 Boss 玩家
	_check_and_attack_nearby_players()


## 更新攻击冷却计时器
func _update_attack_cooldowns(delta: float) -> void:
	var keys_to_remove: Array = []
	
	for peer_id in _player_attack_cooldowns.keys():
		_player_attack_cooldowns[peer_id] -= delta
		if _player_attack_cooldowns[peer_id] <= 0:
			keys_to_remove.append(peer_id)
	
	for peer_id in keys_to_remove:
		_player_attack_cooldowns.erase(peer_id)


## 检测并攻击附近的玩家
func _check_and_attack_nearby_players() -> void:
	for player_peer_id in NetworkPlayerManager.players.keys():
		var target_player = NetworkPlayerManager.players[player_peer_id]
		if not target_player or not is_instance_valid(target_player):
			continue
		
		# 跳过自己
		if target_player == player:
			continue
		
		# 跳过其他 boss
		if target_player.get("player_role_id") == "boss":
			continue
		
		# 跳过已死亡的玩家
		var target_hp = target_player.get("now_hp")
		if target_hp != null and target_hp <= 0:
			continue
		
		# 跳过正在冷却的玩家
		if _player_attack_cooldowns.has(player_peer_id):
			continue
		
		# 检查距离
		var distance = player.global_position.distance_to(target_player.global_position)
		if distance < boss_attack_range:
			# 命中！设置冷却
			_player_attack_cooldowns[player_peer_id] = boss_attack_cooldown
			
			# 计算最终伤害
			var final_damage = calculate_boss_dash_damage()
			print("[Boss] 移动攻击命中玩家: peer_id=%d, damage=%d" % [player_peer_id, final_damage])
			
			# 通知服务器处理伤害和异常效果
			if GameMain.current_mode_id == "online":
				var effects_data = boss_dash_special_effects.duplicate(true)
				rpc_id(1, "rpc_boss_attack_hit", player_peer_id, final_damage, effects_data)


## ==================== Boss 技能系统 ====================

## 激活 Boss 技能（本地调用）
func activate_boss_skill() -> void:
	# 检查冷却
	if _boss_skill_cooldown_remaining > 0:
		print("[PvPOnline] Boss 技能冷却中: %.1f秒" % _boss_skill_cooldown_remaining)
		return
	
	print("[PvPOnline] Boss 激活闪电风暴技能")
	
	# 设置冷却
	_boss_skill_cooldown_remaining = BOSS_SKILL_COOLDOWN
	
	# 播放技能动画，并在完成后恢复走路动画
	_play_skill_animation_and_restore()
	
	# 请求服务器执行技能（服务器负责生成子弹和同步）
	_request_boss_skill.rpc_id(1)


## 播放技能动画并在完成后恢复走路动画
func _play_skill_animation_and_restore() -> void:
	if not player or not player.playerAni:
		return
	
	var ani = player.playerAni
	if not ani.sprite_frames or not ani.sprite_frames.has_animation("skill"):
		return
	
	# 播放技能动画
	ani.play("skill")
	
	# 等待动画完成后恢复
	await ani.animation_finished
	
	# 恢复走路动画
	if is_instance_valid(player) and is_instance_valid(ani):
		player._resume_animation()


## 请求服务器执行 Boss 技能
@rpc("any_peer", "call_remote", "reliable")
func _request_boss_skill() -> void:
	if not NetworkManager.is_server():
		return
	
	var sender_id = multiplayer.get_remote_sender_id()
	if sender_id != player.peer_id:
		return
	
	print("[PvPOnline] 服务器处理 Boss 技能: peer_id=%d" % player.peer_id)
	
	# 广播给所有客户端播放技能动画
	for client_peer_id in multiplayer.get_peers():
		_rpc_play_boss_skill_anim.rpc_id(client_peer_id)
	
	# 服务器执行子弹发射（多轮）
	_server_execute_boss_skill()


## 服务器执行 Boss 技能（发射子弹）
func _server_execute_boss_skill() -> void:
	# 计算最终伤害（使用属性系统）
	var final_damage = _calculate_boss_skill_damage()
	
	# 获取玩家属性（用于异常效果计算）
	var stats = _get_boss_combat_stats()
	
	for round_idx in range(BOSS_SKILL_BULLET_ROUNDS):
		if round_idx > 0:
			await get_tree().create_timer(BOSS_SKILL_ROUND_INTERVAL).timeout
		
		if not is_instance_valid(player):
			return
		
		# 每轮发射 360度 均匀分布的子弹
		var angle_step = TAU / BOSS_SKILL_BULLET_COUNT
		for i in range(BOSS_SKILL_BULLET_COUNT):
			var angle = i * angle_step
			var direction = Vector2(cos(angle), sin(angle))
			var start_pos = player.global_position + direction * 50  # 从玩家位置偏移一点发射
			
			# 使用 NetworkPlayerManager 广播敌人子弹（复用现有系统）
			# 传入 peer_id 作为 owner_peer_id，使子弹不会攻击自己
			# 传入特殊效果和属性，用于触发异常
			NetworkPlayerManager.broadcast_enemy_bullet(
				start_pos,
				direction,
				BOSS_SKILL_BULLET_SPEED,
				final_damage,
				"monitor",  # 子弹类型
				"res://scenes/bullets/monitor_bullet.tscn",  # 使用 monitor 的子弹场景
				player.peer_id,  # 传入 boss 玩家的 peer_id，排除自己
				boss_skill_special_effects,  # 特殊效果配置
				stats  # 玩家属性
			)
		
		print("[PvPOnline] Boss 发射第 %d 轮子弹, damage=%d, owner_peer_id=%d" % [round_idx + 1, final_damage, player.peer_id])


## 客户端播放 Boss 技能动画
@rpc("any_peer", "call_remote", "reliable")
func _rpc_play_boss_skill_anim() -> void:
	# 本地玩家已经执行过了
	if player.is_local_player:
		return
	
	print("[PvPOnline] 播放 Boss 技能动画: peer_id=%d" % player.peer_id)
	
	# 播放技能动画并在完成后恢复
	_play_skill_animation_and_restore()


## 更新 Boss 技能冷却
func _update_boss_skill_cooldown(delta: float) -> void:
	if _boss_skill_cooldown_remaining > 0:
		_boss_skill_cooldown_remaining -= delta
		if _boss_skill_cooldown_remaining < 0:
			_boss_skill_cooldown_remaining = 0


## 获取 Boss 技能剩余冷却时间
func get_boss_skill_cooldown() -> float:
	return _boss_skill_cooldown_remaining


## ==================== 伤害计算 ====================

## 获取当前波数
func _get_current_wave() -> int:
	var wave_system = get_tree().get_first_node_in_group("wave_system")
	if wave_system and "current_wave" in wave_system:
		return wave_system.current_wave
	
	# Fallback：尝试获取 wave_manager
	var wave_manager = get_tree().get_first_node_in_group("wave_manager")
	if wave_manager and "current_wave" in wave_manager:
		return wave_manager.current_wave
	
	return 1


## 获取指定波数的Boss伤害加成
func get_boss_damage_bonus(wave: int) -> int:
	if boss_damage_per_wave.is_empty():
		return 0
	
	# 波数从1开始，数组索引从0开始
	var index = wave - 1
	
	# 如果超出数组范围，使用最后一个值
	if index >= boss_damage_per_wave.size():
		return boss_damage_per_wave[boss_damage_per_wave.size() - 1]
	
	# 如果索引小于0，返回第一个值
	if index < 0:
		return boss_damage_per_wave[0]
	
	return boss_damage_per_wave[index]


## 计算Boss冲刺攻击的最终伤害
## 公式：(基础伤害 + 波数加成) × 属性系统加成
func calculate_boss_dash_damage() -> int:
	var current_wave = _get_current_wave()
	
	# 从数组获取当前波数的伤害加成
	var wave_bonus = get_boss_damage_bonus(current_wave)
	var base_damage = BOSS_DASH_BASE_DAMAGE + wave_bonus
	
	# 获取玩家的属性系统
	if player.attribute_manager and player.attribute_manager.final_stats:
		var stats = player.attribute_manager.final_stats
		# 使用全局伤害加成
		var damage_mult = (1.0 + stats.global_damage_add) * stats.global_damage_mult
		base_damage = int(base_damage * damage_mult)
	
	return max(1, base_damage)


## 计算Boss技能的最终伤害
## 公式：(基础伤害 + 波数加成) × 属性系统加成
func _calculate_boss_skill_damage() -> int:
	var current_wave = _get_current_wave()
	
	# 从数组获取当前波数的伤害加成
	var wave_bonus = get_boss_damage_bonus(current_wave)
	var base_damage = BOSS_SKILL_BASE_DAMAGE + wave_bonus
	
	# 获取玩家的属性系统
	if player.attribute_manager and player.attribute_manager.final_stats:
		var stats = player.attribute_manager.final_stats
		# 使用全局伤害加成
		var damage_mult = (1.0 + stats.global_damage_add) * stats.global_damage_mult
		base_damage = int(base_damage * damage_mult)
	
	return max(1, base_damage)


## 获取Boss的CombatStats（用于异常效果计算）
func _get_boss_combat_stats() -> CombatStats:
	if player.attribute_manager and player.attribute_manager.final_stats:
		return player.attribute_manager.final_stats
	return null


## ==================== RPC 函数 ====================

## RPC：服务器处理 Boss 攻击命中伤害
@rpc("any_peer", "call_remote", "reliable")
func rpc_boss_attack_hit(target_peer_id: int, damage: int, effects_data: Array = []) -> void:
	# 只有服务器处理伤害
	if not NetworkManager.is_server():
		return

	# 安全校验：只能由该 Boss 自己发起；Boss 死亡时忽略（防止客户端残留/作弊调用）
	var sender_id := multiplayer.get_remote_sender_id()
	if player and is_instance_valid(player):
		if sender_id != int(player.peer_id):
			return
		if ("now_hp" in player) and int(player.now_hp) <= 0:
			return
		if ("player_role_id" in player) and str(player.player_role_id) != "boss":
			return
	
	var target_player = NetworkPlayerManager.get_player_by_peer_id(target_peer_id)
	if not target_player or not target_player.has_method("player_hurt"):
		return
	
	# 检查目标是否已死亡
	if target_player.now_hp <= 0:
		return
	
	print("[Server] Boss 攻击伤害: target=%d, damage=%d" % [target_peer_id, damage])
	target_player.player_hurt(damage)
	
	# 应用特殊效果（服务器端处理）
	if not effects_data.is_empty():
		_apply_special_effects_to_target(target_player, effects_data)


## 应用特殊效果到目标玩家
func _apply_special_effects_to_target(target_player: Node, effects_data: Array) -> void:
	var stats: CombatStats = null
	if player and player.attribute_manager and player.attribute_manager.final_stats:
		stats = player.attribute_manager.final_stats
	
	if not stats:
		# 如果没有属性系统，创建一个默认的
		stats = CombatStats.new()
	
	for effect_config in effects_data:
		if not effect_config is Dictionary:
			continue
		
		var effect_type = effect_config.get("type", "")
		var effect_params = effect_config.get("params", {}).duplicate()
		
		# 应用异常效果
		SpecialEffects.try_apply_status_effect(stats, target_player, effect_type, effect_params)


## ==================== 查询方法 ====================

## 是否可以攻击指定玩家（未在冷却中）
func can_attack_player(peer_id: int) -> bool:
	return not _player_attack_cooldowns.has(peer_id)


## 获取对指定玩家的剩余冷却时间
func get_attack_cooldown(peer_id: int) -> float:
	return _player_attack_cooldowns.get(peer_id, 0.0)
