extends Area2D

## 子弹类（重构版）
## 
## 支持多种移动类型和传参执行特效
## 
## 移动类型：
##   - STRAIGHT: 直线飞行
##   - HOMING: 追踪目标
##   - BOUNCE: 弹跳
##   - WAVE: 波浪形

## ========== 导出属性（用于编辑器配置默认值） ==========
@export var speed := 400.0
@export var life_time := 3.0
@export var damage := 10

## ========== 运行时变量 ==========

## 基础属性
var hurt := 1
var dir: Vector2
var _velocity := Vector2.ZERO
var is_critical: bool = false

## 子弹数据
var bullet_data: BulletData = null

## 玩家属性（用于特效）
var player_stats: CombatStats = null

## 特殊效果配置
var special_effects: Array = []

## 结算类型（用于特效伤害计算）
var calculation_type: int = 0

## 穿透计数
var pierce_count: int = 0
var pierced_enemies: Array = []

## 动画状态变量
var _anim_timer: float = 0.0
var _current_frame_index: int = 0
var _total_frames: int = 1

## 生命周期累计（避免大量 create_timer 分配）
var _age: float = 0.0

## ========== 移动相关 ==========

## 移动类型
var movement_type: int = BulletData.MovementType.STRAIGHT

## 移动参数
var movement_params: Dictionary = {}

## 追踪目标
var homing_target: Node2D = null

## WaveSystem 引用缓存（用于复用 active_enemies，避免频繁 get_nodes_in_group 分配）
var _wave_manager_cache: Node = null

## 波浪移动
var wave_time: float = 0.0
var wave_base_position: Vector2 = Vector2.ZERO
var wave_perpendicular: Vector2 = Vector2.ZERO

## 弹跳计数
var bounce_count: int = 0
var max_bounces: int = 3

## ========== 兼容旧版 ==========
var weapon_data: WeaponData = null
var is_visual_only: bool = false  # 客户端视觉子弹（碰撞时只消失，不处理伤害）
var owner_peer_id: int = 0

## 联网同步：每颗子弹的唯一实例 ID（由服务器生成并下发）
var instance_id: String = ""
## 联网同步：是否由服务器驱动轨迹（追踪/弹跳/波浪/螺旋等非直线子弹）
var is_network_driven: bool = false
## 客户端：服务器下发的目标状态（用于插值）
var _net_target_pos: Vector2 = Vector2.ZERO
var _net_target_rot: float = 0.0
var _net_has_state: bool = false
var _net_interp_speed: float = 18.0

## ========== 新版初始化方法 ==========

## 使用配置字典初始化子弹（推荐）
func start_with_config(config: Dictionary) -> void:
	global_position = config.get("position", Vector2.ZERO)
	dir = config.get("direction", Vector2.RIGHT)
	speed = config.get("speed", 2000.0)
	hurt = config.get("damage", 1)
	is_critical = config.get("is_critical", false)
	player_stats = config.get("player_stats", null)
	special_effects = config.get("special_effects", [])
	calculation_type = config.get("calculation_type", 0)
	pierce_count = config.get("pierce_count", 0)
	bullet_data = config.get("bullet_data", null)
	owner_peer_id = config.get("owner_peer_id", 0)
	instance_id = str(config.get("instance_id", ""))
	is_network_driven = bool(config.get("is_network_driven", false))
	
	# 设置移动类型和参数
	if bullet_data:
		movement_type = bullet_data.movement_type
		movement_params = bullet_data.movement_params.duplicate()
		life_time = bullet_data.lifetime
		
		# 设置外观
		_setup_appearance()
	
	# 初始化移动
	_init_movement()
	_age = 0.0
	
	# 暴击效果
	if is_critical:
		#modulate = Color(1.5, 1.5, 1.5)
		scale *= 1.2
	
	# 生命周期：在 _physics_process 中使用 _age 统一管理（避免大量 timer）
	
	# 客户端视觉子弹：禁用碰撞（由服务器决定何时销毁，并通过 despawn 同步）
	if GameMain.current_mode_id == "online" and is_visual_only:
		set_deferred("monitoring", false)
		set_deferred("monitorable", false)
		var cs = get_node_or_null("CollisionShape2D")
		if cs:
			cs.set_deferred("disabled", true)

## ========== 旧版初始化方法（兼容） ==========

func start(pos: Vector2, _dir: Vector2, _speed: float, _hurt: int, _is_critical: bool = false, _player_stats: CombatStats = null, _weapon_data: WeaponData = null, _owner_peer_id: int = 0) -> void:
	global_position = pos
	dir = _dir
	speed = _speed
	hurt = _hurt
	is_critical = _is_critical
	player_stats = _player_stats
	weapon_data = _weapon_data
	owner_peer_id = _owner_peer_id
	
	movement_type = BulletData.MovementType.STRAIGHT
	_velocity = dir * speed
	
	if is_critical:
		#modulate = Color(1.5, 1.5, 1.5)
		scale *= 1.2

	_age = 0.0

## ========== 移动逻辑 ==========

func _init_movement() -> void:
	match movement_type:
		BulletData.MovementType.STRAIGHT:
			_velocity = dir * speed
			# 修正朝向：如果配置了 rotate_to_direction，则旋转子弹朝向飞行方向
			# 子弹素材右侧为正方向（0度），所以直接使用 dir.angle()
			if movement_params.get("rotate_to_direction", false):
				rotation = dir.angle()
		
		BulletData.MovementType.HOMING:
			_velocity = dir * speed
			_find_homing_target()
		
		BulletData.MovementType.BOUNCE:
			_velocity = dir * speed
			max_bounces = movement_params.get("bounce_count", 3)
			# 弹跳子弹默认朝向飞行方向
			rotation = dir.angle()
		
		BulletData.MovementType.WAVE:
			_velocity = dir * speed
			wave_time = 0.0
			wave_base_position = global_position
			wave_perpendicular = dir.rotated(PI / 2)
		
		BulletData.MovementType.SPIRAL:
			_velocity = dir * speed

func _physics_process(delta: float) -> void:
	# 生命周期（统一用 age 计时，避免每颗子弹 create_timer）
	_age += delta
	if _age >= life_time:
		# 联网模式：服务器权威子弹寿命结束，也要同步客户端移除（直线子弹同样需要）
		if GameMain.current_mode_id == "online" and NetworkManager.is_server() and not is_visual_only:
			if instance_id != "" and NetworkPlayerManager and NetworkPlayerManager.has_method("server_despawn_bullet"):
				NetworkPlayerManager.server_despawn_bullet(instance_id)
		queue_free()
		return
	
	# 联网模式：视觉子弹仅展示
	# - 非直线子弹（追踪/弹跳/波浪/螺旋）由服务器权威模拟并下发状态
	# - 客户端只做插值跟随，避免本地寻敌/Time.get_ticks_msec() 等导致轨迹不一致
	if GameMain.current_mode_id == "online" and is_visual_only and is_network_driven:
		# 1. 处理动画播放
		if bullet_data and bullet_data.animation_speed > 0:
			_update_animation(delta)
		
		# 2. 自转（纯视觉）
		if movement_params.has("self_rotation_speed"):
			var sprite = get_node_or_null("Sprite2D")
			if sprite:
				sprite.rotation_degrees += movement_params["self_rotation_speed"] * delta
		
		# 3. 跟随服务器状态（插值）
		if _net_has_state:
			var t := clampf(_net_interp_speed * delta, 0.0, 1.0)
			global_position = global_position.lerp(_net_target_pos, t)
			rotation = lerp_angle(rotation, _net_target_rot, t)
		return

	# 1. 处理动画播放
	if bullet_data and bullet_data.animation_speed > 0:
		_update_animation(delta)

	# 新增：处理自转 (如果子弹需要自转，例如手里剑)
	# 假设我们在 movement_params 里约定了一个 "self_rotation_speed"
	if movement_params.has("self_rotation_speed"):
		var sprite = get_node_or_null("Sprite2D")
		if sprite:
			sprite.rotation_degrees += movement_params["self_rotation_speed"] * delta

	# 2. 处理移动
	match movement_type:
		BulletData.MovementType.STRAIGHT:
			_move_straight(delta)
		
		BulletData.MovementType.HOMING:
			_move_homing(delta)
		
		BulletData.MovementType.BOUNCE:
			_move_straight(delta)
		
		BulletData.MovementType.WAVE:
			_move_wave(delta)
		
		BulletData.MovementType.SPIRAL:
			_move_spiral(delta)

## 直线移动
func _move_straight(delta: float) -> void:
	global_position += _velocity * delta


## 客户端：应用服务器同步的状态（由 NetworkPlayerManager 调用）
func apply_network_state(pos: Vector2, rot: float) -> void:
	_net_target_pos = pos
	_net_target_rot = rot
	_net_has_state = true


func _exit_tree() -> void:
	# 服务器：权威子弹退出树时，广播给客户端移除对应视觉子弹
	if GameMain.current_mode_id == "online" and NetworkManager.is_server() and not is_visual_only:
		if instance_id != "" and NetworkPlayerManager:
			NetworkPlayerManager.server_notify_bullet_freed(instance_id)

## 追踪移动
func _move_homing(delta: float) -> void:
	# 检查目标是否有效
	if not is_instance_valid(homing_target) or homing_target.get("is_dead"):
		_find_homing_target()
	
	# 获取参数
	var turn_speed = movement_params.get("turn_speed", 5.0)     # 转向灵敏度 (现在代表每秒转多少弧度)
	var acceleration = movement_params.get("acceleration", 100.0)
	var max_speed = movement_params.get("max_speed", 2500.0)
	var homing_delay = movement_params.get("homing_delay", 0.0) # 追踪延迟 (秒)
	var wobble_amount = movement_params.get("wobble_amount", 0.0) # 扰动幅度 (度)
	var wobble_freq = movement_params.get("wobble_frequency", 10.0) # 扰动频率
	
	# 处理追踪延迟（先直飞一会）
	if _age < homing_delay:
		# 还在延迟期，只加速不转向
		pass
	elif is_instance_valid(homing_target):
		# 计算目标方向
		var target_dir = (homing_target.global_position - global_position).normalized()
		var current_dir = _velocity.normalized()
		
		# 使用 rotate_toward 限制最大转向角速度 (模拟真实的转弯半径)
		# turn_speed 设为 3.0 ~ 6.0 比较合适
		var angle_diff = current_dir.angle_to(target_dir)
		var rotate_step = sign(angle_diff) * min(abs(angle_diff), turn_speed * delta)
		var new_dir = current_dir.rotated(rotate_step)
		
		dir = new_dir.normalized()

	# 加速
	speed = min(speed + acceleration * delta, max_speed)
	
	# 计算最终速度方向（包含扰动）
	var final_dir = dir
	if wobble_amount > 0:
		# 添加正弦波扰动
		var wobble = sin(Time.get_ticks_msec() / 1000.0 * wobble_freq) * deg_to_rad(wobble_amount)
		final_dir = dir.rotated(wobble)
	
	_velocity = final_dir * speed
	
	# 旋转子弹朝向
	rotation = final_dir.angle()
	
	global_position += _velocity * delta

## 波浪移动
func _move_wave(delta: float) -> void:
	wave_time += delta
	
	var amplitude = movement_params.get("amplitude", 40.0)
	var frequency = movement_params.get("frequency", 4.0)
	
	# 沿基础方向移动
	wave_base_position += dir * speed * delta
	
	# 计算波浪偏移
	var wave_offset = sin(wave_time * frequency) * amplitude
	global_position = wave_base_position + wave_perpendicular * wave_offset

## 螺旋移动
func _move_spiral(delta: float) -> void:
	var spiral_speed = movement_params.get("spiral_speed", 360.0)
	# 预留：未来用于半径螺旋轨迹
	
	# 旋转方向
	dir = dir.rotated(deg_to_rad(spiral_speed * delta))
	_velocity = dir * speed
	
	global_position += _velocity * delta

## 查找追踪目标
func _find_homing_target() -> void:
	var enemies = _get_homing_candidates()
	var closest_dist: float = INF
	homing_target = null

	# 可选：限制寻敌半径，避免全场扫描（默认 INF = 不限制）
	var search_range: float = float(movement_params.get("homing_search_range", INF))
	var limit_by_range: bool = search_range < INF
	
	for enemy in enemies:
		if not is_instance_valid(enemy):
			continue
		# 兼容：敌人脚本里有 is_dead 字段
		if enemy.get("is_dead"):
			continue
		
		if not (enemy is Node2D):
			continue
		var e := enemy as Node2D
		var dist: float = global_position.distance_to(e.global_position)
		if limit_by_range and dist > search_range:
			continue
		if dist < closest_dist:
			closest_dist = dist
			homing_target = e


## 获取追踪寻敌候选列表：优先 WaveSystemV3.active_enemies，回退到 group("enemy")
func _get_homing_candidates() -> Array:
	# 缓存 wave_manager
	if _wave_manager_cache == null or not is_instance_valid(_wave_manager_cache):
		var tree := get_tree()
		if tree:
			_wave_manager_cache = tree.get_first_node_in_group("wave_manager")

	if _wave_manager_cache and is_instance_valid(_wave_manager_cache):
		# WaveSystemV3 有 active_enemies 字段
		if "active_enemies" in _wave_manager_cache:
			var arr = _wave_manager_cache.get("active_enemies")
			if arr is Array:
				return arr

	# 回退：从组里拿（会产生数组分配）
	return get_tree().get_nodes_in_group("enemy")

## ========== 外观设置 ==========

func _setup_appearance() -> void:
	if not bullet_data:
		return
	
	# 设置缩放
	scale = bullet_data.scale
	
	# 设置颜色
	modulate = bullet_data.modulate
	
	# 设置贴图（如果有 Sprite2D 子节点）
	var sprite = get_node_or_null("Sprite2D")
	if sprite and bullet_data.texture_path != "":
		var texture = load(bullet_data.texture_path)
		if texture:
			sprite.texture = texture
			
			# 设置序列帧属性
			sprite.hframes = bullet_data.hframes
			sprite.vframes = bullet_data.vframes
			sprite.frame = 0
			
			# 初始化动画状态
			_total_frames = bullet_data.hframes * bullet_data.vframes
			_current_frame_index = 0
			_anim_timer = 0.0
	
	# 新增：加载挂载特效（如拖尾、旋转光圈等）
	# 检查拖尾效果是否启用
	if bullet_data.trail_effect_path != "" and SaveManager.get_trail_enabled():
		var effect_scene = load(bullet_data.trail_effect_path)
		if effect_scene:
			var effect_instance = effect_scene.instantiate()
			add_child(effect_instance)
			# 确保特效在子弹图层之下（如果需要）
			# move_child(effect_instance, 0) 

## ========== 碰撞处理 ==========

func _on_body_shape_entered(body_rid: RID, body: Node2D, body_shape_index: int, local_shape_index: int) -> void:
	if GameMain.current_mode_id == "online":
		_handle_collision_online(body)
	else:
		_handle_collision_offline(body)


## 联网模式：使用 NetworkPlayerManager 统一处理碰撞
func _handle_collision_online(body: Node2D) -> void:
	var result = NetworkPlayerManager.handle_bullet_collision(owner_peer_id, body, hurt, is_critical, is_visual_only)

	match result:
		NetworkPlayerManager.BulletHitResult.IGNORE:
			# 忽略碰撞，继续飞行
			return

		NetworkPlayerManager.BulletHitResult.DESTROY:
			# 销毁子弹（视觉效果或无效目标）
			# 联网模式：服务器权威子弹销毁需要同步客户端移除（直线子弹同样需要）
			if GameMain.current_mode_id == "online" and NetworkManager.is_server() and not is_visual_only:
				if instance_id != "" and NetworkPlayerManager and NetworkPlayerManager.has_method("server_despawn_bullet"):
					NetworkPlayerManager.server_despawn_bullet(instance_id)
			queue_free()
			return

		NetworkPlayerManager.BulletHitResult.HIT_PLAYER:
			# 命中玩家，伤害已处理，应用武器特效
			_apply_weapon_effects(body)
			if GameMain.current_mode_id == "online" and NetworkManager.is_server() and not is_visual_only:
				if instance_id != "" and NetworkPlayerManager and NetworkPlayerManager.has_method("server_despawn_bullet"):
					NetworkPlayerManager.server_despawn_bullet(instance_id)
			queue_free()
			return

		NetworkPlayerManager.BulletHitResult.HIT_ENEMY:
			# 命中敌人，处理伤害和特效
			_deal_damage_to_enemy(body)
			if GameMain.current_mode_id == "online" and NetworkManager.is_server() and not is_visual_only:
				if instance_id != "" and NetworkPlayerManager and NetworkPlayerManager.has_method("server_despawn_bullet"):
					NetworkPlayerManager.server_despawn_bullet(instance_id)
			queue_free()
			return

	# 默认销毁
	if GameMain.current_mode_id == "online" and NetworkManager.is_server() and not is_visual_only:
		if instance_id != "" and NetworkPlayerManager and NetworkPlayerManager.has_method("server_despawn_bullet"):
			NetworkPlayerManager.server_despawn_bullet(instance_id)
	queue_free()


## 单机模式：直接处理敌人碰撞
func _handle_collision_offline(body: Node2D) -> void:
	# 忽略玩家（单机模式下不应碰到玩家就消失）
	if body.is_in_group("player"):
		return

	if body.is_in_group("enemy"):
		_deal_damage_to_enemy(body)

	# 碰撞后销毁子弹
	queue_free()


## 处理敌人伤害
func _deal_damage_to_enemy(enemy: Node2D) -> void:
	if enemy.has_method("enemy_hurt"):
		if GameMain.current_mode_id == "online":
			enemy.enemy_hurt(hurt, is_critical, owner_peer_id)
		else:
			enemy.enemy_hurt(hurt, is_critical)

	# 应用武器特效
	_apply_weapon_effects(enemy)


## 应用武器特效到目标（敌人或玩家）
func _apply_weapon_effects(target: Node2D) -> void:
	if not player_stats:
		return

	# 优先使用weapon_data中的特殊效果配置
	var effect_configs: Array = []
	if weapon_data and not weapon_data.special_effects.is_empty():
		effect_configs = weapon_data.special_effects

	# 应用每个效果
	for effect_config in effect_configs:
		if not effect_config is Dictionary:
			continue

		var effect_type = effect_config.get("type", "")
		var effect_params = effect_config.get("params", {})

		# 如果是吸血效果，需要传递伤害和攻击者
		if effect_type == "lifesteal":
			var attacker = NetworkPlayerManager.get_player_by_peer_id(owner_peer_id)
			if not attacker:
				attacker = get_tree().get_first_node_in_group("player")
			effect_params["damage_dealt"] = hurt
			effect_params["attacker"] = attacker

		# 应用效果
		SpecialEffects.try_apply_status_effect(player_stats, target, effect_type, effect_params)

	# 如果没有weapon_data配置，使用旧的player_stats逻辑（兼容性）
	if effect_configs.is_empty():
		# 吸血效果
		if player_stats.lifesteal_percent > 0:
			var attacker = NetworkPlayerManager.get_player_by_peer_id(owner_peer_id)
			if not attacker:
				attacker = get_tree().get_first_node_in_group("player")
			SpecialEffects.try_apply_status_effect(player_stats, null, "lifesteal", {
				"attacker": attacker,
				"damage_dealt": hurt,
				"percent": player_stats.lifesteal_percent
			})

		# 状态效果（使用统一方法）
		if player_stats.burn_chance > 0:
			SpecialEffects.try_apply_status_effect(player_stats, target, "burn", {
				"chance": player_stats.burn_chance,
				"tick_interval": 1.0,
				"damage": player_stats.burn_damage_per_second,
				"duration": 3.0
			})

		if player_stats.freeze_chance > 0:
			SpecialEffects.try_apply_status_effect(player_stats, target, "freeze", {
				"chance": player_stats.freeze_chance,
				"duration": 2.0
			})

		if player_stats.poison_chance > 0:
			SpecialEffects.try_apply_status_effect(player_stats, target, "poison", {
				"chance": player_stats.poison_chance,
				"tick_interval": 1.0,
				"damage": 5.0,
				"duration": 5.0
			})

## 播放击中特效
func _play_hit_effect() -> void:
	if not bullet_data:
		return
	
	# 检查是否配置了击中特效
	if bullet_data.hit_effect_scene_path == "" or bullet_data.hit_effect_ani_name == "":
		return
	
	# 在子弹当前位置播放击中特效
	CombatEffectManager.play_bullet_hit(
		bullet_data.hit_effect_scene_path,
		bullet_data.hit_effect_ani_name,
		global_position,
		bullet_data.hit_effect_scale
	)

## 应用击退效果
func _apply_knockback(enemy: Node2D) -> void:
	if not bullet_data:
		return
	
	# 获取基础击退力
	var base_knockback = bullet_data.knockback_force
	if base_knockback <= 0:
		return
	
	# 计算最终击退力（受玩家属性加成影响）
	var final_knockback = base_knockback
	if player_stats:
		final_knockback = DamageCalculator.calculate_knockback(base_knockback, player_stats)
	
	if final_knockback <= 0:
		return
	
	# 计算击退方向（从子弹飞行方向）
	var knockback_dir = dir.normalized()
	
	# 应用击退
	if enemy is CharacterBody2D:
		if enemy.has_method("apply_knockback"):
			# 优先使用 apply_knockback 方法（会自动应用击退抗性）
			enemy.apply_knockback(knockback_dir * final_knockback)
		elif "knockback_velocity" in enemy:
			# 备用方案：手动考虑击退抗性
			var resistance = enemy.knockback_resistance if "knockback_resistance" in enemy else 0.0
			var resistance_multiplier = 1.0 - resistance
			enemy.knockback_velocity += knockback_dir * final_knockback * resistance_multiplier
		elif "velocity" in enemy:
			enemy.velocity += knockback_dir * final_knockback

## 应用特效到目标
func _apply_effects_to_target(target: Node) -> void:
	if not player_stats:
		return
	
	# 优先使用配置的特殊效果
	var effects_to_apply = special_effects
	
	# 兼容旧版：从 weapon_data 获取
	if effects_to_apply.is_empty() and weapon_data and not weapon_data.special_effects.is_empty():
		effects_to_apply = weapon_data.special_effects
	
	# 应用每个效果
	for effect_config in effects_to_apply:
		if not effect_config is Dictionary:
			continue
		
		var effect_type = effect_config.get("type", "")
		var effect_params = effect_config.get("params", {}).duplicate()
		
		# 吸血效果需要传递伤害和攻击者
		if effect_type == "lifesteal":
			var player = get_tree().get_first_node_in_group("player")
			effect_params["damage_dealt"] = hurt
			effect_params["attacker"] = player
		
		SpecialEffects.try_apply_status_effect(player_stats, target, effect_type, effect_params)
	
	# 兼容旧版：使用 player_stats 中的效果
	if effects_to_apply.is_empty():
		_apply_legacy_effects(target)

## 旧版特效应用（兼容）
func _apply_legacy_effects(target: Node) -> void:
	if not player_stats:
		return
	
	# 吸血
	if player_stats.lifesteal_percent > 0:
		var player = get_tree().get_first_node_in_group("player")
		SpecialEffects.try_apply_status_effect(player_stats, null, "lifesteal", {
			"attacker": player,
			"damage_dealt": hurt,
			"percent": player_stats.lifesteal_percent
		})
	
	# 燃烧
	if player_stats.burn_chance > 0:
		SpecialEffects.try_apply_status_effect(player_stats, target, "burn", {
			"chance": player_stats.burn_chance,
			"tick_interval": 1.0,
			"damage": player_stats.burn_damage_per_second,
			"duration": 3.0
		})
	
	# 冰冻
	if player_stats.freeze_chance > 0:
		SpecialEffects.try_apply_status_effect(player_stats, target, "freeze", {
			"chance": player_stats.freeze_chance,
			"duration": 2.0
		})
	
	# 中毒
	if player_stats.poison_chance > 0:
		SpecialEffects.try_apply_status_effect(player_stats, target, "poison", {
			"chance": player_stats.poison_chance,
			"tick_interval": 1.0,
			"damage": 5.0,
			"duration": 5.0
		})

## ========== 弹跳处理 ==========

func _handle_bounce() -> void:
	if bounce_count >= max_bounces:
		queue_free()
		return
	
	bounce_count += 1
	
	# 反射速度
	var bounce_loss = movement_params.get("bounce_loss", 0.9)
	_velocity = _velocity.bounce(Vector2.UP) * bounce_loss  # 简化：假设垂直反弹
	dir = _velocity.normalized()
	speed *= bounce_loss

func _handle_bounce_to_enemy() -> void:
	if bounce_count >= max_bounces:
		queue_free()
		return
	
	bounce_count += 1
	
	# 寻找下一个目标
	var search_range = movement_params.get("search_range", 300.0)
	var enemies = get_tree().get_nodes_in_group("enemy")
	var closest_enemy: Node2D = null
	var closest_dist = search_range
	
	for enemy in enemies:
		if not is_instance_valid(enemy) or enemy.get("is_dead"):
			continue
		if pierced_enemies.has(enemy):
			continue
		
		var dist = global_position.distance_to(enemy.global_position)
		if dist < closest_dist:
			closest_dist = dist
			closest_enemy = enemy
	
	if closest_enemy:
		dir = (closest_enemy.global_position - global_position).normalized()
		var bounce_loss = movement_params.get("bounce_loss", 0.9)
		speed *= bounce_loss
		_velocity = dir * speed
		# 弹跳后更新朝向
		rotation = dir.angle()
	else:
		queue_free()

## 新增：动画更新函数
func _update_animation(delta: float) -> void:
	var sprite = get_node_or_null("Sprite2D")
	if not sprite: return
	
	_anim_timer += delta
	var frame_duration = 1.0 / bullet_data.animation_speed
	
	if _anim_timer >= frame_duration:
		_anim_timer -= frame_duration
		_current_frame_index += 1
		
		# 循环或停在最后一帧
		if _current_frame_index >= _total_frames:
			if bullet_data.loop_animation:
				_current_frame_index = 0
			else:
				_current_frame_index = _total_frames - 1
		
		sprite.frame = _current_frame_index
