extends Node3D
class_name CapturePoint

## ============================================================
## Punto de control
## El NPCSoldier ya hace el chequeo de distancia y el conteo de
## tiempo (capture_radius / capture_time) desde su propio script.
## Este script solo:
##   - guarda quién es el dueño actual
##   - cambia el color del punto para reflejarlo
##   - avisa con una señal cuando cambia de dueño
## ============================================================

signal captured(team: int)

@export var capture_time: float = 3.0 # segundos que un NPC debe quedarse para capturarlo

# Colores por equipo. Índice = valor del enum Team en npc_soldier.gd (BLUE=0, RED=1)
@export var neutral_color: Color = Color(0.6, 0.6, 0.6)
@export var team_colors: Array[Color] = [
	Color(0.2, 0.4, 1.0), # BLUE
	Color(1.0, 0.2, 0.2), # RED
]

@onready var mesh_instance: MeshInstance3D = $MeshInstance3D

var owner_team: int = -1 # -1 = neutral, nadie lo ha capturado aún
var _material: StandardMaterial3D


func _ready() -> void:
	# Duplicamos el material para que cada punto tenga el suyo propio.
	# Si no hacemos esto, cambiar el color de un punto cambiaría
	# el color de TODOS los puntos que compartan el mismo material.
	if mesh_instance.get_surface_override_material(0):
		_material = mesh_instance.get_surface_override_material(0).duplicate()
	else:
		_material = StandardMaterial3D.new()
	mesh_instance.set_surface_override_material(0, _material)

	_update_color()


func capture(team: int) -> void:
	if owner_team == team:
		return
	owner_team = team
	_update_color()
	captured.emit(team)


func reset_point() -> void:
	owner_team = -1
	_update_color()


func _update_color() -> void:
	if owner_team == -1 or owner_team >= team_colors.size():
		_material.albedo_color = neutral_color
	else:
		_material.albedo_color = team_colors[owner_team]
