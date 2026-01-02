extends Node2D
class_name BaseWeapon

## 武器基类（重构版 - 行为组合模式）
## 
## 使用行为组合模式，将武器的攻击方式（行为）与伤害计算（结算）分离
## 
## 核心变化：
##   - 使用 WeaponBehavior 子类处理具体攻击逻辑
##   - 根据 weapon_data.calculation_type 计算伤害加成
##   - 支持"火焰剑"等组合武器（近战行为 + 魔法结算）

@onready var weaponAni: AnimatedSprite2D = $AnimatedSprite2D
@onready var timer: Timer = $Timer
@onready var detection_area: Area2D = $Area2D

## 武器数据
var weapon_data: WeaponData = null

## 敌人列表
var attack_enemies: Array = []

## ===== 行为组合 =====
## 武器行为实例（处理具体的攻击逻辑）
var behavior: WeaponBehavior = null

## ===== 属性系统 =====
## 玩家属性引用（从AttributeManager.final_stats获取）
var player_stats: CombatStats = null

## 武器等级（1-5级）
var weapon_level: int = 1

## ===== 旧系统（已废弃，保留兼容） =====
var damage_multiplier: float = 1.0
var attack_speed_multiplier: float = 1.0
var range_multiplier: float = 1.0

var owner_player: PlayerCharacter = null
var owner_peer_id: int = 0

## 武器等级颜色
const weapon_level_colors = {
	level_1 = "#FFFFFF",
	level_2 = "#00FF00",
	level_3 = "#0000FF",
	level_4 = "#FF00FF",
	level_5 = "#FF0000",
}

## 初始化武器
func initialize(data: WeaponData, level: int = 1) -> void:
	weapon_data = data
	weapon_level = clamp(level, 1, 5)
	
	if weapon_data == null:
		push_error("[BaseWeapon] 武器数据为空！")
		return
	
	# 确保在场景树中
	if not is_inside_tree():
		push_error("[BaseWeapon] initialize() 调用时节点不在场景树中")
		return
	
	# 确保@onready节点已准备好
	_ensure_nodes_ready()
	
	if not weaponAni or not timer or not detection_area:
		push_error("[BaseWeapon] initialize() 时关键节点缺失")
		return
	
	# 创建行为实例
	_create_behavior()
	
	# 刷新武器属性
	refresh_weapon_stats()
	
	# 设置武器贴图
	_setup_weapon_appearance()
	
	# 设置武器等级颜色和描边
	_update_weapon_level_appearance()
	
	# 调用子类的初始化
	_on_weapon_initialized()

## 创建行为实例
func _create_behavior() -> void:
	if not weapon_data:
		return
	
	# 获取行为参数
	var behavior_params = weapon_data.get_behavior_params()
	
	# 根据行为类型创建对应的行为实例
	match weapon_data.behavior_type:
		WeaponData.BehaviorType.MELEE:
			behavior = MeleeBehavior.new()
		WeaponData.BehaviorType.RANGED:
			behavior = RangedBehavior.new()
		WeaponData.BehaviorType.MAGIC:
			# 添加武器名称到参数（用于特效）
			behavior_params["weapon_name"] = weapon_data.weapon_name
			behavior = MagicBehavior.new()
		_:
			push_error("[BaseWeapon] 未知的行为类型: %d" % weapon_data.behavior_type)
			return
	
	# 初始化行为
	behavior.initialize(
		self,
		behavior_params,
		weapon_data.calculation_type,
		weapon_data.special_effects
	)
	
	# 设置玩家属性和武器等级
	if player_stats:
		behavior.set_player_stats(player_stats)
	behavior.set_weapon_level(weapon_level)

## 确保节点已准备好
func _ensure_nodes_ready() -> void:
	if not weaponAni:
		weaponAni = get_node_or_null("AnimatedSprite2D")
	if not timer:
		timer = get_node_or_null("Timer")
	if not detection_area:
		detection_area = get_node_or_null("Area2D")

## 刷新武器属性
func refresh_weapon_stats() -> void:
	if not weapon_data:
		return
	
	# 更新行为的玩家属性
	if behavior and player_stats:
		behavior.set_player_stats(player_stats)
	
	# 更新攻击间隔
	if timer:
		var final_attack_speed = get_attack_speed()
		timer.wait_time = final_attack_speed
		if not timer.autostart:
			timer.autostart = true
	
	# 更新检测范围
	if detection_area and detection_area.get_child_count() > 0:
		var collision_shape = detection_area.get_child(0)
		if collision_shape is CollisionShape2D:
			var new_shape = CircleShape2D.new()
			new_shape.radius = get_range()
			collision_shape.shape = new_shape

## 获取最终伤害
func get_damage() -> int:
	if behavior:
		return behavior.get_final_damage()
	
	# 降级方案：使用旧逻辑
	if not weapon_data:
		return 0
	
	if weapon_data.damage <= 0:
		return weapon_data.damage
	
	if player_stats:
		return DamageCalculator.calculate_damage_by_calc_type(
			weapon_data.damage,
			weapon_level,
			weapon_data.calculation_type,
			player_stats
		)
	else:
		var multipliers = WeaponData.get_level_multipliers(weapon_level)
		return int(max(1.0, weapon_data.damage * multipliers.damage_multiplier))

## 获取最终攻击速度（攻击间隔）
func get_attack_speed() -> float:
	if behavior:
		return behavior.get_attack_interval()
	
	# 降级方案
	if not weapon_data:
		return 1.0
	
	if player_stats:
		return DamageCalculator.calculate_attack_speed_by_calc_type(
			weapon_data.attack_speed,
			weapon_level,
			weapon_data.calculation_type,
			player_stats
		)
	else:
		var multipliers = WeaponData.get_level_multipliers(weapon_level)
		return weapon_data.attack_speed / multipliers.attack_speed_multiplier

## 获取最终攻击范围
func get_range() -> float:
	if behavior:
		return behavior.get_attack_range()
	
	# 降级方案
	if not weapon_data:
		return 100.0
	
	if player_stats:
		return DamageCalculator.calculate_range_by_calc_type(
			weapon_data.range,
			weapon_level,
			weapon_data.calculation_type,
			player_stats
		)
	else:
		var multipliers = WeaponData.get_level_multipliers(weapon_level)
		return weapon_data.range * multipliers.range_multiplier

## 升级武器等级
func upgrade_level() -> bool:
	if weapon_level >= 5:
		return false
	
	weapon_level += 1
	
	# 更新行为的武器等级
	if behavior:
		behavior.set_weapon_level(weapon_level)
	
	refresh_weapon_stats()
	_update_weapon_level_appearance()
	
	return true

## 设置玩家属性
func set_player_stats(stats: CombatStats) -> void:
	player_stats = stats
	if behavior:
		behavior.set_player_stats(stats)
	refresh_weapon_stats()

## 更新武器等级外观
func _update_weapon_level_appearance() -> void:
	if not weaponAni:
		return
	
	var material = weaponAni.material
	if not material or not material is ShaderMaterial:
		return
	
	var shader_material = material as ShaderMaterial
	var color_hex = WeaponData.weapon_level_colors['level_' + str(weapon_level)]
	var color = Color(color_hex)
	
	shader_material.set_shader_parameter("color", color)

## 设置武器外观
func _setup_weapon_appearance() -> void:
	if weapon_data == null or not weaponAni:
		return
	
	self.scale = weapon_data.scale
	
	if weapon_data.texture_path != "":
		var texture = load(weapon_data.texture_path)
		if texture:
			var sprite_frames = SpriteFrames.new()
			sprite_frames.set_animation_loop("default", true)
			sprite_frames.add_frame("default", texture)
			sprite_frames.set_animation_speed("default", 5.0)
			
			weaponAni.sprite_frames = sprite_frames
			weaponAni.play("default")
			
			if weapon_data.sprite_offset != Vector2.ZERO:
				weaponAni.position = weapon_data.sprite_offset

func _ready() -> void:
	if not is_inside_tree():
		push_error("[BaseWeapon] _ready() 调用时节点不在场景树中")
		return
	
	_ensure_nodes_ready()
	
	if not weaponAni or not timer or not detection_area:
		push_error("[BaseWeapon] 关键节点缺失")
		return
	
	# 连接信号
	if detection_area:
		if not detection_area.body_entered.is_connected(_on_area_2d_body_entered):
			detection_area.body_entered.connect(_on_area_2d_body_entered)
		if not detection_area.body_exited.is_connected(_on_area_2d_body_exited):
			detection_area.body_exited.connect(_on_area_2d_body_exited)
	
	if timer:
		if not timer.timeout.is_connected(_on_timer_timeout):
			timer.timeout.connect(_on_timer_timeout)
	
	# 检查是否有存储的weapon_data
	if has_meta("weapon_data"):
		var stored_data = get_meta("weapon_data")
		var stored_level = get_meta("weapon_level") if has_meta("weapon_level") else 1
		
		# 检查是否有存储的player_stats
		if has_meta("player_stats"):
			player_stats = get_meta("player_stats")
			remove_meta("player_stats")
		
		if stored_data is WeaponData:
			initialize(stored_data, stored_level)
			remove_meta("weapon_data")
			if has_meta("weapon_level"):
				remove_meta("weapon_level")

func _process(delta: float) -> void:
	# 行为的每帧更新
	if behavior:
		behavior.process(delta)
	
	# 非近战武器朝向最近的敌人
	if weapon_data and weapon_data.behavior_type != WeaponData.BehaviorType.MELEE:
		if attack_enemies.size() > 0:
			var target_enemy = attack_enemies[0]
			if is_instance_valid(target_enemy):
				look_at(target_enemy.global_position)
			else:
				attack_enemies.erase(target_enemy)
				sort_enemy()
		else:
			rotation_degrees = 0
	
	# 调用子类的更新逻辑
	_on_weapon_process(delta)

## 计时器超时，执行攻击
func _on_timer_timeout() -> void:
	if attack_enemies.is_empty() or weapon_data == null:
		return
	
	# 获取武器的检测范围（用于二次验证）
	var weapon_range = get_range()
	
	# 清理无效的敌人、死亡的 PvP 目标、以及超出范围的目标
	var before_count = attack_enemies.size()
	attack_enemies = attack_enemies.filter(func(target):
		if not is_instance_valid(target):
			return false
		# 联网模式下，过滤死亡的玩家
		if GameMain.current_mode_id == "online" and target.is_in_group("player"):
			var target_hp = target.get("now_hp")
			if target_hp != null and target_hp <= 0:
				return false
		# 检查目标是否仍在武器范围内（防止 body_exited 未正确触发）
		var distance = global_position.distance_to(target.global_position)
		if distance > weapon_range * 1.2:  # 添加20%容差
			return false
		return true
	)
	var after_count = attack_enemies.size()
	
	if before_count != after_count:
		print("[BaseWeapon] 清理无效/死亡/超出范围目标: %d -> %d" % [before_count, after_count])
	
	if attack_enemies.is_empty():
		return
	
	if GameMain.current_mode_id == "online":
		if not NetworkManager.is_server():
			return
		# 服务器执行攻击（子类负责广播给客户端）
		print("[BaseWeapon] 服务器执行攻击, 目标数量: %d, owner_peer_id: %d" % [attack_enemies.size(), owner_peer_id])
	
	# 使用行为执行攻击
	if behavior:
		behavior.perform_attack(attack_enemies)
	else:
		# 降级：调用子类方法（兼容旧代码）
		_perform_attack()
	
## 敌人进入检测范围
func _on_area_2d_body_entered(body: Node2D) -> void:
	var added = false
	if body.is_in_group("enemy") and not attack_enemies.has(body):
		attack_enemies.append(body)
		sort_enemy()
		added = true
	
	# 联网模式：Boss 玩家也是攻击目标（PvP）
	if NetworkPlayerManager.is_valid_pvp_target(owner_peer_id, body) and not attack_enemies.has(body):
		attack_enemies.append(body)
		sort_enemy()
		added = true
	
	if added and GameMain.current_mode_id == "online" and NetworkManager.is_server():
		print("[BaseWeapon] 目标进入: %s, 目标数: %d, owner: %d" % [body.name, attack_enemies.size(), owner_peer_id])
	
## 敌人离开检测范围
func _on_area_2d_body_exited(body: Node2D) -> void:
	if attack_enemies.has(body):
		attack_enemies.erase(body)
		sort_enemy()
		if GameMain.current_mode_id == "online" and NetworkManager.is_server():
			print("[BaseWeapon] 目标离开: %s, 剩余: %d, owner: %d" % [body.name, attack_enemies.size(), owner_peer_id])




## 排序敌人（按距离）
func sort_enemy() -> void:
	if attack_enemies.size() == 0:
		return
	
	attack_enemies.sort_custom(
		func(x, y):
			if not is_instance_valid(x) or not is_instance_valid(y):
				return false
			return x.global_position.distance_to(self.global_position) < y.global_position.distance_to(self.global_position)
	)

func set_owner_player(player: PlayerCharacter) -> void:
	owner_player = player
	owner_peer_id = player.peer_id if player else 0

## 虚函数：子类实现具体的攻击逻辑（兼容旧代码）
func _perform_attack() -> void:
	pass

## 虚函数：武器初始化时的额外设置
func _on_weapon_initialized() -> void:
	pass

## 虚函数：每帧更新逻辑
func _on_weapon_process(_delta: float) -> void:
	pass

## ===== 兼容旧系统的方法 =====

func set_damage_multiplier(multiplier: float) -> void:
	damage_multiplier = multiplier

func set_attack_speed_multiplier(multiplier: float) -> void:
	attack_speed_multiplier = multiplier
	if timer and weapon_data:
		timer.wait_time = weapon_data.attack_speed / attack_speed_multiplier

func set_range_multiplier(multiplier: float) -> void:
	range_multiplier = multiplier
	if detection_area and detection_area.get_child_count() > 0 and weapon_data:
		var collision_shape = detection_area.get_child(0)
		if collision_shape is CollisionShape2D:
			var shape = collision_shape.shape
			if shape is CircleShape2D:
				var multipliers = WeaponData.get_level_multipliers(weapon_level)
				shape.radius = weapon_data.range * multipliers.range_multiplier * range_multiplier

## 应用特殊效果到目标（兼容旧代码）
func apply_special_effects(target: Node, damage_dealt: int = 0, effect_configs: Array = []) -> void:
	if behavior:
		behavior.apply_special_effects(target, damage_dealt)
		return
	
	if not player_stats:
		return
	
	# 降级方案
	if effect_configs.is_empty() and weapon_data and weapon_data.special_effects:
		effect_configs = weapon_data.special_effects
	
	for effect_config in effect_configs:
		if not effect_config is Dictionary:
			continue
		
		var effect_type = effect_config.get("type", "")
		var effect_params = effect_config.get("params", {}).duplicate()
		
		if effect_type != "lifesteal" and not target:
			continue
		
		if effect_type == "lifesteal":
			effect_params["damage_dealt"] = damage_dealt
			effect_params["attacker"] = get_tree().get_first_node_in_group("player")
		
		SpecialEffects.try_apply_status_effect(player_stats, target, effect_type, effect_params)

## 获取实际伤害（兼容旧代码）
func get_actual_damage() -> int:
	return get_damage()
