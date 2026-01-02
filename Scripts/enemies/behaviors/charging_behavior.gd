extends EnemyBehavior
class_name ChargingBehavior

## 冲锋技能行为
## 当玩家在触发距离内时，敌人会高速冲向玩家

## 状态
enum ChargeState {
	IDLE,      # 待机，正常移动
	PREPARING, # 准备冲锋（短暂延迟）
	CHARGING,  # 冲锋中
	COOLDOWN   # 冷却中
}

var state: ChargeState = ChargeState.IDLE

## 配置参数（从config字典读取）
var trigger_distance: float = 500.0  # 触发距离
var charge_speed: float = 800.0     # 冲锋速度
var charge_distance: float = 600.0  # 冲锋距离
var cooldown: float = 3.0           # 冷却时间
var extra_damage: int = 10          # 冲锋命中额外伤害
var prepare_time: float = 0.3       # 准备时间
var hit_range: float = 0.0          # 冲锋命中范围（0表示使用attack_range）

## 指示器
var indicator_node: Node2D = null  # 可以是 Sprite2D 或 AnimatedSprite2D
var indicator_texture: Texture2D = null  # 静态纹理（可拖拽配置）
var indicator_sprite_frames: SpriteFrames = null  # 动画帧（可拖拽配置）
var indicator_animation: String = "default"  # 动画名称
var indicator_scale: Vector2 = Vector2.ONE  # 指示器缩放
const DEFAULT_INDICATOR_TEXTURE_PATH: String = "res://assets/skill_indicator/charging-range-rect.png"

## 状态计时器
var state_timer: float = 0.0

## 冲锋相关
var charge_start_pos: Vector2 = Vector2.ZERO
var charge_direction: Vector2 = Vector2.ZERO
var is_charging: bool = false
var original_knockback_resistance: float = 0.0  # 保存原始击退抗性
var has_hit_player: bool = false  # 本次冲锋是否已经命中玩家（防止多次伤害）

func _on_initialize() -> void:
	# 从配置中读取参数
	trigger_distance = config.get("trigger_distance", 500.0)
	charge_speed = config.get("charge_speed", 800.0)
	charge_distance = config.get("charge_distance", 600.0)
	cooldown = config.get("cooldown", 3.0)
	extra_damage = config.get("extra_damage", 10)
	prepare_time = config.get("prepare_time", 0.3)
	hit_range = config.get("hit_range", 0.0)  # 0表示使用attack_range
	
	# 加载指示器配置（支持拖拽资源）
	# 优先使用动画帧，其次使用静态纹理
	indicator_sprite_frames = config.get("indicator_sprite_frames", null)
	indicator_animation = config.get("indicator_animation", "default")
	indicator_texture = config.get("indicator_texture", null)
	
	# 如果都没配置，使用默认静态纹理
	if indicator_sprite_frames == null and indicator_texture == null:
		indicator_texture = load(DEFAULT_INDICATOR_TEXTURE_PATH)
	
	# 读取缩放参数
	var scale_value = config.get("indicator_scale", 1.0)
	if scale_value is Vector2:
		indicator_scale = scale_value
	else:
		indicator_scale = Vector2(scale_value, scale_value)
	
	# 刷新创建时默认进入冷却，避免怪物生成后立刻触发冲锋
	state = ChargeState.COOLDOWN
	state_timer = cooldown
	is_charging = false
	_hide_indicator()

func _on_update(delta: float) -> void:
	if not enemy or enemy.is_dead:
		# 敌人死亡时隐藏指示器
		_hide_indicator()
		return
	
	# 联网模式下，客户端不执行冲刺逻辑（由服务器控制）
	if GameMain.current_mode_id == "online" and not NetworkManager.is_server():
		return
	
	state_timer -= delta
	
	match state:
		ChargeState.IDLE:
			_check_trigger_charge()
		
		ChargeState.PREPARING:
			_update_indicator()
			if state_timer <= 0:
				_start_charge()
		
		ChargeState.CHARGING:
			_update_charge(delta)
		
		ChargeState.COOLDOWN:
			if state_timer <= 0:
				state = ChargeState.IDLE
				is_charging = false

func _on_physics_update(_delta: float) -> void:
	# 冲锋期间的移动在_update_charge中处理
	pass

## 检查是否触发冲锋
func _check_trigger_charge() -> void:
	var distance = get_distance_to_player()
	if distance <= trigger_distance:
		# 开始准备冲锋
		state = ChargeState.PREPARING
		state_timer = prepare_time
		is_charging = false
		_show_indicator()
		
		# 播放技能准备动画
		if enemy:
			enemy.play_animation("skill_prepare")
			enemy.play_skill_animation("skill_prepare")

## 开始冲锋
func _start_charge() -> void:
	var player = get_player()
	if not player or not enemy:
		state = ChargeState.IDLE
		return
	
	state = ChargeState.CHARGING
	charge_start_pos = enemy.global_position
	charge_direction = get_direction_to_player()
	is_charging = true
	has_hit_player = false  # 重置命中标志
	_hide_indicator()
	
	# 冲锋期间完全无视击退
	original_knockback_resistance = enemy.knockback_resistance
	enemy.knockback_resistance = 1.0
	enemy.knockback_velocity = Vector2.ZERO  # 清除已有的击退速度
	
	# 设置冲锋距离的计时器（基于速度计算）
	var charge_duration = charge_distance / charge_speed
	state_timer = charge_duration
	
	# 播放技能执行动画
	enemy.play_animation("skill_execute")
	enemy.play_skill_animation("skill_execute")
	
	print("[ChargingBehavior] 开始冲锋 | 方向:", charge_direction, " 距离:", charge_distance)

## 更新冲锋
func _update_charge(_delta: float) -> void:
	if not enemy:
		return
	
	# 冲锋期间持续清除击退速度，确保不受干扰
	enemy.knockback_velocity = Vector2.ZERO
	
	# 计算冲锋移动
	var charge_velocity = charge_direction * charge_speed
	
	# 检查是否已经冲锋足够距离
	var traveled_distance = enemy.global_position.distance_to(charge_start_pos)
	if traveled_distance >= charge_distance:
		_end_charge()
		return
	
	# 检查是否命中玩家（穿过玩家继续冲刺，但只造成一次伤害）
	if not has_hit_player:
		var player = get_player()
		if player:
			var player_distance = enemy.global_position.distance_to(player.global_position)
			# 使用配置的 hit_range，如果未配置则使用 attack_range
			var check_range = hit_range if hit_range > 0 else (enemy.enemy_data.attack_range if enemy.enemy_data else 80.0)
			if player_distance < check_range:
				# 命中玩家，造成额外伤害，但不停止冲锋
				_hit_player_with_charge()
				has_hit_player = true  # 标记已命中，防止多次伤害
	
	# 应用冲锋速度（覆盖正常移动）
	enemy.velocity = charge_velocity
	enemy.move_and_slide()
	
	# 检查计时器
	if state_timer <= 0:
		_end_charge()

## 冲锋命中玩家
func _hit_player_with_charge() -> void:
	var player = get_player()
	if player and player.has_method("player_hurt"):
		var total_damage = enemy.attack_damage + extra_damage
		player.player_hurt(total_damage)
		print("[ChargingBehavior] 冲锋命中玩家 | 伤害:", total_damage)

## 结束冲锋
func _end_charge() -> void:
	state = ChargeState.COOLDOWN
	state_timer = cooldown
	is_charging = false
	enemy.velocity = Vector2.ZERO
	_hide_indicator()
	
	# 恢复原始击退抗性
	if enemy:
		enemy.knockback_resistance = original_knockback_resistance
		enemy.play_animation("walk")
		enemy.stop_skill_animation()
	
	print("[ChargingBehavior] 冲锋结束，进入冷却")

## 是否正在冲锋（供Enemy类查询，用于覆盖正常移动）
func is_charging_now() -> bool:
	return is_charging and state == ChargeState.CHARGING

## 指示器相关
func _create_indicator() -> void:
	# 联网模式下，客户端不创建本地指示器（由服务器通过 RPC 同步）
	if GameMain.current_mode_id == "online" and not NetworkManager.is_server():
		return
	
	if is_instance_valid(indicator_node):
		return
	
	if not enemy:
		return
	
	# 根据配置创建不同类型的指示器
	if indicator_sprite_frames != null:
		# 使用 AnimatedSprite2D（动态指示器）
		var animated_sprite = AnimatedSprite2D.new()
		animated_sprite.sprite_frames = indicator_sprite_frames
		animated_sprite.centered = false
		
		# 计算偏移（垂直居中）
		if indicator_sprite_frames.has_animation(indicator_animation):
			var frame_texture = indicator_sprite_frames.get_frame_texture(indicator_animation, 0)
			if frame_texture:
				animated_sprite.offset = Vector2(0, -frame_texture.get_height() / 2.0)
		
		indicator_node = animated_sprite
	else:
		# 使用 Sprite2D（静态指示器）
		var sprite = Sprite2D.new()
		sprite.texture = indicator_texture
		sprite.centered = false
		if indicator_texture:
			sprite.offset = Vector2(0, -indicator_texture.get_height() / 2.0)
		
		indicator_node = sprite
	
	# 通用设置
	indicator_node.visible = false
	indicator_node.top_level = true
	indicator_node.z_index = -1
	indicator_node.scale = indicator_scale
	enemy.add_child(indicator_node)

func _show_indicator() -> void:
	_create_indicator()
	if is_instance_valid(indicator_node):
		indicator_node.visible = true
		
		# 如果是动画指示器，播放动画
		if indicator_node is AnimatedSprite2D:
			var anim_sprite = indicator_node as AnimatedSprite2D
			if anim_sprite.sprite_frames and anim_sprite.sprite_frames.has_animation(indicator_animation):
				anim_sprite.play(indicator_animation)
		
		_update_indicator()
	
	# 联网模式：服务器广播给客户端
	if GameMain.current_mode_id == "online" and NetworkManager.is_server() and enemy:
		var player = get_player()
		if player:
			var enemy_path = str(enemy.get_path())
			# 获取实际使用的纹理路径
			var texture_path = ""
			var sprite_frames_path = ""
			var anim_name = indicator_animation
			
			if indicator_sprite_frames != null:
				# 使用动画帧，尝试获取资源路径
				sprite_frames_path = indicator_sprite_frames.resource_path
			elif indicator_texture != null:
				# 使用静态纹理
				texture_path = indicator_texture.resource_path
			else:
				# 使用默认纹理
				texture_path = DEFAULT_INDICATOR_TEXTURE_PATH
			
			NetworkPlayerManager.broadcast_show_charge_indicator(
				enemy_path,
				enemy.global_position,
				player.global_position,
				indicator_scale,
				texture_path,
				sprite_frames_path,
				anim_name
			)

func _hide_indicator() -> void:
	if is_instance_valid(indicator_node):
		indicator_node.visible = false
		
		# 如果是动画指示器，停止动画
		if indicator_node is AnimatedSprite2D:
			(indicator_node as AnimatedSprite2D).stop()
	
	# 联网模式：服务器广播给客户端
	if GameMain.current_mode_id == "online" and NetworkManager.is_server() and enemy:
		var enemy_path = str(enemy.get_path())
		NetworkPlayerManager.broadcast_hide_charge_indicator(enemy_path)

func _update_indicator() -> void:
	if not is_instance_valid(indicator_node) or not indicator_node.visible or not enemy:
		return
	
	var player = get_player()
	if not player:
		return
		
	# 更新位置
	indicator_node.global_position = enemy.global_position
	
	# 更新朝向
	var dir = (player.global_position - enemy.global_position).normalized()
	indicator_node.rotation = dir.angle()
	
	# 联网模式：服务器广播给客户端
	if GameMain.current_mode_id == "online" and NetworkManager.is_server():
		var enemy_path = str(enemy.get_path())
		NetworkPlayerManager.broadcast_update_charge_indicator(
			enemy_path,
			enemy.global_position,
			player.global_position
		)
