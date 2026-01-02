extends EnemyBehavior
class_name ShootingBehavior

## 射击技能行为
## 敌人在射程内时，定时向玩家发射子弹
## 支持多轮散射发射、发射特效、自定义动作
## 技能期间正常移动和受伤

## 状态枚举
enum ShootState {
	IDLE,      # 待机状态，正常移动，检测触发
	SHOOTING   # 发射中，执行多轮发射
}

var state: ShootState = ShootState.IDLE

## ==================== 可配置参数 ====================

## 基础射击配置
var shoot_range: float = 600.0        # 射击范围（触发距离）
var shoot_interval: float = 2.0       # 射击间隔（冷却时间，秒）

## 子弹配置
var bullet_speed: float = 400.0       # 子弹速度
var bullet_damage: int = 10           # 子弹伤害
var bullet_id: String = "basic"       # 子弹ID（从数据库获取）
var bullet_scene_path: String = ""    # 子弹场景路径（可选，优先使用）

## 多轮发射配置
var bullet_rounds: int = 1            # 发射轮次
var bullet_round_interval: float = 0.5 # 每轮间隔时间（秒）
var bullets_per_round: int = 1        # 每轮发射颗数
var spread_angle: float = 0.0         # 散射角度（度），如60度 = -30°, 0°, +30°

## 发射位置
var shoot_offset: Vector2 = Vector2(0, -30)  # 发射位置偏移（相对于敌人中心）

## 发射特效配置（枪口特效）
var fx_sprite_frames_path: String = ""  # 特效 SpriteFrames 资源路径
var fx_animation_name: String = ""      # 特效动画名
var fx_offset: Vector2 = Vector2.ZERO   # 特效偏移（相对于发射位置）
var fx_scale: Vector2 = Vector2(1.0, 1.0) # 特效缩放

## 击中特效配置
var hit_fx_sprite_frames_path: String = ""  # 击中特效 SpriteFrames 资源路径
var hit_fx_animation_name: String = ""      # 击中特效动画名
var hit_fx_scale: Vector2 = Vector2(1.0, 1.0) # 击中特效缩放

## 发射动作配置
var shoot_sprite_anim: String = ""      # SpriteFrames 发射动画名
var shoot_anim_player: String = ""      # AnimationPlayer 动画名

## ==================== 内部状态 ====================

var shoot_timer: float = 0.0          # 射击冷却计时器
var bullet_scene: PackedScene = null
var fx_sprite_frames: SpriteFrames = null
var hit_fx_sprite_frames: SpriteFrames = null

## 多轮发射状态
var current_round: int = 0            # 当前发射轮次
var round_timer: float = 0.0          # 轮次间隔计时器
var base_direction: Vector2 = Vector2.RIGHT  # 基准发射方向（朝向玩家）

func _on_initialize() -> void:
	# 从配置中读取基础参数
	shoot_range = config.get("shoot_range", 600.0)
	shoot_interval = config.get("shoot_interval", 2.0)
	bullet_speed = config.get("bullet_speed", 400.0)
	bullet_damage = config.get("bullet_damage", 10)
	bullet_id = config.get("bullet_id", "basic")
	bullet_scene_path = config.get("bullet_scene_path", "")
	
	# 多轮发射配置
	bullet_rounds = config.get("bullet_rounds", 1)
	bullet_round_interval = config.get("bullet_round_interval", 0.5)
	bullets_per_round = config.get("bullets_per_round", 1)
	spread_angle = config.get("spread_angle", 0.0)
	
	# 发射位置
	shoot_offset = config.get("shoot_offset", Vector2(0, -30))
	
	# 枪口特效配置
	fx_sprite_frames_path = config.get("fx_sprite_frames_path", "")
	fx_animation_name = config.get("fx_animation_name", "")
	fx_offset = config.get("fx_offset", Vector2.ZERO)
	fx_scale = config.get("fx_scale", Vector2(1.0, 1.0))
	
	# 击中特效配置
	hit_fx_sprite_frames_path = config.get("hit_fx_sprite_frames_path", "")
	hit_fx_animation_name = config.get("hit_fx_animation_name", "")
	hit_fx_scale = config.get("hit_fx_scale", Vector2(1.0, 1.0))
	
	# 动作配置
	shoot_sprite_anim = config.get("shoot_sprite_anim", "")
	shoot_anim_player = config.get("shoot_anim_player", "")
	
	# 加载子弹场景
	if bullet_scene_path != "":
		bullet_scene = load(bullet_scene_path) as PackedScene
	else:
		bullet_scene = load("res://scenes/bullets/enemy_bullet.tscn") as PackedScene
	
	if not bullet_scene:
		push_error("[ShootingBehavior] 无法加载子弹场景")
	
	# 加载枪口特效资源
	if fx_sprite_frames_path != "":
		fx_sprite_frames = load(fx_sprite_frames_path) as SpriteFrames
		if not fx_sprite_frames:
			push_error("[ShootingBehavior] 无法加载枪口特效资源: " + fx_sprite_frames_path)
	
	# 加载击中特效资源
	if hit_fx_sprite_frames_path != "":
		hit_fx_sprite_frames = load(hit_fx_sprite_frames_path) as SpriteFrames
		if not hit_fx_sprite_frames:
			push_error("[ShootingBehavior] 无法加载击中特效资源: " + hit_fx_sprite_frames_path)
	
	state = ShootState.IDLE
	# 刷新创建时默认进入冷却，避免怪物生成后立刻放技能
	# 只有冷却结束后才允许第一次触发射击
	shoot_timer = shoot_interval

func _on_update(delta: float) -> void:
	if not enemy or enemy.is_dead:
		return
	
	match state:
		ShootState.IDLE:
			_update_idle(delta)
		
		ShootState.SHOOTING:
			_update_shooting(delta)

## 更新待机状态
func _update_idle(delta: float) -> void:
	# 更新冷却计时器
	if shoot_timer > 0:
		shoot_timer -= delta
	
	# 检查是否在射程内
	var player = get_player()
	if not player:
		return
	
	var distance = get_distance_to_player()
	if distance <= shoot_range and shoot_timer <= 0:
		# 在射程内且冷却完成，开始射击
		_start_shooting()

## 开始射击
func _start_shooting() -> void:
	var player = get_player()
	if not player or not enemy:
		return
	
	state = ShootState.SHOOTING
	current_round = 0
	round_timer = 0.0
	
	# 记录基准发射方向（朝向玩家）
	base_direction = get_direction_to_player()
	
	# 播放发射动作
	_play_shoot_animation()
	
	# 立即发射第一轮
	_shoot_one_round()
	current_round = 1
	
	print("[ShootingBehavior] 开始射击 | 总轮次:", bullet_rounds, " 每轮:", bullets_per_round, "颗 散射:", spread_angle, "度")

## 更新射击状态
func _update_shooting(delta: float) -> void:
	if not enemy:
		return
	
	# 保持技能动画持续播放（防止非循环动画结束后停止）
	_ensure_skill_animation_playing()
	
	# 检查是否已完成所有轮次
	if current_round >= bullet_rounds:
		_end_shooting()
		return
	
	# 更新轮次间隔计时器
	round_timer += delta
	
	# 检查是否可以发射下一轮
	if round_timer >= bullet_round_interval:
		# 更新基准方向（每轮重新瞄准玩家）
		base_direction = get_direction_to_player()
		
		_shoot_one_round()
		current_round += 1
		round_timer = 0.0
		print("[ShootingBehavior] 发射第", current_round, "/", bullet_rounds, "轮")

## 发射一轮子弹（支持散射）
func _shoot_one_round() -> void:
	if not bullet_scene or not enemy:
		return
	
	# 检查怪物是否朝右（翻转状态）
	# 怪物默认朝左（flip_h = false），翻转后朝右（flip_h = true）
	var is_facing_right = _is_enemy_facing_right()
	
	# 计算发射位置（考虑朝向）
	# 怪物朝左（默认）时，偏移X取反；怪物朝右时，偏移保持原值
	var actual_shoot_offset = shoot_offset
	if not is_facing_right:
		actual_shoot_offset.x = -actual_shoot_offset.x
	var shoot_pos = enemy.global_position + actual_shoot_offset
	
	# 播放枪口特效（每轮一次）
	_play_fx_effect(shoot_pos, is_facing_right)
	
	# 计算散射角度
	var angles: Array[float] = _calculate_spread_angles()
	
	# 发射每颗子弹
	for angle_offset in angles:
		var direction = base_direction.rotated(deg_to_rad(angle_offset))
		_spawn_bullet(shoot_pos, direction)

## 计算散射角度数组
func _calculate_spread_angles() -> Array[float]:
	var angles: Array[float] = []
	
	if bullets_per_round <= 1 or spread_angle <= 0:
		# 单颗子弹或无散射，只有0度
		angles.append(0.0)
	else:
		# 多颗子弹，均匀分布在 [-spread_angle/2, +spread_angle/2]
		var half_spread = spread_angle / 2.0
		var step = spread_angle / (bullets_per_round - 1)
		
		for i in range(bullets_per_round):
			var angle = -half_spread + i * step
			angles.append(angle)
	
	return angles

## 生成一颗子弹
func _spawn_bullet(pos: Vector2, direction: Vector2) -> void:
	# 联网模式：通过 NetworkPlayerManager 广播子弹
	if GameMain.current_mode_id == "online":
		NetworkPlayerManager.broadcast_enemy_bullet(pos, direction, bullet_speed, bullet_damage, bullet_id, bullet_scene_path)
		return
	
	# 单机模式：直接生成子弹
	var bullet = bullet_scene.instantiate()
	if not bullet:
		push_error("[ShootingBehavior] 无法实例化子弹")
		return
	
	# 添加到场景树
	get_tree().root.add_child(bullet)
	
	# 设置子弹朝向（子弹右侧为正方向）
	bullet.rotation = direction.angle()
	
	# 初始化子弹
	if bullet.has_method("start"):
		bullet.start(pos, direction, bullet_speed, bullet_damage)
	elif bullet.has_method("initialize_with_data"):
		var bullet_data = EnemyBulletDatabase.get_bullet_data(bullet_id)
		if bullet_data:
			bullet_data.damage = bullet_damage
			bullet_data.speed = bullet_speed
			bullet.initialize_with_data(pos, direction, bullet_data)
		else:
			bullet.start(pos, direction, bullet_speed, bullet_damage)
	else:
		push_error("[ShootingBehavior] 子弹没有start或initialize_with_data方法")
		bullet.queue_free()
		return
	
	# 设置击中特效
	if hit_fx_sprite_frames and hit_fx_animation_name != "" and bullet.has_method("set_hit_fx"):
		bullet.set_hit_fx(hit_fx_sprite_frames, hit_fx_animation_name, hit_fx_scale)

## 播放发射动作（整个技能期间持续播放）
func _play_shoot_animation() -> void:
	if not enemy:
		return
	
	# 优先使用 skill_execute 动画（通过 enemy_data.animations 映射）
	# 这会在整个技能期间持续播放
	enemy.play_animation("skill_execute")
	
	# 播放 AnimationPlayer 动画
	if shoot_anim_player != "":
		enemy.play_skill_animation(shoot_anim_player)

## 确保技能动画持续播放（防止非循环动画结束后停止）
func _ensure_skill_animation_playing() -> void:
	if not enemy:
		return
	
	var sprite = enemy.get_node_or_null("AnimatedSprite2D")
	if not sprite:
		return
	
	# 获取 skill_execute 对应的实际动画名
	var anim_name = "skill_execute"
	if enemy.enemy_data and enemy.enemy_data.animations.has("skill_execute"):
		var mapped_name = enemy.enemy_data.animations.get("skill_execute", "")
		if mapped_name != "" and mapped_name != null:
			anim_name = mapped_name
		else:
			return  # 没有配置 skill_execute 动画
	
	# 检查动画是否已停止播放（非循环动画播放完毕）
	if not sprite.is_playing() or sprite.animation != anim_name:
		if sprite.sprite_frames and sprite.sprite_frames.has_animation(anim_name):
			sprite.play(anim_name)

## 检查怪物是否朝右（翻转状态）
## 怪物默认朝左（flip_h = false），翻转后朝右（flip_h = true）
func _is_enemy_facing_right() -> bool:
	if not enemy:
		return false
	
	var sprite = enemy.get_node_or_null("AnimatedSprite2D")
	if sprite:
		return sprite.flip_h  # flip_h = true 表示朝右
	return false

## 播放枪口特效（每轮一次）
## 特效默认朝右，怪物默认朝左
## 特效绑定在敌人身上跟随移动
func _play_fx_effect(_shoot_pos: Vector2, is_facing_right: bool = false) -> void:
	if not enemy or not fx_sprite_frames or fx_animation_name == "":
		return
	
	# 检查是否有这个动画
	if not fx_sprite_frames.has_animation(fx_animation_name):
		push_error("[ShootingBehavior] 特效资源中没有动画: " + fx_animation_name)
		return
	
	# 计算特效局部偏移（考虑朝向）
	# 怪物朝左（默认）时，偏移X取反；怪物朝右时，偏移保持原值
	var actual_offset = shoot_offset + fx_offset
	if not is_facing_right:
		actual_offset.x = -actual_offset.x
	
	# 创建特效节点
	var fx_node = AnimatedSprite2D.new()
	fx_node.sprite_frames = fx_sprite_frames
	fx_node.position = actual_offset  # 使用局部坐标
	fx_node.scale = fx_scale
	fx_node.z_index = 10  # 在上层显示
	
	# 特效默认朝右，怪物朝左时特效需要翻转
	if not is_facing_right:
		fx_node.flip_h = true
	
	# 添加到敌人节点（跟随敌人移动）
	enemy.add_child(fx_node)
	
	# 播放动画
	fx_node.play(fx_animation_name)
	
	# 动画结束后自动清理
	fx_node.animation_finished.connect(func(): fx_node.queue_free())

## 结束射击
func _end_shooting() -> void:
	state = ShootState.IDLE
	shoot_timer = shoot_interval  # 设置冷却时间
	
	# 恢复行走动画
	if enemy:
		enemy.play_animation("walk")
		enemy.stop_skill_animation()
	
	print("[ShootingBehavior] 射击结束，进入冷却 | 冷却时间:", shoot_interval, "秒")

## 检查技能是否激活（用于外部判断，如 AI 控制器）
func is_skill_active() -> bool:
	return state == ShootState.SHOOTING
