extends WeaponBehavior
class_name MagicBehavior

## 魔法行为
## 
## 实现定点打击攻击方式
## 
## 参数 (params):
##   - damage: int 基础伤害
##   - explosion_radius: float 爆炸范围
##   - explosion_damage_multiplier: float 爆炸伤害倍数
##   - cast_delay: float 施法延迟（秒）
##   - is_target_locked: bool 是否锁定目标（跟随）
##   - max_targets: int 最大目标数量
##   - has_explosion_damage: bool 是否有范围爆炸伤害
##   - attack_speed: float 攻击间隔（秒）
##   - range: float 检测范围
##   - effect_lead_time: float 特效预播放时间（在伤害判定前多久播放特效）

## 爆炸指示器脚本
var explosion_indicator_script: GDScript = null

## 当前正在施法的攻击列表
var casting_attacks: Array = []

## WaveSystem 缓存：优先使用 active_enemies 避免 get_nodes_in_group("enemy") 分配
var _wave_manager_cache: Node = null

## 指示器颜色（可由武器配置覆盖，默认白色保留纹理原色）
var indicator_color: Color = Color(1.0, 1.0, 1.0, 0.8)

## 缓存的自定义指示器纹理
var _cached_indicator_texture: Texture2D = null

## 射击位置节点（用于枪口特效）
var shoot_pos: Marker2D = null

func _on_initialize() -> void:
	casting_attacks.clear()
	
	# 加载爆炸指示器脚本
	explosion_indicator_script = preload("res://Scripts/weapons/explosion_indicator.gd")
	
	# 读取指示器颜色
	if params.has("indicator_color"):
		indicator_color = params.get("indicator_color")

	# 预加载并缓存指示器纹理
	_cached_indicator_texture = null
	var texture_path = params.get("indicator_texture_path", "")
	if texture_path != "" and ResourceLoader.exists(texture_path):
		_cached_indicator_texture = load(texture_path)
	
	# 获取或创建射击位置节点（用于枪口特效）
	if weapon:
		shoot_pos = weapon.get_node_or_null("shoot_pos")
		if not shoot_pos:
			shoot_pos = Marker2D.new()
			shoot_pos.name = "shoot_pos"
			weapon.add_child(shoot_pos)
		
		# 从 params 中读取发射位置偏移
		var shoot_offset = params.get("shoot_offset", Vector2(16, 0))
		shoot_pos.position = shoot_offset

func get_behavior_type() -> int:
	return WeaponData.BehaviorType.MAGIC

## 获取爆炸范围
func get_explosion_radius() -> float:
	var base_radius = params.get("explosion_radius", 150.0)
	
	if player_stats:
		return DamageCalculator.calculate_explosion_radius(base_radius, player_stats)
	
	return base_radius

## 获取爆炸伤害倍数
func get_explosion_damage_multiplier() -> float:
	return params.get("explosion_damage_multiplier", 1.0)

## 获取施法延迟
func get_cast_delay() -> float:
	return params.get("cast_delay", 0.0)

## 是否锁定目标
func is_target_locked() -> bool:
	return params.get("is_target_locked", true)

## 获取最大目标数
func get_max_targets() -> int:
	return params.get("max_targets", 1)

## 是否有爆炸伤害
func has_explosion_damage() -> bool:
	return params.get("has_explosion_damage", true)

## 获取特效预播放时间（在伤害判定前多久开始播放特效）
func get_effect_lead_time() -> float:
	return params.get("effect_lead_time", 0.2)  # 默认提前 0.2 秒

## 获取枪口特效场景路径
func get_muzzle_effect_scene_path() -> String:
	return params.get("muzzle_effect_scene_path", "")

## 获取枪口特效动画名
func get_muzzle_effect_ani_name() -> String:
	return params.get("muzzle_effect_ani_name", "")

## 获取枪口特效缩放
func get_muzzle_effect_scale() -> float:
	return params.get("muzzle_effect_scale", 1.0)

## 获取枪口特效偏移
func get_muzzle_effect_offset() -> Vector2:
	return params.get("muzzle_effect_offset", Vector2.ZERO)

func process(delta: float) -> void:
	_update_casting_attacks(delta)

## 更新施法攻击
func _update_casting_attacks(delta: float) -> void:
	var attacks_to_remove = []
	var effect_lead_time = get_effect_lead_time()
	
	for i in range(casting_attacks.size()):
		var cast_data = casting_attacks[i]
		
		# 如果是锁敌模式，检查目标有效性
		if cast_data.is_locked:
			if not is_instance_valid(cast_data.target) or cast_data.target.get("is_dead"):
				_cancel_cast(cast_data)
				attacks_to_remove.append(i)
				continue
		
		# 更新倒计时
		cast_data.timer -= delta
		
		# 预播放特效：在伤害判定前 effect_lead_time 秒播放特效
		if not cast_data.get("effect_played", false) and cast_data.timer <= effect_lead_time:
			_play_cast_effect_early(cast_data)
			cast_data["effect_played"] = true
		
		# 时间到，执行攻击（伤害判定）
		if cast_data.timer <= 0:
			_execute_cast(cast_data)
			attacks_to_remove.append(i)
	
	# 移除已完成的攻击
	attacks_to_remove.reverse()
	for i in attacks_to_remove:
		casting_attacks.remove_at(i)

## 取消施法
func _cancel_cast(cast_data: Dictionary) -> void:
	if cast_data.indicator and is_instance_valid(cast_data.indicator):
		if cast_data.indicator.has_method("fade_out_and_remove"):
			cast_data.indicator.fade_out_and_remove(0.1)

## 执行施法（只处理伤害判定，特效已在预播放阶段处理）
func _execute_cast(cast_data: Dictionary) -> void:
	var base_damage = cast_data.damage
	var explosion_radius = get_explosion_radius()
	var explosion_position: Vector2
	
	if cast_data.is_locked:
		# 锁敌模式：在目标当前位置爆炸
		var target = cast_data.target
		if not is_instance_valid(target):
			if cast_data.indicator and is_instance_valid(cast_data.indicator):
				if cast_data.indicator.has_method("hide_and_remove"):
					cast_data.indicator.hide_and_remove()
				else:
					cast_data.indicator.queue_free()
			return
		
		explosion_position = target.global_position
		
		# 暴击判定
		var final_damage = base_damage
		var is_critical = roll_critical()
		if is_critical:
			final_damage = apply_critical(base_damage)
		
		# 对目标造成直接伤害（区分敌人和玩家）
		var damage_to_deal = int(final_damage * get_explosion_damage_multiplier())
		if target.is_in_group("enemy"):
			if target.has_method("enemy_hurt"):
				target.enemy_hurt(damage_to_deal, is_critical)
				apply_special_effects(target, damage_to_deal)
		elif target.is_in_group("player") and GameMain.current_mode_id == "online":
			# PvP 目标：服务器直接处理伤害（攻击逻辑只在服务器执行）
			var target_peer_id = target.get("peer_id")
			if target_peer_id != null and weapon.owner_peer_id > 0:
				NetworkPlayerManager.apply_pvp_damage(weapon.owner_peer_id, target_peer_id, damage_to_deal)
		
		# 爆炸范围伤害
		if has_explosion_damage() and explosion_radius > 0:
			_explode_at_position(explosion_position, explosion_radius, base_damage, target)
	else:
		# 非锁敌模式：在锁定的位置爆炸
		explosion_position = cast_data.target_position
		
		if has_explosion_damage() and explosion_radius > 0:
			_explode_at_position(explosion_position, explosion_radius, base_damage, null)
	
	# 如果特效没有预播放（无延迟攻击或其他原因），在这里补播
	if not cast_data.get("effect_played", false):
		_create_explosion_effect(explosion_position)
	
	# 清理指示器
	if cast_data.indicator and is_instance_valid(cast_data.indicator):
		if cast_data.indicator.has_method("hide_and_remove"):
			cast_data.indicator.hide_and_remove()
		else:
			cast_data.indicator.queue_free()

## 预播放特效（在伤害判定前调用）
func _play_cast_effect_early(cast_data: Dictionary) -> void:
	var explosion_position: Vector2
	
	if cast_data.is_locked:
		var target = cast_data.target
		if is_instance_valid(target):
			explosion_position = target.global_position
		else:
			return
	else:
		explosion_position = cast_data.target_position
	
	# 播放爆炸特效
	_create_explosion_effect(explosion_position)

func perform_attack(enemies: Array) -> void:
	if enemies.is_empty() or not weapon:
		return
	
	var max_targets = get_max_targets()
	var cast_delay = get_cast_delay()
	var damage = get_final_damage()
	var explosion_radius = get_explosion_radius()
	
	# 选择目标
	var targets = []
	for i in range(min(enemies.size(), max_targets)):
		var enemy = enemies[i]
		if is_instance_valid(enemy):
			targets.append(enemy)
	
	if targets.is_empty():
		return
	
	# 播放枪口特效（只播放一次，不管有多少目标）
	if targets.size() > 0:
		var first_target = targets[0]
		var direction = (first_target.global_position - shoot_pos.global_position).normalized()
		_play_muzzle_effect(direction)
	
	# 为每个目标创建攻击
	for target in targets:
		if cast_delay > 0:
			_start_cast(target, damage, explosion_radius, cast_delay)
		else:
			_execute_immediate_attack(target, damage, explosion_radius)

## 播放枪口特效
func _play_muzzle_effect(direction: Vector2) -> void:
	var scene_path = get_muzzle_effect_scene_path()
	var ani_name = get_muzzle_effect_ani_name()
	
	# 检查是否配置了枪口特效
	if scene_path == "" or ani_name == "":
		return
	
	if not shoot_pos:
		return
	
	# 计算朝向角度
	var rotation_angle = direction.angle()

	# 联网模式：
	# - 客户端枪口特效由 NetworkPlayerManager.rpc_magic_cast/execute 事件在本地武器 shoot_pos 上播放（保证尺寸/旋转一致）
	# - 这里保留服务器本地播放（服务器观察/录制用），避免 online 下服务器完全没有枪口反馈
	if GameMain.current_mode_id == "online" and not NetworkManager.is_server():
		return
	
	# 单机模式：本地直接播放，绑定到 shoot_pos 上跟随武器移动
	CombatEffectManager.play_muzzle_flash(
		scene_path,
		ani_name,
		shoot_pos,                    # 父节点，特效会跟随移动
		get_muzzle_effect_offset(),   # 本地位置偏移（相对于 shoot_pos）
		rotation_angle,
		get_muzzle_effect_scale()
	)

## 开始施法
func _start_cast(target: Node2D, damage: int, radius: float, delay: float) -> void:
	var is_locked = is_target_locked()
	var indicator = null
	var target_position = target.global_position
	
	if radius > 0:
		if is_locked:
			indicator = _create_persistent_indicator(target, radius, delay)
		else:
			indicator = _create_fixed_indicator(target_position, radius, delay)
	
	# 联网模式：广播施法效果给客户端
	if GameMain.current_mode_id == "online" and weapon.owner_peer_id > 0:
		var weapon_name = params.get("weapon_name", "")
		var texture_path = ""
		if _cached_indicator_texture:
			texture_path = _cached_indicator_texture.resource_path
		NetworkPlayerManager.broadcast_magic_cast(target_position, radius, delay, weapon.owner_peer_id, weapon_name, texture_path, indicator_color)
	
	casting_attacks.append({
		"target": target,
		"target_position": target_position,
		"indicator": indicator,
		"timer": delay,
		"damage": damage,
		"is_locked": is_locked
	})

## 立即执行攻击（无延迟）
func _execute_immediate_attack(target: Node2D, damage: int, radius: float) -> void:
	var is_locked = is_target_locked()
	var explosion_position = target.global_position
	
	# 显示短暂指示器
	if radius > 0:
		_show_explosion_indicator(explosion_position, radius)
	
	# 暴击判定
	var final_damage = damage
	var is_critical = roll_critical()
	if is_critical:
		final_damage = apply_critical(damage)
	
	if is_locked:
		# 锁敌模式：直接伤害 + 爆炸伤害（区分敌人和玩家）
		var damage_to_deal = int(final_damage * get_explosion_damage_multiplier())
		if target.is_in_group("enemy"):
			if target.has_method("enemy_hurt"):
				target.enemy_hurt(damage_to_deal, is_critical)
				apply_special_effects(target, damage_to_deal)
		elif target.is_in_group("player") and GameMain.current_mode_id == "online":
			# PvP 目标：服务器直接处理伤害（攻击逻辑只在服务器执行）
			var target_peer_id = target.get("peer_id")
			if target_peer_id != null and weapon.owner_peer_id > 0:
				NetworkPlayerManager.apply_pvp_damage(weapon.owner_peer_id, target_peer_id, damage_to_deal)
	
	# 爆炸范围伤害
	if has_explosion_damage() and radius > 0:
		_explode_at_position(explosion_position, radius, damage, target if is_locked else null)
	
	# 播放爆炸特效
	_create_explosion_effect(explosion_position)
	
	# 联网模式：广播爆炸效果给客户端
	if GameMain.current_mode_id == "online" and weapon.owner_peer_id > 0:
		var weapon_name = params.get("weapon_name", "")
		var texture_path = ""
		if _cached_indicator_texture:
			texture_path = _cached_indicator_texture.resource_path
		NetworkPlayerManager.broadcast_magic_execute(explosion_position, radius, weapon.owner_peer_id, weapon_name, texture_path, indicator_color)

## 在指定位置产生爆炸效果（包括 PvP 伤害）
func _explode_at_position(pos: Vector2, radius: float, base_damage: int, exclude_target = null) -> void:
	if not weapon:
		return

	var enemies = _get_explosion_candidates()
	
	for enemy in enemies:
		if not is_instance_valid(enemy):
			continue
		
		# 跳过主目标（已受到直接伤害）
		if enemy == exclude_target:
			continue
		
		if not (enemy is Node2D):
			continue
		var e := enemy as Node2D
		var distance = pos.distance_to(e.global_position)
		
		if distance <= radius:
			# 根据距离计算伤害衰减
			var damage_mult = 1.0 - (distance / radius) * 0.5
			var final_damage = int(base_damage * damage_mult * get_explosion_damage_multiplier())
			
			if e.has_method("enemy_hurt"):
				e.enemy_hurt(final_damage)
				apply_special_effects(e, final_damage)
	
	# 联网模式：处理 PvP 爆炸伤害
	if GameMain.current_mode_id == "online" and weapon.owner_peer_id > 0:
		NetworkPlayerManager.handle_explosion_collision(
			weapon.owner_peer_id, pos, radius, base_damage, get_explosion_damage_multiplier()
		)


## 爆炸伤害候选：优先使用 WaveSystemV3.active_enemies（无新数组分配），回退到 group("enemy")
func _get_explosion_candidates() -> Array:
	# 缓存 wave_manager
	if _wave_manager_cache == null or not is_instance_valid(_wave_manager_cache):
		var tree := weapon.get_tree() if weapon else null
		if tree:
			_wave_manager_cache = tree.get_first_node_in_group("wave_manager")

	if _wave_manager_cache and is_instance_valid(_wave_manager_cache):
		if "active_enemies" in _wave_manager_cache:
			var arr = _wave_manager_cache.get("active_enemies")
			if arr is Array:
				return arr

	# 回退：会创建数组
	return weapon.get_tree().get_nodes_in_group("enemy")

## 创建爆炸特效
func _create_explosion_effect(pos: Vector2) -> void:
	# 使用统一的特效管理器
	var weapon_name = params.get("weapon_name", "")
	if weapon_name != "" and weapon:
		CombatEffectManager.play_explosion(weapon_name, pos)

## 创建持续指示器（跟随目标）
func _create_persistent_indicator(target: Node2D, radius: float, duration: float) -> Node2D:
	if not weapon or not explosion_indicator_script:
		return null
	
	var indicator = Node2D.new()
	indicator.set_script(explosion_indicator_script)
	weapon.get_tree().root.add_child(indicator)
	indicator._ready()
	
	# 设置自定义纹理
	var texture = _get_indicator_texture()
	if texture and indicator.has_method("set_texture"):
		indicator.set_texture(texture)
	
	if indicator.has_method("show_persistent"):
		indicator.show_persistent(target, radius, indicator_color, duration)
	
	return indicator

## 创建固定位置指示器
func _create_fixed_indicator(position: Vector2, radius: float, duration: float) -> Node2D:
	if not weapon or not explosion_indicator_script:
		return null
	
	var indicator = Node2D.new()
	indicator.set_script(explosion_indicator_script)
	indicator.global_position = position
	weapon.get_tree().root.add_child(indicator)
	indicator._ready()
	
	# 设置自定义纹理
	var texture = _get_indicator_texture()
	if texture and indicator.has_method("set_texture"):
		indicator.set_texture(texture)
	
	if indicator.has_method("show_persistent"):
		indicator.show_persistent(null, radius, indicator_color, duration)
	
	return indicator

## 显示短暂指示器
func _show_explosion_indicator(pos: Vector2, radius: float) -> void:
	if not weapon or not explosion_indicator_script:
		return
	
	var indicator = Node2D.new()
	indicator.set_script(explosion_indicator_script)
	weapon.get_tree().root.add_child(indicator)
	indicator._ready()
	
	# 设置自定义纹理
	var texture = _get_indicator_texture()
	if texture and indicator.has_method("set_texture"):
		indicator.set_texture(texture)
	
	if indicator.has_method("show_at"):
		indicator.show_at(pos, radius, indicator_color, 0.3)

## 获取指示器纹理
func _get_indicator_texture() -> Texture2D:
	return _cached_indicator_texture
