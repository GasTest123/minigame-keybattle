extends CharacterBody2D
class_name EnemyOnline

## 联网模式专用敌人脚本
## 使用 MultiplayerSpawner + MultiplayerSynchronizer 进行同步

var dir = null
var speed = 300
var target = null
var enemyHP = 50  # 当前血量（通过 MultiplayerSynchronizer 同步）
var max_enemyHP = 50  # 最大血量（通过 MultiplayerSynchronizer 同步）

@export var shake_on_death: bool = true
@export var shake_duration: float = 0.2
@export var shake_amount: float = 8.0

## 敌人数据
var enemy_data: EnemyData = null
var enemy_spawner: Node = null
var enemy_id: String = ""  # 敌人类型ID（通过 MultiplayerSynchronizer 同步）

var attack_cooldown: float = 0.0
var attack_interval: float = 1.0
var attack_damage: int = 5

## 击退相关
var knockback_velocity: Vector2 = Vector2.ZERO
var knockback_decay: float = 0.9
var knockback_resistance: float = 0.0  # 击退抗性（0-1，1表示完全免疫）

## 金币掉落数量
var gold_drop_count: int = 1

## 掉落物随机偏移范围
var drop_randf_range_min: float = 20.0
var drop_randf_range_max: float = 60.0

## 停止距离
var stop_distance: float = 100.0

## 是否为本波最后一个敌人（通过 MultiplayerSynchronizer 同步）
var is_last_enemy_in_wave: bool = false

## 当前波次号（通过 MultiplayerSynchronizer 同步）
var current_wave_number: int = 1

## 是否已经死亡（通过 MultiplayerSynchronizer 同步）
var is_dead: bool = false

## 是否无敌
var is_invincible: bool = false

## 技能行为列表
var behaviors: Array[EnemyBehavior] = []

## Buff系统
var buff_system: BuffSystem = null

## 是否正在flash
var is_flashing: bool = false

## 性能优化：shader 状态是否需要更新（事件驱动，避免每帧检查）
var _shader_needs_update: bool = false

## 信号：敌人死亡
signal enemy_killed(enemy_ref: EnemyOnline)

## 目标刷新
var target_refresh_interval: float = 1.0
var _target_refresh_timer: float = 0.0


func _ready() -> void:
	# 初始化Buff系统
	buff_system = BuffSystem.new()
	buff_system.name = "BuffSystem"
	add_child(buff_system)
	buff_system.buff_tick.connect(_on_buff_tick)
	buff_system.buff_applied.connect(_on_buff_applied)
	buff_system.buff_expired.connect(_on_buff_expired)
	
	# 服务器端：数据会在 enemy_spawner 的 add_child 后设置，然后手动调用 _apply_enemy_data()
	if NetworkManager.is_server():
		# 查找目标玩家
		target = _find_nearest_player()
	else:
		# 客户端：延迟加载敌人数据（等待 MultiplayerSynchronizer 同步）
		call_deferred("_client_init")


## 客户端延迟初始化
func _client_init() -> void:
	# 等待多帧确保同步数据到达（网络延迟可能需要更多时间）
	var max_wait_frames = 10
	var waited_frames = 0
	
	while enemy_id == "" and waited_frames < max_wait_frames:
		await get_tree().process_frame
		waited_frames += 1
	
	# 根据同步的 enemy_id 加载敌人数据和外观
	if enemy_id != "":
		_apply_enemy_data_by_id()
	else:
		push_warning("[EnemyOnline] 客户端等待 %d 帧后仍未收到 enemy_id" % waited_frames)


## 处理Buff Tick（DoT伤害）
@warning_ignore("UNUSED_PARAMETER")
func _on_buff_tick(_buff_id: String, tick_data: Dictionary) -> void:
	SpecialEffects.apply_dot_damage(self, tick_data)


## Buff应用时的处理（应用shader效果）
func _on_buff_applied(buff_id: String) -> void:
	_shader_needs_update = true
	_apply_status_shader(buff_id)


## Buff过期时的处理（移除shader效果）
func _on_buff_expired(buff_id: String) -> void:
	_shader_needs_update = true
	_remove_status_shader(buff_id)


## 应用状态shader效果
func _apply_status_shader(buff_id: String) -> void:
	if not $AnimatedSprite2D or not $AnimatedSprite2D.material:
		return
	
	var sprite = $AnimatedSprite2D
	var color_config = SpecialEffects.get_status_color_config(buff_id)
	sprite.material.set_shader_parameter("flash_color", color_config["shader_color"])
	sprite.material.set_shader_parameter("flash_opacity", color_config["shader_opacity"])


## 移除状态shader效果
@warning_ignore("UNUSED_PARAMETER")
func _remove_status_shader(_buff_id: String) -> void:
	if not $AnimatedSprite2D or not $AnimatedSprite2D.material:
		return
	
	# 检查是否还有其他状态效果，按优先级应用
	# 优先级：freeze > slow > burn > bleed > poison
	if buff_system:
		var priority_order = ["freeze", "slow", "burn", "bleed", "poison"]
		for status_id in priority_order:
			if buff_system.has_buff(status_id):
				# 应用优先级最高的状态效果
				_apply_status_shader(status_id)
				return
	
	# 如果没有其他状态效果，恢复原状
	var sprite = $AnimatedSprite2D
	sprite.material.set_shader_parameter("flash_color", Color(1.0, 1.0, 1.0, 1.0))
	sprite.material.set_shader_parameter("flash_opacity", 0.0)


## 检查是否冰冻
func is_frozen() -> bool:
	if not buff_system:
		return false
	return buff_system.has_buff("freeze")


## 获取减速倍数
func get_slow_multiplier() -> float:
	if not buff_system:
		return 1.0
	
	var slow_buff = buff_system.get_buff("slow")
	if not slow_buff or not slow_buff.special_effects.has("slow_multiplier"):
		return 1.0
	
	return slow_buff.special_effects.get("slow_multiplier", 1.0)


## 获取当前最高优先级的异常效果ID
func get_current_status_effect() -> String:
	if not buff_system:
		return ""
	
	var priority_order = ["freeze", "slow", "burn", "bleed", "poison"]
	for status_id in priority_order:
		if buff_system.has_buff(status_id):
			return status_id
	
	return ""


## 性能优化：应用当前状态的 shader 效果（仅在状态变化时调用）
func _apply_current_status_shader() -> void:
	if not $AnimatedSprite2D or not $AnimatedSprite2D.material:
		return
	
	var current_status = get_current_status_effect()
	if current_status != "":
		# 应用当前最高优先级的状态效果
		_apply_status_shader(current_status)
	else:
		# 没有异常效果，恢复原状
		var sprite = $AnimatedSprite2D
		sprite.material.set_shader_parameter("flash_color", Color(1.0, 1.0, 1.0, 1.0))
		sprite.material.set_shader_parameter("flash_opacity", 0.0)


## 初始化敌人（服务器端调用）
func initialize(data: EnemyData, spawner: Node = null) -> void:
	enemy_data = data
	enemy_spawner = spawner
	_apply_enemy_data()


## 根据 enemy_id 加载敌人数据（客户端用）
func _apply_enemy_data_by_id() -> void:
	if enemy_id == "":
		return
	
	enemy_data = EnemyDatabase.get_enemy_data(enemy_id)
	if enemy_data == null:
		push_error("[EnemyOnline] 无法根据 enemy_id 加载敌人数据: %s" % enemy_id)
		return
	
	_apply_enemy_data()


## 应用敌人数据（应用数值属性和外观）
func _apply_enemy_data() -> void:
	if enemy_data == null:
		return
	
	# 设置敌人类型ID
	enemy_id = enemy_data.id
	
	# 应用属性（服务器端设置，客户端从同步数据读取）
	if NetworkManager.is_server():
		max_enemyHP = enemy_data.max_hp
		enemyHP = max_enemyHP
	
	# 应用数值属性
	attack_damage = enemy_data.attack_damage
	speed = enemy_data.move_speed
	attack_interval = enemy_data.attack_interval
	
	# 应用震动设置
	shake_on_death = enemy_data.shake_on_death
	shake_duration = enemy_data.shake_duration
	shake_amount = enemy_data.shake_amount
	
	# 应用击退抗性和掉落设置
	knockback_resistance = enemy_data.knockback_resistance
	gold_drop_count = enemy_data.gold_drop_count
	
	# 加载并应用敌人外观和缩放（从模式1的敌人场景中提取 SpriteFrames 和 scale）
	_load_sprite_frames_from_scene()
	
	# 服务器端初始化技能行为
	if NetworkManager.is_server():
		_setup_skill_behavior()
	
	# 播放默认走路动画
	play_animation("walk")


## 从敌人预制场景中加载 SpriteFrames 和 scale 并应用
func _load_sprite_frames_from_scene() -> void:
	if enemy_data == null or enemy_data.scene_path == "":
		return
	
	var sprite = $AnimatedSprite2D
	if not sprite:
		return
	
	# 加载敌人预制场景
	if not ResourceLoader.exists(enemy_data.scene_path):
		push_warning("[EnemyOnline] 敌人场景不存在: %s" % enemy_data.scene_path)
		return
	
	var scene = load(enemy_data.scene_path) as PackedScene
	if not scene:
		push_warning("[EnemyOnline] 无法加载敌人场景: %s" % enemy_data.scene_path)
		return
	
	# 实例化场景以提取 SpriteFrames 和 scale
	var temp_instance = scene.instantiate()
	if not temp_instance:
		return
	
	# 从单机场景读取 scale 并应用到联网敌人
	if temp_instance is Node2D:
		self.scale = temp_instance.scale
		print("[EnemyOnline] ✓ 应用场景缩放: %s -> %s" % [enemy_data.id, str(temp_instance.scale)])
	
	# 查找 AnimatedSprite2D 节点
	var source_sprite: AnimatedSprite2D = null
	if temp_instance is CharacterBody2D:
		source_sprite = temp_instance.get_node_or_null("AnimatedSprite2D")
	
	if source_sprite and source_sprite.sprite_frames:
		# 复制 SpriteFrames 到当前敌人
		sprite.sprite_frames = source_sprite.sprite_frames
		print("[EnemyOnline] ✓ 已加载敌人外观: %s" % enemy_data.id)
	
	# 清理临时实例
	temp_instance.queue_free()


## 播放指定动画（供 behavior 调用）
## 
## @param anim_key 逻辑动画名（walk/idle/attack/hurt/skill_prepare/skill_execute）
func play_animation(anim_key: String) -> void:
	if not $AnimatedSprite2D:
		return
	
	# 从 enemy_data 获取实际动画名
	var anim_name = anim_key  # 默认使用原名
	if enemy_data and enemy_data.animations.has(anim_key):
		var mapped_name = enemy_data.animations.get(anim_key, "")
		if mapped_name != "" and mapped_name != null:
			anim_name = mapped_name
		else:
			return  # 该敌人没有配置这个动画
	
	# 检查 SpriteFrames 是否有这个动画
	if $AnimatedSprite2D.sprite_frames and $AnimatedSprite2D.sprite_frames.has_animation(anim_name):
		$AnimatedSprite2D.play(anim_name)


## 播放 AnimationPlayer 动画（技能动作）
## 
## @param anim_name AnimationPlayer 中的动画名
func play_skill_animation(anim_name: String) -> void:
	var anim_player = get_node_or_null("AnimationPlayer")
	if anim_player and anim_player.has_animation(anim_name):
		anim_player.play(anim_name)


## 停止 AnimationPlayer 动画
func stop_skill_animation() -> void:
	var anim_player = get_node_or_null("AnimationPlayer")
	if anim_player:
		anim_player.stop()


func _process(delta: float) -> void:
	# 客户端：只处理视觉效果
	if not NetworkManager.is_server():
		# 性能优化：仅在 Buff 状态变化时更新 shader（事件驱动）
		if _shader_needs_update and not is_flashing:
			_apply_current_status_shader()
			_shader_needs_update = false
		_update_facing_direction()
		return
	
	# ========== 以下仅服务器执行 ==========
	
	# 定期刷新目标
	_target_refresh_timer += delta
	if _target_refresh_timer >= target_refresh_interval:
		_target_refresh_timer = 0.0
		target = _find_nearest_player()
	
	# 更新攻击冷却
	if attack_cooldown > 0:
		attack_cooldown -= delta
	
	# 更新击退速度（逐渐衰减）
	knockback_velocity *= knockback_decay
	if knockback_velocity.length() < 10.0:
		knockback_velocity = Vector2.ZERO
	
	# 性能优化：仅在 Buff 状态变化时更新 shader（事件驱动）
	if _shader_needs_update and not is_flashing:
		_apply_current_status_shader()
		_shader_needs_update = false
	
	# 更新技能行为
	for behavior in behaviors:
		if is_instance_valid(behavior):
			behavior.update_behavior(delta)
	
	# 检查是否有技能正在控制移动（如冲锋）
	var is_skill_controlling_movement = false
	for behavior in behaviors:
		if is_instance_valid(behavior) and behavior is ChargingBehavior:
			var charging = behavior as ChargingBehavior
			# 冲刺技能：准备阶段与冲刺阶段都应阻止正常移动
			if charging.state == ChargingBehavior.ChargeState.PREPARING or charging.is_charging_now():
				is_skill_controlling_movement = true
				break
	
	# 正常移动逻辑
	if not is_skill_controlling_movement and target:
		if is_frozen():
			velocity = Vector2.ZERO
			move_and_slide()
			return
		
		var player_distance = global_position.distance_to(target.global_position)
		var attack_range_value = enemy_data.attack_range if enemy_data else 80.0
		var min_distance = attack_range_value - 20.0
		
		if player_distance > min_distance:
			dir = (target.global_position - self.global_position).normalized()
			var current_speed = speed * get_slow_multiplier()
			velocity = dir * current_speed + knockback_velocity
		else:
			velocity = knockback_velocity
		move_and_slide()
		
		_update_facing_direction()
		
		if player_distance < attack_range_value:
			_attack_player()


## 查找最近的玩家
func _find_nearest_player() -> Node:
	var players = NetworkPlayerManager.players
	if players.is_empty():
		return null
	
	var nearest_player: Node = null
	var nearest_distance: float = INF
	
	for peer_id in players.keys():
		var player = players[peer_id]
		if player and is_instance_valid(player):
			# 跳过 boss 角色
			if player.get("player_role_id") == "boss":
				continue
			
			# 检查玩家是否存活
			if player.get("now_hp") != null and player.now_hp <= 0:
				continue
			
			var distance = global_position.distance_to(player.global_position)
			if distance < nearest_distance:
				nearest_distance = distance
				nearest_player = player
	
	return nearest_player


## 更新朝向
func _update_facing_direction() -> void:
	if not target or not $AnimatedSprite2D:
		return
	
	var direction_to_player = target.global_position.x - global_position.x
	
	if direction_to_player > 0:
		$AnimatedSprite2D.flip_h = true
	else:
		$AnimatedSprite2D.flip_h = false


## 攻击玩家（仅服务器）
func _attack_player() -> void:
	if attack_cooldown > 0:
		return
	
	if target and target.has_method("player_hurt"):
		# 跳过 boss 角色
		if target.get("player_role_id") == "boss":
			return
		
		target.player_hurt(attack_damage)
		attack_cooldown = attack_interval


## 敌人受伤（外部调用入口）
func enemy_hurt(hurt: int, is_critical: bool = false, attacker_peer_id: int = 0):
	# 只有服务器处理伤害
	if not NetworkManager.is_server():
		return
	
	if enemy_spawner and enemy_spawner.has_method("notify_enemy_hurt"):
		enemy_spawner.notify_enemy_hurt(self, hurt, is_critical, attacker_peer_id)
	
	# 直接应用伤害（服务器端）
	_apply_damage(hurt, is_critical, attacker_peer_id)


## 应用伤害（服务器端）
func _apply_damage(hurt: int, is_critical: bool = false, attacker_peer_id: int = 0):
	if is_dead:
		return
	
	if is_invincible:
		return
	
	# 检查自爆技能
	for behavior in behaviors:
		if is_instance_valid(behavior) and behavior is ExplodingBehavior:
			var exploding = behavior as ExplodingBehavior
			if exploding.trigger_condition == ExplodingBehavior.ExplodeTrigger.LOW_HP:
				var current_hp_percentage = float(self.enemyHP) / float(self.max_enemyHP)
				var new_hp = self.enemyHP - hurt
				var new_hp_percentage = float(new_hp) / float(self.max_enemyHP)
				
				if current_hp_percentage <= exploding.low_hp_threshold or new_hp_percentage <= exploding.low_hp_threshold:
					if exploding.state == ExplodingBehavior.ExplodeState.IDLE:
						exploding._start_countdown()
					self.enemyHP = max(1, new_hp)
					return
	
	self.enemyHP -= hurt
	
	if hurt <= 0:
		return
	
	# 显示伤害跳字（服务器本地）
	_show_damage_text(hurt, is_critical)
	
	enemy_flash()
	CombatEffectManager.play_enemy_hurt(global_position)
	
	if self.enemyHP <= 0:
		enemy_dead()


## 显示伤害数字
func _show_damage_text(damage: int, is_critical: bool) -> void:
	var text_color = Color(1.0, 1.0, 1.0, 1.0)
	if is_critical:
		text_color = Color(0.2, 0.8, 0.8, 1.0)
	
	var text_content = "-" + str(damage)
	if is_critical:
		text_content = "暴击 -" + str(damage)
	
	FloatingText.create_floating_text(
		global_position + Vector2(0, -30),
		text_content,
		text_color,
		is_critical
	)


## 显示受伤效果（客户端用）
func show_hurt_effect(damage: int, is_critical: bool = false) -> void:
	_show_damage_text(damage, is_critical)
	enemy_flash()
	CombatEffectManager.play_enemy_hurt(global_position)


## 敌人死亡
func enemy_dead():
	if not NetworkManager.is_server():
		return
	
	if enemy_spawner and enemy_spawner.has_method("notify_enemy_dead"):
		enemy_spawner.notify_enemy_dead(self)
	
	_apply_death()


## 应用死亡（服务器端）
func _apply_death():
	if is_dead:
		return
	
	# 检查自爆倒数状态
	for behavior in behaviors:
		if is_instance_valid(behavior) and behavior is ExplodingBehavior:
			var exploding = behavior as ExplodingBehavior
			if exploding.is_in_countdown():
				return
	
	is_dead = true
	
	# 通知自爆技能
	for behavior in behaviors:
		if is_instance_valid(behavior) and behavior is ExplodingBehavior:
			var exploding = behavior as ExplodingBehavior
			exploding.on_enemy_death()
	
	CombatEffectManager.play_enemy_death(global_position)
	
	# 掉落物品（与单机版逻辑一致）
	if is_last_enemy_in_wave:
		# 最后一个敌人掉落 masterkey
		NetworkPlayerManager.spawn_drop("masterkey", self.global_position, Vector2(1, 1))
	else:
		# 普通敌人根据 gold_drop_count 掉落金币
		for i in range(gold_drop_count):
			# 添加随机偏移，防止多个金币重叠
			var offset = Vector2.ZERO
			if gold_drop_count > 1:
				var angle = randf() * TAU
				var distance = randf_range(drop_randf_range_min, drop_randf_range_max)
				offset = Vector2(cos(angle), sin(angle)) * distance
			
			NetworkPlayerManager.spawn_drop("gold", self.global_position + offset, Vector2(1, 1))
	
	enemy_killed.emit(self)
	
	if shake_on_death:
		CameraShake.shake(shake_duration, shake_amount)
	
	self.queue_free()


## 显示死亡效果（客户端用）
func show_death_effect() -> void:
	CombatEffectManager.play_enemy_death(global_position)


## 受伤闪烁
func enemy_flash():
	if not $AnimatedSprite2D or not $AnimatedSprite2D.material:
		return
	
	var sprite = $AnimatedSprite2D
	
	# 标记正在flash
	is_flashing = true
	
	# 白色flash效果（受伤时）
	sprite.material.set_shader_parameter("flash_color", Color(1.0, 1.0, 1.0, 1.0))
	sprite.material.set_shader_parameter("flash_opacity", 0.5)
	
	# 等待0.05秒
	await get_tree().create_timer(0.05).timeout
	
	# 取消flash标记
	is_flashing = false
	
	# 标记需要更新shader（下一帧会恢复正确的状态效果）
	_shader_needs_update = true


## 设置无敌状态
func set_invincible(value: bool) -> void:
	is_invincible = value


## 应用击退（考虑击退抗性）
## @param knockback_force 击退力向量
func apply_knockback(knockback_force: Vector2) -> void:
	# 根据击退抗性减少击退力
	var resistance_multiplier = 1.0 - knockback_resistance
	knockback_velocity += knockback_force * resistance_multiplier


## 设置技能行为（服务器端）
func _setup_skill_behavior() -> void:
	if enemy_data == null:
		return
	
	for behavior in behaviors:
		if is_instance_valid(behavior):
			behavior.queue_free()
	behaviors.clear()
	
	match enemy_data.skill_type:
		EnemyData.EnemySkillType.CHARGING:
			var charging = ChargingBehavior.new()
			add_child(charging)
			charging.initialize(self, enemy_data.skill_config)
			behaviors.append(charging)
		
		EnemyData.EnemySkillType.SHOOTING:
			var shooting = ShootingBehavior.new()
			add_child(shooting)
			shooting.initialize(self, enemy_data.skill_config)
			behaviors.append(shooting)
		
		EnemyData.EnemySkillType.EXPLODING:
			var exploding = ExplodingBehavior.new()
			add_child(exploding)
			exploding.initialize(self, enemy_data.skill_config)
			behaviors.append(exploding)
		
		EnemyData.EnemySkillType.BOSS_SHOOTING:
			var boss_shooting = BossShootingBehavior.new()
			add_child(boss_shooting)
			boss_shooting.initialize(self, enemy_data.skill_config)
			behaviors.append(boss_shooting)
		
		EnemyData.EnemySkillType.NONE:
			pass
