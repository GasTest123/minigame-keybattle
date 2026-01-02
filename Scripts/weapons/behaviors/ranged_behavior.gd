extends WeaponBehavior
class_name RangedBehavior

## 远程行为
## 
## 实现发射子弹攻击方式
## 
## 参数 (params):
##   - damage: int 基础伤害
##   - bullet_id: String 子弹ID（引用 BulletDatabase）
##   - pierce_count: int 穿透数量
##   - projectile_count: int 每次发射的子弹数量
##   - spread_angle: float 散射角度（度）
##   - attack_speed: float 攻击间隔（秒）
##   - range: float 检测范围
##   - recoil_distance: float 后座力位移像素（可选，默认0）
##   - recoil_duration: float 后座力恢复时间秒（可选，默认0.1）

## 子弹场景
var bullet_scene: PackedScene = null

## 射击位置节点
var shoot_pos: Marker2D = null

## ===== 后座力系统 =====
## 后座力位移像素
var recoil_distance: float = 0.0
## 后座力恢复时间
var recoil_duration: float = 0.1
## 后座力计时器
var recoil_timer: float = 0.0
## 是否正在后座力恢复中
var is_recoiling: bool = false
## 武器原始本地位置
var original_local_position: Vector2 = Vector2.ZERO
## 后座力方向（武器朝向的反方向）
var recoil_direction: Vector2 = Vector2.ZERO

func _on_initialize() -> void:
	# 加载子弹场景
	bullet_scene = preload("res://scenes/bullets/bullet.tscn")
	
	# 获取或创建射击位置节点
	if weapon:
		shoot_pos = weapon.get_node_or_null("shoot_pos")
		if not shoot_pos:
			shoot_pos = Marker2D.new()
			shoot_pos.name = "shoot_pos"
			weapon.add_child(shoot_pos)
		
		# 从 params 中读取发射位置偏移，如果没有则使用默认值
		var shoot_offset = params.get("shoot_offset", Vector2(16, 0))
		shoot_pos.position = shoot_offset
		
		# 读取后座力参数
		recoil_distance = params.get("recoil_distance", 0.0)
		recoil_duration = params.get("recoil_duration", 0.1)

func get_behavior_type() -> int:
	return WeaponData.BehaviorType.RANGED

## 获取子弹ID
func get_bullet_id() -> String:
	return params.get("bullet_id", "normal_bullet")

## 获取子弹数据
func get_bullet_data() -> BulletData:
	return BulletDatabase.get_bullet(get_bullet_id())

## 获取穿透数量
func get_pierce_count() -> int:
	var base_pierce = params.get("pierce_count", 0)
	
	# 如果有玩家属性，加上远程穿透加成
	if player_stats:
		base_pierce += player_stats.ranged_penetration
	
	return base_pierce

## 获取每次发射的子弹数量
func get_projectile_count() -> int:
	var base_count = params.get("projectile_count", 1)
	
	# 如果有玩家属性，加上额外弹药数
	if player_stats:
		base_count += player_stats.ranged_projectile_count
	
	return max(1, base_count)

## 获取散射角度
func get_spread_angle() -> float:
	return params.get("spread_angle", 0.0)

func perform_attack(enemies: Array) -> void:
	if enemies.is_empty() or not weapon or not shoot_pos:
		return
	
	var target_enemy = enemies[0]
	if not is_instance_valid(target_enemy):
		return
	
	# 获取子弹数据
	var bullet_data = get_bullet_data()
	var projectile_count = get_projectile_count()
	var spread_angle = get_spread_angle()
	
	# 计算基础方向
	var base_direction = (target_enemy.global_position - shoot_pos.global_position).normalized()
	
	# 播放枪口特效
	_play_muzzle_effect(bullet_data, base_direction)
	
	# 触发后座力（如果有配置）
	_trigger_recoil(base_direction)
	
	# 计算伤害和暴击
	var base_damage = get_final_damage()
	var is_critical = roll_critical()
	var final_damage = base_damage
	if is_critical:
		final_damage = apply_critical(base_damage)
	
	# 发射多颗子弹
	for i in range(projectile_count):
		var direction = base_direction
		
		# 如果有多颗子弹，计算散射
		if projectile_count > 1 and spread_angle > 0:
			var angle_offset = 0.0
			if projectile_count > 1:
				# 均匀分布在散射角度范围内
				var step = spread_angle / (projectile_count - 1)
				angle_offset = -spread_angle / 2 + step * i
			direction = base_direction.rotated(deg_to_rad(angle_offset))
		
		# 创建子弹
		_spawn_bullet(direction, final_damage, is_critical, bullet_data)

## 播放枪口特效
func _play_muzzle_effect(bullet_data: BulletData, direction: Vector2) -> void:
	if not bullet_data:
		return
	
	# 检查是否配置了枪口特效
	if bullet_data.muzzle_effect_scene_path == "" or bullet_data.muzzle_effect_ani_name == "":
		return
	
	# 计算朝向角度
	var rotation_angle = direction.angle()

	# 联网模式：
	# - 客户端枪口特效由 NetworkPlayerManager.rpc_spawn_bullet_visual 在本地播放（与每颗子弹一一对应）
	# - 这里保留服务器本地播放（服务器观察/录制用），避免 online 下服务器完全没有枪口反馈
	if GameMain.current_mode_id == "online" and not NetworkManager.is_server():
		return
	
	# 单机模式：本地直接播放，绑定到 shoot_pos 上跟随武器移动
	CombatEffectManager.play_muzzle_flash(
		bullet_data.muzzle_effect_scene_path,
		bullet_data.muzzle_effect_ani_name,
		shoot_pos,                        # 父节点，特效会跟随移动
		bullet_data.muzzle_effect_offset, # 本地位置偏移（相对于 shoot_pos）
		rotation_angle,
		bullet_data.muzzle_effect_scale
	)

## 触发后座力
func _trigger_recoil(_shoot_direction: Vector2) -> void:
	if recoil_distance == 0 or not weapon:
		return
	
	# 如果正在后座力恢复中，立即重置到原位再开始新的后座力
	if is_recoiling:
		weapon.position = original_local_position
	
	# 后座力方向是武器的负X方向（武器朝向的反方向）
	# 武器会旋转朝向敌人，所以需要根据武器的旋转角度计算后座力方向
	# Vector2(-1, 0) 是武器本地坐标的后方，旋转到父节点坐标系
	recoil_direction = Vector2(-1, 0).rotated(weapon.rotation)
	
	# 立即将武器移动到后座位置
	weapon.position = original_local_position + recoil_direction * recoil_distance
	
	# 开始后座力恢复计时
	recoil_timer = 0.0
	is_recoiling = true

## 每帧更新 - 处理后座力恢复
func process(delta: float) -> void:
	if not weapon:
		return
	
	# 不在后座力状态时，持续记录武器的正常位置
	if not is_recoiling:
		original_local_position = weapon.position
		return
	
	# 更新后座力计时器
	recoil_timer += delta
	
	# 计算恢复进度 (0 -> 1)
	var progress = recoil_timer / recoil_duration if recoil_duration > 0 else 1.0
	progress = clampf(progress, 0.0, 1.0)
	
	# 使用平滑插值从后座位置恢复到原位
	# 使用 ease out 效果让恢复更自然
	var eased_progress = 1.0 - pow(1.0 - progress, 2.0)  # ease out quad
	var current_offset = recoil_direction * recoil_distance * (1.0 - eased_progress)
	weapon.position = original_local_position + current_offset
	
	# 检查是否恢复完成
	if progress >= 1.0:
		weapon.position = original_local_position
		is_recoiling = false
		recoil_timer = 0.0

## 生成子弹
func _spawn_bullet(direction: Vector2, damage: int, is_critical: bool, bullet_data: BulletData) -> void:
	if not bullet_scene or not weapon:
		return
	
	# 联网模式：通过 NetworkPlayerManager 广播子弹（服务器处理伤害，客户端只显示）
	if GameMain.current_mode_id == "online":
		NetworkPlayerManager.broadcast_spawn_bullet(
			shoot_pos.global_position,
			direction,
			damage,
			is_critical,
			weapon.owner_peer_id,
			get_bullet_id(),
			get_pierce_count()
		)
		return
	
	# 单机模式：直接生成子弹
	var bullet = bullet_scene.instantiate()
	weapon.get_tree().root.add_child(bullet)
	
	# 配置子弹参数
	var start_params = {
		"position": shoot_pos.global_position,
		"direction": direction,
		"speed": bullet_data.speed,
		"damage": damage,
		"is_critical": is_critical,
		"player_stats": player_stats,
		"special_effects": special_effects,
		"calculation_type": calculation_type,
		"pierce_count": get_pierce_count(),
		"bullet_data": bullet_data,
	}
	
	# 调用子弹的初始化方法
	if bullet.has_method("start_with_config"):
		bullet.start_with_config(start_params)
	else:
		# 兼容旧版子弹
		bullet.start(
			shoot_pos.global_position,
			direction,
			bullet_data.speed,
			damage,
			is_critical,
			player_stats,
			null  # 旧版不传 weapon_data
		)

