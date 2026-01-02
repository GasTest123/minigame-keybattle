extends EnemyBehavior
class_name ExplodingBehavior

## 自爆技能行为
## 根据触发条件（低血量/距离玩家/死亡时）触发爆炸
## 触发后会进入倒数状态，显示范围警示，敌人闪烁，倒数结束后爆炸

## 状态枚举
enum ExplodeState {
	IDLE,       # 待机状态
	COUNTDOWN,  # 倒数状态
	EXPLODED    # 已爆炸
}

## 触发条件枚举
enum ExplodeTrigger {
	LOW_HP,      # 低血量时
	DISTANCE,    # 距离玩家一定距离内
	ON_DEATH     # 死亡时
}

var state: ExplodeState = ExplodeState.IDLE
var trigger_condition: ExplodeTrigger = ExplodeTrigger.LOW_HP

## 配置参数（从config字典读取）
var explosion_range: float = 200.0     # 爆炸范围
var explosion_damage: int = 30         # 爆炸伤害
var low_hp_threshold: float = 0.3      # 低血量阈值（百分比，如0.3表示30%）
var trigger_distance: float = 150.0    # 触发距离（用于DISTANCE条件）
var countdown_duration: float = 3.0    # 倒数时长（秒）

## 动画配置（从config字典读取，通用化）
var prepare_anim_player: String = ""   # AnimationPlayer 准备动画名
var execute_anim_player: String = ""   # AnimationPlayer 爆炸动画名
var wait_explode_animation: bool = true  # 是否等待爆炸动画完成再删除敌人

## 爆炸特效配置（支持拖拽 SpriteFrames 资源）
var explode_fx_sprite_frames: SpriteFrames = null  # 爆炸特效动画帧
var explode_fx_animation: String = "default"       # 爆炸特效动画名
var explode_fx_scale: Vector2 = Vector2.ONE        # 爆炸特效缩放

## 倒数相关
var countdown_timer: float = 0.0
var is_invincible: bool = false  # 倒数期间无敌

## 范围指示器
var range_indicator: Sprite2D = null
## 预加载的范围圈纹理（与grave_rescue_manager共用资源）
static var _range_circle_texture = preload("res://assets/skill_indicator/explosion_range_circle.png")

## 闪烁相关
var flash_timer: float = 0.0
var flash_interval: float = 0.1  # 闪烁间隔（秒）
var is_flashing: bool = false

func _on_initialize() -> void:
	# 从配置中读取参数
	explosion_range = config.get("explosion_range", 200.0)
	explosion_damage = config.get("explosion_damage", 30)
	low_hp_threshold = config.get("low_hp_threshold", 0.3)
	trigger_distance = config.get("trigger_distance", 150.0)
	countdown_duration = config.get("countdown_duration", 3.0)
	
	# 从配置中读取动画名（通用化，不再硬编码）
	prepare_anim_player = config.get("prepare_anim_player", "")
	execute_anim_player = config.get("execute_anim_player", "")
	wait_explode_animation = config.get("wait_explode_animation", true)
	
	# 读取爆炸特效配置（支持拖拽资源）
	explode_fx_sprite_frames = config.get("explode_fx_sprite_frames", null)
	explode_fx_animation = config.get("explode_fx_animation", "default")
	var fx_scale_value = config.get("explode_fx_scale", 1.0)
	if fx_scale_value is Vector2:
		explode_fx_scale = fx_scale_value
	else:
		explode_fx_scale = Vector2(fx_scale_value, fx_scale_value)
	
	# 解析触发条件
	var trigger_str = config.get("trigger_condition", "low_hp")
	match trigger_str:
		"low_hp", "LOW_HP":
			trigger_condition = ExplodeTrigger.LOW_HP
		"distance", "DISTANCE":
			trigger_condition = ExplodeTrigger.DISTANCE
		"on_death", "ON_DEATH":
			trigger_condition = ExplodeTrigger.ON_DEATH
		_:
			trigger_condition = ExplodeTrigger.LOW_HP
	
	state = ExplodeState.IDLE
	countdown_timer = 0.0
	is_invincible = false
	
	# 延迟创建范围指示器（确保enemy已经添加到场景树）
	call_deferred("_create_range_indicator")

func _on_update(delta: float) -> void:
	if not enemy or enemy.is_dead:
		return
	
	# 联网模式下，客户端不执行爆炸逻辑（由服务器控制）
	if GameMain.current_mode_id == "online" and not NetworkManager.is_server():
		return
	
	match state:
		ExplodeState.IDLE:
			# 根据触发条件检查
			match trigger_condition:
				ExplodeTrigger.LOW_HP:
					_check_low_hp_trigger()
				
				ExplodeTrigger.DISTANCE:
					_check_distance_trigger()
				
				ExplodeTrigger.ON_DEATH:
					# 死亡时触发在enemy_dead中处理
					pass
		
		ExplodeState.COUNTDOWN:
			_update_countdown(delta)
		
		ExplodeState.EXPLODED:
			pass  # 已爆炸，什么都不做

## 检查低血量触发
func _check_low_hp_trigger() -> void:
	if not enemy:
		return
	
	var hp_percentage = float(enemy.enemyHP) / float(enemy.max_enemyHP)
	if hp_percentage <= low_hp_threshold:
		_start_countdown()

## 检查距离触发
func _check_distance_trigger() -> void:
	var distance = get_distance_to_player()
	if distance <= trigger_distance:
		_start_countdown()

## 开始倒数
func _start_countdown() -> void:
	if state != ExplodeState.IDLE or not enemy:
		return
	
	state = ExplodeState.COUNTDOWN
	countdown_timer = countdown_duration
	is_invincible = true  # 进入无敌状态
	is_flashing = true  # 立即开始闪烁
	flash_timer = 0.0
	
	# 显示范围指示器
	_show_range_indicator()
	
	# 立即更新闪烁效果
	_update_flash_effect()
	
	# 阻止敌人死亡（通过设置一个标记，在Enemy类中检查）
	# 注意：我们需要在Enemy类中添加对is_invincible的检查
	if enemy.has_method("set_invincible"):
		enemy.set_invincible(true)
	
	# 播放准备动画（通用化：从配置读取）
	enemy.play_animation("skill_prepare")  # SpriteFrames 动画（通过 animations 字典映射）
	if prepare_anim_player != "":
		enemy.play_skill_animation(prepare_anim_player)  # AnimationPlayer 动画
	
	print("[ExplodingBehavior] 开始倒数 | 时长:", countdown_duration, "秒")

## 更新倒数状态
func _update_countdown(delta: float) -> void:
	if not enemy:
		return
	
	countdown_timer -= delta
	
	# 更新范围指示器位置（跟随敌人）
	if range_indicator:
		range_indicator.global_position = enemy.global_position
	
	# 联网模式：服务器广播位置更新给客户端
	if GameMain.current_mode_id == "online" and NetworkManager.is_server():
		var enemy_path = str(enemy.get_path())
		NetworkPlayerManager.broadcast_update_explode_indicator(enemy_path, enemy.global_position)
	
	# 更新闪烁效果
	flash_timer += delta
	if flash_timer >= flash_interval:
		flash_timer = 0.0
		is_flashing = !is_flashing
		_update_flash_effect()
	
	# 检查倒数是否结束
	if countdown_timer <= 0:
		_explode()

## 更新闪烁效果
func _update_flash_effect() -> void:
	if not enemy or not enemy.has_node("AnimatedSprite2D"):
		return
	
	var sprite = enemy.get_node("AnimatedSprite2D")
	if is_flashing:
		# 黄色闪烁（使用flash_opacity参数）
		sprite.material.set_shader_parameter("flash_color",Color(0.826, 0.766, 0.0, 1.0) )
		sprite.material.set_shader_parameter("flash_opacity", 1.0)
	else:
		# 恢复正常
		sprite.material.set_shader_parameter("flash_color",Color(1.0, 1.0, 1.0, 1.0) )
		sprite.material.set_shader_parameter("flash_opacity", 0.0)
	
	# 联网模式：服务器广播闪烁状态给客户端
	if GameMain.current_mode_id == "online" and NetworkManager.is_server():
		var enemy_path = str(enemy.get_path())
		NetworkPlayerManager.broadcast_enemy_flash(enemy_path, is_flashing)

## 执行爆炸
func _explode() -> void:
	if state == ExplodeState.EXPLODED or not enemy:
		return
	
	state = ExplodeState.EXPLODED
	is_invincible = false
	
	# 恢复闪烁效果
	if enemy.has_node("AnimatedSprite2D"):
		var sprite = enemy.get_node("AnimatedSprite2D")
		sprite.modulate = Color.WHITE
		sprite.material.set_shader_parameter("flash_opacity", 0.0)
	
	# 隐藏范围指示器
	_hide_range_indicator()
	
	var explode_pos = enemy.global_position
	
	print("[ExplodingBehavior] 爆炸！| 位置:", explode_pos, " 范围:", explosion_range, " 伤害:", explosion_damage)
	
	# 禁用敌人的碰撞和移动（防止在动画期间继续交互）
	enemy.set_physics_process(false)
	enemy.set_process(false)
	if enemy.has_node("CollisionShape2D"):
		enemy.get_node("CollisionShape2D").set_deferred("disabled", true)
	
	# 播放爆炸动画（通用化）
	var has_sprite_anim = false
	
	# 1. 播放 SpriteFrames 爆炸动画（通过 animations 字典映射）
	if enemy.enemy_data and enemy.enemy_data.animations.get("skill_execute", "") != "":
		enemy.play_animation("skill_execute")
		has_sprite_anim = true
	
	# 2. 播放 AnimationPlayer 爆炸动画（从配置读取）
	if execute_anim_player != "":
		enemy.play_skill_animation(execute_anim_player)
	
	# 对范围内玩家造成伤害（立即生效）
	_damage_players_in_range(explode_pos)
	
	# 播放自定义爆炸特效（如果配置了）
	_play_explode_fx(explode_pos)
	
	# 播放通用爆炸特效（粒子等）
	_create_explosion_effect(explode_pos)
	
	# 处理敌人死亡
	if trigger_condition != ExplodeTrigger.ON_DEATH:
		if wait_explode_animation and has_sprite_anim:
			# 等待序列帧动画播放完成后再删除
			_wait_and_die()
		else:
			# 立即死亡
			_do_die()

## 等待动画完成后死亡
func _wait_and_die() -> void:
	if not enemy or not enemy.has_node("AnimatedSprite2D"):
		_do_die()
		return
	
	var sprite = enemy.get_node("AnimatedSprite2D")
	
	# 连接动画完成信号
	if not sprite.animation_finished.is_connected(_on_explode_animation_finished):
		sprite.animation_finished.connect(_on_explode_animation_finished, CONNECT_ONE_SHOT)

## 爆炸动画播放完成
func _on_explode_animation_finished() -> void:
	_do_die()

## 执行死亡
func _do_die() -> void:
	if enemy and not enemy.is_dead:
		if enemy.has_method("set_invincible"):
			enemy.set_invincible(false)
		enemy.enemy_dead()

## 创建范围指示器节点（使用预加载的纹理，与grave_rescue_manager一致）
func _create_range_indicator() -> void:
	# 联网模式下，客户端不创建本地指示器（由服务器通过 RPC 同步）
	if GameMain.current_mode_id == "online" and not NetworkManager.is_server():
		return
	
	if range_indicator:
		return
	
	range_indicator = Sprite2D.new()
	range_indicator.texture = _range_circle_texture
	
	# 根据explosion_range调整缩放（与grave_rescue_manager相同的计算方式）
	var target_diameter = explosion_range * 2
	var texture_size = _range_circle_texture.get_size().x  # 假设图片是正方形
	if texture_size > 0:
		range_indicator.scale = Vector2.ONE * (target_diameter / texture_size)
	
	range_indicator.visible = false
	range_indicator.z_index = 1  # 在敌人下方
	range_indicator.modulate = Color(1.0, 0.0, 0.0, 0.5)  # 红色，50%透明度
	
	# 添加到场景树（作为敌人的兄弟节点，这样不会随敌人旋转）
	if enemy and enemy.get_parent():
		enemy.get_parent().add_child(range_indicator)
	else:
		# 如果还没有父节点，延迟添加
		call_deferred("_add_range_indicator_to_scene")

## 延迟添加范围指示器到场景
func _add_range_indicator_to_scene() -> void:
	if not range_indicator:
		return
	
	if enemy and enemy.get_parent():
		enemy.get_parent().add_child(range_indicator)
	else:
		get_tree().root.add_child(range_indicator)

## 显示范围指示器
func _show_range_indicator() -> void:
	if range_indicator:
		range_indicator.visible = true
		if enemy:
			range_indicator.global_position = enemy.global_position
	
	# 联网模式：服务器广播给客户端
	if GameMain.current_mode_id == "online" and NetworkManager.is_server() and enemy:
		var enemy_path = str(enemy.get_path())
		NetworkPlayerManager.broadcast_show_explode_indicator(
			enemy_path,
			enemy.global_position,
			explosion_range
		)

## 隐藏范围指示器
func _hide_range_indicator() -> void:
	if range_indicator:
		range_indicator.visible = false
	
	# 联网模式：服务器广播给客户端
	if GameMain.current_mode_id == "online" and NetworkManager.is_server() and enemy:
		var enemy_path = str(enemy.get_path())
		NetworkPlayerManager.broadcast_hide_explode_indicator(enemy_path)

## 播放自定义爆炸特效
func _play_explode_fx(pos: Vector2) -> void:
	if explode_fx_sprite_frames == null:
		return
	
	# 检查动画是否存在
	if not explode_fx_sprite_frames.has_animation(explode_fx_animation):
		push_warning("[ExplodingBehavior] 特效资源中没有动画: " + explode_fx_animation)
		return
	
	# 联网模式：服务器广播特效给客户端
	if GameMain.current_mode_id == "online" and NetworkManager.is_server():
		var sprite_frames_path = explode_fx_sprite_frames.resource_path
		NetworkPlayerManager.broadcast_explode_fx(pos, sprite_frames_path, explode_fx_animation, explode_fx_scale)
	
	# 创建特效节点（服务器本地也创建）
	var fx_node = AnimatedSprite2D.new()
	fx_node.sprite_frames = explode_fx_sprite_frames
	fx_node.global_position = pos
	fx_node.scale = explode_fx_scale
	fx_node.z_index = 10  # 在上层显示
	
	# 添加到场景树
	get_tree().root.add_child(fx_node)
	
	# 播放动画
	fx_node.play(explode_fx_animation)
	
	# 计算动画时长并用定时器清理（避免循环动画不触发 animation_finished 的问题）
	var frame_count = explode_fx_sprite_frames.get_frame_count(explode_fx_animation)
	var fps = explode_fx_sprite_frames.get_animation_speed(explode_fx_animation)
	if fps <= 0:
		fps = 5.0  # 默认帧率
	var duration = frame_count / fps
	
	# 使用定时器延迟清理
	get_tree().create_timer(duration + 0.1).timeout.connect(func():
		if is_instance_valid(fx_node):
			fx_node.queue_free()
	)
	
	print("[ExplodingBehavior] 播放爆炸特效 | 动画:", explode_fx_animation, " 帧数:", frame_count, " 时长:", duration, "秒")

## 创建爆炸效果
func _create_explosion_effect(pos: Vector2) -> void:
	# 联网模式：服务器广播通用爆炸效果给客户端
	if GameMain.current_mode_id == "online" and NetworkManager.is_server():
		NetworkPlayerManager.broadcast_enemy_explosion(pos, 1.5)
	
	# 使用统一的特效管理器播放自爆特效（服务器本地也播放）
	CombatEffectManager.play_enemy_explosion(pos, 1.5)
	
	# 震动屏幕
	CameraShake.shake(0.3, 15.0)

## 对范围内玩家造成伤害
func _damage_players_in_range(center: Vector2) -> void:
	var player = get_player()
	if not player:
		return
	
	var distance = center.distance_to(player.global_position)
	if distance <= explosion_range:
		# 玩家在爆炸范围内
		if player.has_method("player_hurt"):
			player.player_hurt(explosion_damage)
			print("[ExplodingBehavior] 爆炸命中玩家 | 距离:", distance, " 伤害:", explosion_damage)
		
		# 显示伤害跳字
		FloatingText.create_floating_text(
			player.global_position + Vector2(0, -30),
			"-" + str(explosion_damage),
			Color(1.0, 0.5, 0.0)  # 橙色伤害数字
		)

## 敌人死亡时调用（用于ON_DEATH触发条件）
func on_enemy_death() -> void:
	if trigger_condition == ExplodeTrigger.ON_DEATH and state == ExplodeState.IDLE:
		_start_countdown()

## 清理资源
func _exit_tree() -> void:
	if range_indicator and is_instance_valid(range_indicator):
		range_indicator.queue_free()

## 检查敌人是否在倒数状态（供Enemy类查询）
func is_in_countdown() -> bool:
	return state == ExplodeState.COUNTDOWN

## 检查技能是否激活（倒数或爆炸中）- 供 AI 控制器查询
func is_skill_active() -> bool:
	return state == ExplodeState.COUNTDOWN or state == ExplodeState.EXPLODED

## 检查敌人是否无敌（供Enemy类查询）
func is_enemy_invincible() -> bool:
	return is_invincible
