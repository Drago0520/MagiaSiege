extends CharacterBody3D
class_name NPCSoldier

## ============================================================
## NPC Soldado - Máquina de estados (estilo TABS)
##
## Prioridad de decisión, evaluada cada frame:
##   1) Si hay un NPC enemigo dentro del rango de visión -> atacarlo
##   2) Si no, pero hay un Player enemigo a la vista       -> atacarlo
##   3) Si no hay nada que atacar -> correr hacia el punto actual.
##      Si no quedan puntos, carga contra el NPC/Player más cercano.
## ============================================================

enum Team { BLUE, RED }
enum State { MOVING_TO_POINT, ATTACKING, DEAD }

# --- Equipo ---
@export_group("Equipo")
@export var team: Team = Team.BLUE

# --- Movimiento ---
@export_group("Movimiento")
@export var move_speed: float = 4.0
@export var rotation_speed: float = 8.0
@export var gravity: float = 20.0

# --- Combate ---
@export_group("Combate")
@export var max_health: float = 100.0
@export var attack_damage: float = 10.0
@export var attack_range: float = 2.0
@export var attack_cooldown: float = 1.0
@export var vision_range: float = 15.0

@export_group("Empuje entre aliados")
@export var push_strength: float = 1.5 # qué tan fuerte empuja un aliado bloqueado al que tiene enfrente

# --- Puntos de captura (arrastra Node3D/Marker3D en el inspector) ---
@export_group("Puntos de captura")
@export var capture_points: Array[Node3D] = []
@export var capture_radius: float = 1.5

# --- Debug ---
@export_group("Debug")
@export var debug_paint_team_color: bool = false # pinta el mesh según el equipo, solo para debug visual
@export var debug_team_colors: Array[Color] = [
	Color(0.2, 0.4, 1.0), # BLUE
	Color(1.0, 0.2, 0.2), # RED
]

# --- Referencias a nodos hijos (ajusta los nombres si difieren en tu escena) ---
@onready var vision_area: Area3D = $VisionArea
@onready var nav_agent: NavigationAgent3D = $NavigationAgent3D
@onready var mesh_instance: MeshInstance3D = $MeshInstance3D

# --- Estado interno ---
var current_health: float
var current_state: State = State.MOVING_TO_POINT
var target: Node3D = null
var _attack_timer: float = 0.0
var _bodies_in_range: Array[Node3D] = []
var _capturing_point: Node3D = null
var _capture_progress: float = 0.0
var _push_velocity: Vector3 = Vector3.ZERO # empuje recibido de aliados este frame


func _ready() -> void:
	current_health = max_health
	add_to_group("npc")
	add_to_group("combatant")

	var col: CollisionShape3D = vision_area.get_node("CollisionShape3D")
	if col.shape is SphereShape3D:
		col.shape.radius = vision_range

	if debug_paint_team_color:
		apply_debug_team_color()


func _physics_process(delta: float) -> void:
	if current_state == State.DEAD:
		return

	if not is_on_floor():
		velocity.y -= gravity * delta

	decide_state()

	match current_state:
		State.ATTACKING:
			process_attacking(delta)
		State.MOVING_TO_POINT:
			process_moving_to_point(delta)

	# Aplico el empuje que me hayan dado aliados bloqueados detrás mío
	velocity.x += _push_velocity.x
	velocity.z += _push_velocity.z
	_push_velocity = Vector3.ZERO

	move_and_slide()

	push_blocking_allies()


# ---------------------------------------------------------
# DECISIÓN DE ESTADO
# Enemigo NPC y enemigo Player tienen la misma prioridad:
# se ataca al que esté más cerca, sea del tipo que sea.
# ---------------------------------------------------------
func decide_state() -> void:
	var enemy := get_nearest_hostile()
	if enemy:
		target = enemy
		current_state = State.ATTACKING
		return

	target = null
	if current_state == State.ATTACKING:
		current_state = State.MOVING_TO_POINT


# ---------------------------------------------------------
# ATACAR (persigue si está lejos, ataca si está en rango)
# ---------------------------------------------------------
func process_attacking(delta: float) -> void:
	if not is_instance_valid(target):
		current_state = State.MOVING_TO_POINT
		return

	var dist := global_position.distance_to(target.global_position)
	face_target(target.global_position, delta)

	if dist > attack_range:
		nav_agent.target_position = target.global_position
		move_along_path()
	else:
		velocity.x = 0
		velocity.z = 0
		_attack_timer -= delta
		if _attack_timer <= 0.0:
			_attack_timer = attack_cooldown
			do_attack(target)


func do_attack(t: Node3D) -> void:
	if t.has_method("take_damage"):
		t.take_damage(attack_damage)


# ---------------------------------------------------------
# EMPUJE ENTRE ALIADOS
# Si quedo bloqueado por un aliado (ej: está peleando adelante mío
# y no me deja pasar), le doy un pequeño empujón para abrirme campo.
# ---------------------------------------------------------
func push_blocking_allies() -> void:
	for i in get_slide_collision_count():
		var collision := get_slide_collision(i)
		var collider := collision.get_collider()

		if not (collider is NPCSoldier):
			continue
		if collider == self or not collider.is_alive():
			continue
		if collider.get_team() != team:
			continue # a los enemigos no los empujo, a esos les pego

		# Punto al que intento llegar (mi objetivo de ataque o mi punto
		# de captura). IMPORTANTE: uso la posición del objetivo, NO mi
		# propia rotación (global_transform.basis) — usar la rotación
		# arma un feedback loop con face_target() y por eso giraba solo.
		var aim_pos: Vector3
		if is_instance_valid(target):
			aim_pos = target.global_position
		else:
			var point := get_nearest_available_point()
			aim_pos = point.global_position if point else (global_position - global_transform.basis.z)

		var forward := aim_pos - global_position
		forward.y = 0
		if forward.length() < 0.01:
			continue
		forward = forward.normalized()
		var right := Vector3(-forward.z, 0.0, forward.x) # perpendicular, geométrico, no depende de mi rotación

		# Lado fijo y determinístico por par de IDs: mientras dure el
		# bloqueo, siempre empujo para el mismo lado. Nada de basarme
		# en la normal de colisión (esa sí es ruidosa entre frames).
		var side := 1.0 if get_instance_id() < collider.get_instance_id() else -1.0

		collider.receive_push(right * side * push_strength)

func receive_push(amount: Vector3) -> void:
	_push_velocity += amount


# ---------------------------------------------------------
# CORRER A UN PUNTO
# ---------------------------------------------------------
func process_moving_to_point(delta: float) -> void:
	var point := get_nearest_available_point()

	if not point:
		# No quedan puntos por capturar. Si hubiera un enemigo visible,
		# decide_state() ya nos habría mandado a ATTACKING antes de
		# llegar acá, así que no hay nada que hacer más que esperar.
		velocity.x = 0
		velocity.z = 0
		return

	var dist := global_position.distance_to(point.global_position)
	face_target(point.global_position, delta)

	if dist <= capture_radius:
		velocity.x = 0
		velocity.z = 0

		if _capturing_point != point:
			_capturing_point = point
			_capture_progress = 0.0

		_capture_progress += delta
		var required_time: float = point.capture_time if "capture_time" in point else 0.0

		if _capture_progress >= required_time:
			on_point_captured(point)
			_capturing_point = null
			_capture_progress = 0.0
	else:
		_capturing_point = null
		_capture_progress = 0.0
		nav_agent.target_position = point.global_position
		move_along_path()


func get_nearest_available_point() -> Node3D:
	var nearest: Node3D = null
	var nearest_dist := INF
	for point in capture_points:
		if not is_instance_valid(point):
			continue
		if "owner_team" in point and point.owner_team == team:
			continue # ya es mío, no necesito volver a capturarlo
		var d := global_position.distance_to(point.global_position)
		if d < nearest_dist:
			nearest_dist = d
			nearest = point
	return nearest


func on_point_captured(point: Node3D) -> void:
	if point.has_method("capture"):
		point.capture(team)


func move_along_path() -> void:
	if nav_agent.is_navigation_finished():
		velocity.x = 0
		velocity.z = 0
		return
	var next_pos := nav_agent.get_next_path_position()
	var dir := next_pos - global_position
	dir.y = 0
	dir = dir.normalized()
	velocity.x = dir.x * move_speed
	velocity.z = dir.z * move_speed


func face_target(pos: Vector3, delta: float) -> void:
	var dir := pos - global_position
	dir.y = 0
	if dir.length() < 0.01:
		return
	var target_rot := atan2(dir.x, dir.z)
	rotation.y = lerp_angle(rotation.y, target_rot, rotation_speed * delta)


# ---------------------------------------------------------
# DETECCIÓN (Area3D de visión)
# ---------------------------------------------------------
func _on_vision_area_body_entered(body: Node3D) -> void:
	if body == self:
		return
	if body.is_in_group("npc") or body.is_in_group("player"):
		_bodies_in_range.append(body)


func _on_vision_area_body_exited(body: Node3D) -> void:
	_bodies_in_range.erase(body)


func get_nearest_hostile() -> Node3D:
	var nearest: Node3D = null
	var nearest_dist := INF
	for body in _bodies_in_range:
		if not is_instance_valid(body):
			continue
		if not is_hostile(body):
			continue
		if body.has_method("is_alive") and not body.is_alive():
			continue
		var d := global_position.distance_to(body.global_position)
		if d < nearest_dist:
			nearest_dist = d
			nearest = body
	return nearest


func is_hostile(body: Node3D) -> bool:
	if body.has_method("get_team"):
		return body.get_team() != team
	return false


func get_team() -> int:
	return team


# ---------------------------------------------------------
# DEBUG (solo visual, no afecta gameplay)
# ---------------------------------------------------------
func apply_debug_team_color() -> void:
	if not mesh_instance:
		return
	var mat := StandardMaterial3D.new()
	if team < debug_team_colors.size():
		mat.albedo_color = debug_team_colors[team]
	else:
		mat.albedo_color = Color.WHITE
	mesh_instance.set_surface_override_material(0, mat)


# ---------------------------------------------------------
# VIDA / DAÑO
# ---------------------------------------------------------
func take_damage(amount: float) -> void:
	if current_state == State.DEAD:
		return
	current_health -= amount
	if current_health <= 0.0:
		die()


func is_alive() -> bool:
	return current_state != State.DEAD


func die() -> void:
	current_state = State.DEAD
	remove_from_group("npc")
	remove_from_group("combatant")
	set_physics_process(false)
	# Aquí va tu ragdoll/animación de muerte estilo TABS, sonido, etc.
	queue_free() # o desactiva la colisión y deja el cuerpo tirado si prefieres el efecto TABS
