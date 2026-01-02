extends BaseGameMode
class_name OnlineMode

## Online模式 - 联网对战年会模式
## 核心特性：
## - 多人联网对战
## - Boss vs Player vs Impostor 三方对抗
## - 可以复活（消耗 master_key）

func _init() -> void:
	mode_id = "online"
	mode_name = "联网模式"
	mode_description = "联网对战，三方混战"
	total_waves = 30
	victory_condition_type = "waves"
	wave_config_id = "online"  # 使用联网模式波次配置（从JSON加载）
	victory_waves = 30  # Online模式胜利条件：完成30波
	allow_revive = true  # Online模式允许复活（消耗 master_key）
	initial_gold = 10  # Online模式初始gold数量（由 NetworkPlayerManager 根据角色分配）
	initial_master_key = 2  # Online模式初始masterkey数量（由 NetworkPlayerManager 根据角色分配）
	spawn_indicator_delay = 0.5  # 敌人刷新预警延迟（秒）

## 注意：波次配置已由wave_system_v3从JSON文件（wave_config_id）加载，不再使用硬编码配置
## 注意：胜利失败判定已由base_game_mode统一实现，通过配置参数控制
## 注意：联网模式下的角色分配、资源初始化由 NetworkPlayerManager 处理

## 是否允许复活
func can_revive() -> bool:
	return allow_revive

