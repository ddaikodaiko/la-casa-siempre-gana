class_name Pareja
extends Node
## El cooperativo online de punta a punta: qué le cuenta el anfitrión al invitado y qué le
## pide el invitado al anfitrión. Lo crea main.gd por código, junto a Red (el cable).
##
## La partida es la del cooperativo local, y la lleva entera el ANFITRIÓN: el J2 es un muñeco
## que se pone donde dice el invitado. El INVITADO no simula nada: mueve a su propio jugador
## (así responde al instante) y todo lo demás lo ve "en espejo":
##   - enemigos, balas, monedas, avisos...: Espejo copia los nodos tal cual se dibujan;
##   - sonidos y efectos del jugo: Red.cola (se apuntan solos al sonar o al pintarse);
##   - el estado (Juego, puertas, mesas, avisos, paneles...): un diccionario del que solo
##     viaja lo que cambia.
## Lo que hace el invitado (rodar, volcar, comprar, elegir carta...) viaja como petición y el
## anfitrión decide. Si algo de aquí no cuadra con lo que llega, se ignora: nunca se rompe.

signal sala_cambiada  # algo del vestíbulo ha cambiado (para repintarlo)
signal cerrada(motivo: String, jugaba: bool)  # el invitado se ha quedado sin sala (el anfitrión se ha ido)

# Del anfitrión al invitado.
const A_VESTIBULO := 1  # [_, {fase}]
const A_EMPEZAR := 2  # [_, juego completo, nombres]
const A_SALA := 3  # [_, n_sala, pos, salas, venimos, p1, p2]
const A_TIC := 4  # [_, n_sala, jugadores, espejo, eventos, estado]
const A_FIN := 5  # [_, gano]
const A_PORTADA := 6  # el anfitrión ha vuelto al vestíbulo
# Del invitado al anfitrión.
const I_YO := 20  # [_, n_sala, pos, dir, ratón o null]
const I_RODAR := 21  # [_, dirección]
const I_ACCION := 22  # [_, "interactuar" | "ordago"]
const I_ELEGIR := 23  # [_, id de carta, o "" para saltar]
const I_SUSTITUIR := 24  # [_, ranura, o -1 para cancelar]
const I_TECLA := 25  # [_, tecla de panel]
const I_RATON := 26  # [_, pos, pulsado, botón]
const I_PAUSA := 27  # [_, bool]
const I_PERSONAJE := 28  # [_, id]
const I_VOLCAR := 29  # [_, índice de mesa, dirección]
const I_COLA := 30  # [_, [eventos de Red.cola]]

# Más cosas que se apuntan en Red.cola, además de las de Red (FX, SONIDO, MUSICA).
const CARTEL := 10  # [_, título, subtítulo]
const VIBRAR := 11  # [_, [débil, fuerte, segundos]]
const CICLO := 12  # [_, plan]
const PASO := 13  # [_, paso]
const CICLO_FIN := 14

const TIC := 1.0 / 20.0  # lo que manda el anfitrión, veces por segundo
const YO := 1.0 / 30.0  # y el invitado
const TECLAS_PANEL := [KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_ENTER, KEY_ESCAPE]
const ZONA := Rect2(-24, -24, 688, 352)  # donde puede estar un jugador (con margen para las puertas)
## Lo de Juego que el invitado tiene que ver igual. tiempo_partida solo viaja al empezar.
const CAMPOS_JUEGO := ["vida", "vida_max", "oro", "piso", "enemigos_eliminados", "racha", "personaje", "mesa",
	"extremo", "diario", "imposible", "infinito", "deuda", "orden_jefes", "cartas", "objetos", "stats",
	"transformaciones", "mejor_combo", "oro_total", "ordagos", "contrato", "coop", "personaje2", "vida2",
	"vida_max2", "titular", "en_combate", "progreso_sala", "balas_sala", "desatado"]

var red: Red
var p  # main.gd (sin tipo: no tiene class_name)
var espejo := Espejo.new()
## Hay partida online en marcha en este ordenador (anfitrión o invitado).
var en_partida := false
## El personaje del invitado (lo elige él en el vestíbulo).
var personaje_invitado := "tahur"
## Lo que hace el otro ahora mismo, para el vestíbulo: "sala" o "eligiendo".
var fase_anfitrion := "sala"
## El otro tiene su menú de pausa abierto.
var pausa_remota := false
var n_sala := 0
var tics_enviados := 0
var tics_recibidos := 0

var _t_tic := 0.0
var _t_yo := 0.0
var _ultimo := {}  # anfitrión: el último estado mandado
var _pausa_mia := false  # la pausa del árbol la he puesto yo por el otro
var _arrastre := Vector2.ZERO  # invitado: lo que tira de su jugador (lo dice el anfitrión)
var _raton = null  # invitado: dónde tiene el ratón sobre un panel del anfitrión
var _rodaba_j1 := false
var _panel_vars := {}  # nombres de las variables que se copian de cada panel


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	red.mensaje.connect(_al_llegar)
	red.companero_fuera.connect(_al_irse_companero)
	red.companero_vuelve.connect(_al_volver_companero)
	red.estado_cambiado.connect(_al_cambiar_red)
	red.error_sala.connect(func(_motivo: String) -> void: _soltar())
	personaje_invitado = PersonajesDB.PERSONAJES.keys()[0]


# ------------------------------------------------------------ quién soy
func anfitrion() -> bool:
	return red.en_pareja() and red.anfitrion


func jugando_anfitrion() -> bool:
	return en_partida and red.en_pareja() and red.anfitrion


func jugando_invitado() -> bool:
	return en_partida and red.invitado()


## La conexión (la mía o la del otro) está cortada y se está intentando recuperar.
func cortado() -> bool:
	return red.en_sala() and (red.esperando or red.estado == Red.Estado.VOLVIENDO)


# ------------------------------------------------------------ vestíbulo
## El invitado elige su personaje (solo entre los que tiene abiertos).
func elegir_personaje(id: String) -> void:
	if not PersonajesDB.PERSONAJES.has(id):
		return
	personaje_invitado = id
	if red.invitado():
		red.enviar([I_PERSONAJE, id])
	sala_cambiada.emit()


## El anfitrión avisa de lo que está haciendo antes de empezar.
func poner_fase(fase: String) -> void:
	fase_anfitrion = fase
	if anfitrion():
		red.enviar([A_VESTIBULO, {"fase": fase}])


func _al_cambiar_red() -> void:
	if red.invitado() and red.hay_companero and not en_partida:
		red.enviar([I_PERSONAJE, personaje_invitado])  # nada más entrar, para que el anfitrión lo vea
	if anfitrion() and not en_partida:
		red.enviar([A_VESTIBULO, {"fase": fase_anfitrion}])
	sala_cambiada.emit()


## Dejar la sala a propósito (desde el vestíbulo).
func salir() -> void:
	_soltar()
	red.salir()


# ------------------------------------------------------------ anfitrión: empezar y salas
## Lo que necesita main para empezar una partida con el invitado.
func config_coop() -> Dictionary:
	return {"personaje2": personaje_invitado, "entrada1": Mando.TODO, "entrada2": Mando.REMOTO}


## main acaba de preparar a los jugadores de una partida nueva.
func al_arrancar() -> void:
	if not anfitrion() or not Juego.coop or p.jugador2 == null or not p.jugador2.remoto:
		return
	en_partida = true
	n_sala = 0
	_empezar_a_contar()
	Red.reenviando = true  # desde ya: lo primero que suene también es para él


func _empezar_a_contar() -> void:
	espejo.reiniciar()
	_ultimo = {}
	pausa_remota = false
	Red.cola.clear()
	var datos := Juego.volcar()
	datos["tiempo_partida"] = Juego.tiempo_partida
	red.enviar([A_EMPEZAR, datos, red.companero])


## main acaba de entrar en una sala (o de volver a ella).
func al_entrar_sala(venimos: Vector2i) -> void:
	if not jugando_anfitrion():
		return
	if n_sala > 0:
		_mandar_tic()  # lo último de la sala que se deja (sus sonidos, lo que ha cambiado)
	n_sala += 1
	espejo.reiniciar()
	p.jugador2.remoto_pos = p.jugador2.position
	red.enviar([A_SALA, n_sala, p.actual.pos, p.salas, venimos, p.jugador.position, p.jugador2.position, Juego.piso])


func al_acabar(gano: bool) -> void:
	if not jugando_anfitrion():
		return
	_mandar_tic()  # lo último que ha pasado, antes del final
	red.enviar([A_FIN, gano])


## main vuelve al menú. Devuelve true si hay que enseñar el vestíbulo en vez de la portada.
func al_ir_al_menu() -> bool:
	if not en_partida:
		return red.en_sala()
	var era_invitado := red.invitado()
	if not era_invitado and red.en_pareja():
		red.enviar([A_PORTADA])
	_soltar()
	if era_invitado:
		red.salir()  # el invitado que se va al menú deja la sala
		return false
	return red.en_sala()


# ------------------------------------------------------------ cada fotograma
func _process(delta: float) -> void:
	Red.reenviando = jugando_anfitrion() and not p._menu.visible and not cortado()
	Red.espejo = jugando_invitado()
	if not en_partida:
		return
	var real := delta / maxf(Engine.time_scale, 0.001)
	if red.anfitrion:
		_llevar_pausa(pausa_remota or cortado())
		_t_tic += real
		if _t_tic >= TIC:
			_t_tic = fmod(_t_tic, TIC)
			_mandar_tic()
	else:
		_llevar_pausa_invitado()
		if not Red.cola.is_empty():
			red.enviar([I_COLA, Red.cola])
			Red.cola = []
	_pintar_letrero()


func _physics_process(delta: float) -> void:
	if not jugando_invitado() or p.jugador2 == null:
		return
	var yo = p.jugador2
	if _arrastre != Vector2.ZERO:
		yo.arrastre = _arrastre
	_t_yo += delta / maxf(Engine.time_scale, 0.001)
	if _t_yo >= YO:
		_t_yo = fmod(_t_yo, YO)
		red.enviar([I_YO, n_sala, yo.position, yo.direccion_vista, _raton])
		_raton = null


## El otro ha pausado (o se le ha cortado): el árbol se para aquí también, y se suelta
## cuando ya no hay motivo, salvo que algo de aquí (un panel, el menú) lo tenga parado.
func _llevar_pausa(hace_falta: bool) -> void:
	var arbol := get_tree()
	if hace_falta:
		if not arbol.paused:
			arbol.paused = true
			_pausa_mia = true
	elif _pausa_mia:
		_pausa_mia = false
		if arbol.paused and not p.algo_pausa():
			arbol.paused = false


func _llevar_pausa_invitado() -> void:
	get_tree().paused = pausa_remota or cortado() or p._menu.visible or p._pantalla.visible


func _pintar_letrero() -> void:
	var texto := ""
	if cortado():
		texto = Idioma.t("SE HA CORTADO LA CONEXIÓN") + "\n" + Idioma.t("VOLVIENDO A CONECTAR...")
	elif pausa_remota and not p._menu.visible and not p._pantalla.visible and not p.panel_a_la_vista():
		texto = Idioma.t("TU COMPAÑERO HA PAUSADO LA PARTIDA")
	p.poner_letrero(texto)


## El árbol está parado solo porque el otro ha pausado: el menú de aquí se puede abrir igual.
func pausa_prestada() -> bool:
	return en_partida and _pausa_mia and not p.algo_pausa()


# ------------------------------------------------------------ anfitrión: lo que manda
func _mandar_tic() -> void:
	if not red.en_pareja() or cortado():
		return
	var jugadores: Array = []
	for j in p.jugadores:
		jugadores.append([j.position, j.remoto_dir if j.remoto else j.direccion_vista, j.rodando(),
			j.direccion_rodar(), j.caido, j.reanimar, j.respiro(), j.arrastre_visto if j.remoto else Vector2.ZERO])
	var jefe := -1.0
	if is_instance_valid(p._horda.jefe):
		jefe = clampf(p._horda.jefe.vida / p._horda.jefe.vida_max, 0.0, 1.0)
	var copia: Array = espejo.capturar([p._horda, p._ataques, p._recogibles, p._efectos])
	var eventos := Red.cola
	Red.cola = []
	tics_enviados += 1
	red.enviar([A_TIC, n_sala, jugadores, copia, eventos, _cambios(_estado()), jefe])


## Todo lo que el invitado tiene que ver igual y no es un nodo del mundo.
func _estado() -> Dictionary:
	var e := {}
	for campo in CAMPOS_JUEGO:
		e["j:" + campo] = Juego.get(campo)
	e["fiebre"] = snappedf(Juego.fiebre, 0.05)
	e["desatado_t"] = snappedf(Juego.get("_desatado_t"), 0.25)
	e["pausa"] = p.algo_pausa()
	e["puertas"] = p._sala.get("_puertas_abiertas")
	e["mesas"] = p._sala.datos_mesas()
	e["limpia"] = bool(p.actual.get("limpia", false))
	e["aviso"] = p._aviso.text
	e["crono"] = p._crono.text if p._crono.visible else ""
	e["crono_a"] = snappedf(p._crono.modulate.a, 0.05)
	e["info"] = p._barra.info_externa
	e["pelea"] = p._barra.en_combate
	e["dueno"] = p._dueno_panel.indice if p._dueno_panel != null and is_instance_valid(p._dueno_panel) else -1
	e["selector"] = [p._selector.get("_ids"), p._selector.get("_titulo")] if p._selector.visible else []
	e["sustituir"] = p._carta_pendiente if p._barra.modo_sustituir else ""
	e["jefe"] = String(p._horda.jefe.nombre) if is_instance_valid(p._horda.jefe) else ""
	e["a_mano"] = p.algo_a_mano(p.jugador2)
	_estado_panel(e, "pe", p._panel)
	_estado_panel(e, "pa", p._panel_apuestas)
	return e


## Un panel del anfitrión (evento, apuestas) viaja tal cual está: sus variables de datos.
## El invitado lo pinta con ellas, sin lógica; lo que pulse llega aquí como teclas y clics.
func _estado_panel(e: Dictionary, clave: String, panel: Control) -> void:
	e[clave] = panel.visible
	if not panel.visible:
		return
	for nombre in _variables_de(panel):
		var limpio := _limpiar(panel.get(nombre))
		if limpio[0]:
			e[clave + ":" + nombre] = limpio[1]


func _variables_de(panel: Control) -> Array:
	var clave := panel.get_instance_id()
	if not _panel_vars.has(clave):
		var nombres: Array = []
		for prop in panel.get_script().get_script_property_list():
			if int(prop.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE:
				nombres.append(String(prop.name))
		_panel_vars[clave] = nombres
	return _panel_vars[clave]


## [vale, valor]: el valor sin nada que no sean datos. Los botones pierden lo que hacen
## (un Callable); lo demás que lleve objetos dentro no viaja.
static func _limpiar(v: Variant) -> Array:
	match typeof(v):
		TYPE_OBJECT, TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID:
			return [false, null]
		TYPE_ARRAY:
			var lista: Array = []
			for x in v:
				var limpio := _limpiar(x)
				if not limpio[0]:
					return [false, null]
				lista.append(limpio[1])
			return [true, lista]
		TYPE_DICTIONARY:
			var d := {}
			for k in v:
				if typeof(v[k]) == TYPE_CALLABLE:
					continue
				var limpio := _limpiar(v[k])
				if not limpio[0]:
					return [false, null]
				d[k] = limpio[1]
			return [true, d]
	return [true, v]


## Solo lo que ha cambiado desde el último mensaje.
func _cambios(e: Dictionary) -> Dictionary:
	var cambios := {}
	for k in e:
		var v = e[k]
		if _ultimo.has(k) and typeof(_ultimo[k]) == typeof(v) and _ultimo[k] == v:
			continue
		cambios[k] = v
		_ultimo[k] = v.duplicate(true) if v is Array or v is Dictionary else v
	for k in _ultimo.keys():
		if not e.has(k):
			_ultimo.erase(k)
	return cambios


## Lo que se apunta para el invitado desde main (un cartel, una vibración...).
static func evento(datos: Array) -> void:
	if Red.reenviando and Red.eco:
		Red.cola.append(datos)


func conectar_motor(motor: MotorCartas) -> void:
	motor.ciclo_empezado.connect(func(plan: Dictionary) -> void:
		if Red.reenviando:
			var limpio := _limpiar(plan)
			if limpio[0]:
				Red.cola.append([CICLO, limpio[1]]))
	motor.paso_ejecutado.connect(func(paso: Dictionary) -> void:
		if Red.reenviando:
			var limpio := _limpiar(paso)
			if limpio[0]:
				Red.cola.append([PASO, limpio[1]]))
	motor.ciclo_terminado.connect(func() -> void:
		if Red.reenviando:
			Red.cola.append([CICLO_FIN]))


# ------------------------------------------------------------ lo que llega
func _al_llegar(m: Array) -> void:
	var tipo: int = m[0]
	if red.anfitrion:
		if tipo >= I_YO:
			_del_invitado(tipo, m)
	elif tipo < I_YO:
		_del_anfitrion(tipo, m)


# ------------------------------------------------------------ anfitrión: lo que pide el invitado
func _del_invitado(tipo: int, m: Array) -> void:
	if tipo == I_PERSONAJE:
		if m.size() >= 2 and m[1] is String and PersonajesDB.PERSONAJES.has(m[1]):
			personaje_invitado = m[1]
			sala_cambiada.emit()
		return
	if not jugando_anfitrion() or p.jugador2 == null:
		return
	var j2 = p.jugador2
	match tipo:
		I_YO:
			if m.size() < 5 or not (m[1] is int) or not (m[2] is Vector2) or not (m[3] is Vector2):
				return
			if m[1] != n_sala or not _finito(m[2]) or not _finito(m[3]):
				return
			j2.remoto_pos = m[2].clamp(ZONA.position, ZONA.end)
			j2.remoto_dir = m[3].limit_length(1.0)
			if m[4] is Vector2 and _finito(m[4]):
				_raton_remoto(m[4], 0, MOUSE_BUTTON_NONE)
		I_RODAR:
			if m.size() >= 2 and m[1] is Vector2 and _finito(m[1]) and not get_tree().paused:
				Red.eco = false  # su voltereta ya la ha oído y visto él
				j2.rodar_remoto(m[1], true)
				Red.eco = true
		I_ACCION:
			if m.size() < 2 or not (m[1] is String) or get_tree().paused:
				return
			if m[1] == "interactuar":
				p._interactuar(j2)
			elif m[1] == "ordago":
				p.lanzar_ordago(j2)
		I_ELEGIR:
			if m.size() < 2 or not (m[1] is String) or p._dueno_panel != j2 or not p._selector.visible:
				return
			if m[1] == "":
				p._cerrar_selector()
			elif (p._selector.get("_ids") as Array).has(m[1]):
				p._al_elegir_carta(m[1])
		I_SUSTITUIR:
			if m.size() < 2 or not (m[1] is int) or p._dueno_panel != j2 or not p._barra.modo_sustituir:
				return
			if m[1] < 0:
				p._cerrar_selector()
			elif m[1] < Juego.cartas.size() and Juego.cartas[m[1]] != "":
				p._al_sustituir(m[1])
		I_TECLA:
			if m.size() >= 2 and m[1] is int and TECLAS_PANEL.has(m[1]):
				_tecla_remota(m[1])
		I_RATON:
			if m.size() >= 4 and m[1] is Vector2 and _finito(m[1]) and m[2] is bool and m[3] is int:
				_raton_remoto(m[1], 1 if m[2] else 2, m[3])
		I_PAUSA:
			if m.size() >= 2 and m[1] is bool:
				pausa_remota = m[1]
		I_VOLCAR:
			if m.size() < 3 or not (m[1] is int) or not (m[2] is Vector2) or m[1] < 0 or m[1] >= p._sala.mesas.size():
				return
			var mesa: Mesa = p._sala.mesas[m[1]]
			if mesa.estado == Mesa.Estado.DE_PIE and mesa.centro.distance_to(j2.position) < 90.0:
				Red.eco = false  # el polvo y el golpe ya los ha tenido él
				mesa.volcar(Sala.cardinal(m[2]), p._horda, p._sala.dano_mesas, p._sala.refuerzo_mesas)
				Red.eco = true
		I_COLA:
			if m.size() >= 2 and m[1] is Array:
				for ev in m[1]:
					_peticion(ev)


func _peticion(ev: Variant) -> void:
	if not (ev is Array) or ev.is_empty() or not (ev[0] is int):
		return
	if ev[0] == Red.MOVER_CARTA and ev.size() >= 3 and ev[1] is int and ev[2] is int:
		var n := Juego.cartas.size()
		if ev[1] >= 0 and ev[1] < n and ev[2] >= 0 and ev[2] < n and ev[1] != ev[2] and p._barra.puede_ordenar():
			Juego.mover_carta(ev[1], ev[2])
		else:
			_ultimo.erase("j:cartas")  # no vale: que vuelva a ver la fila de verdad


static func _numero(v: Variant) -> bool:
	return (v is float or v is int) and is_finite(float(v))


static func _finito(v: Vector2) -> bool:
	return is_finite(v.x) and is_finite(v.y)


## El panel del anfitrión que maneja ahora el invitado, o null.
func _panel_del_invitado() -> Control:
	if p._dueno_panel != p.jugador2:
		return null
	if p._panel.visible:
		return p._panel
	if p._panel_apuestas.visible:
		return p._panel_apuestas
	return null


func _tecla_remota(tecla: int) -> void:
	var panel := _panel_del_invitado()
	if panel == null:
		return
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.keycode = tecla as Key
	ev.physical_keycode = tecla as Key
	panel._unhandled_input(ev)


## tipo: 0 se mueve, 1 pulsa, 2 suelta.
func _raton_remoto(pos: Vector2, tipo: int, boton: int) -> void:
	var panel := _panel_del_invitado()
	if panel == null:
		return
	if tipo == 0:
		var mov := InputEventMouseMotion.new()
		mov.position = pos
		panel._gui_input(mov)
		return
	if boton != MOUSE_BUTTON_LEFT and boton != MOUSE_BUTTON_RIGHT:
		return
	var clic := InputEventMouseButton.new()
	clic.position = pos
	clic.button_index = boton as MouseButton
	clic.pressed = tipo == 1
	panel._gui_input(clic)


# ------------------------------------------------------------ invitado: lo que pide
func pedir(datos: Array) -> void:
	if jugando_invitado():
		red.enviar(datos)


## Las teclas y el ratón del invitado sobre un panel del anfitrión que le toca manejar.
func _input(ev: InputEvent) -> void:
	if not jugando_invitado() or p._menu.visible:
		return
	if not (p._panel.visible or p._panel_apuestas.visible) or p._dueno_panel != p.jugador2:
		return
	if ev is InputEventMouseMotion:
		_raton = ev.position
		return
	if ev is InputEventMouseButton:
		red.enviar([I_RATON, ev.position, ev.pressed, int(ev.button_index)])
		get_viewport().set_input_as_handled()
		return
	var tecla := Mando.tecla_panel(ev, true)
	if tecla == KEY_NONE and ev is InputEventKey and ev.pressed and not ev.echo and ev.physical_keycode == KEY_SPACE:
		tecla = KEY_ENTER
	if tecla != KEY_NONE:
		red.enviar([I_TECLA, int(tecla)])
		get_viewport().set_input_as_handled()


## El jugador de este ordenador acaba de rodar (solo cuenta en el invitado).
func al_rodar_yo(direccion: Vector2) -> void:
	if jugando_invitado() and not p.jugador2.remoto:
		red.enviar([I_RODAR, direccion])


func avisar_pausa(pausado: bool) -> void:
	if en_partida and red.en_pareja():
		if red.anfitrion:
			return  # la del anfitrión ya viaja con el estado
		red.enviar([I_PAUSA, pausado])


# ------------------------------------------------------------ invitado: lo que cuenta el anfitrión
func _del_anfitrion(tipo: int, m: Array) -> void:
	match tipo:
		A_VESTIBULO:
			if m.size() >= 2 and m[1] is Dictionary:
				fase_anfitrion = String(m[1].get("fase", "sala"))
				sala_cambiada.emit()
		A_EMPEZAR:
			if m.size() >= 2 and m[1] is Dictionary:
				_empezar_invitado(m[1])
		A_SALA:
			if en_partida and m.size() >= 8 and m[1] is int and m[2] is Vector2i and m[3] is Dictionary \
					and m[4] is Vector2i and m[5] is Vector2 and m[6] is Vector2 and m[7] is int and _sala_valida(m[3], m[2]):
				n_sala = m[1]
				espejo.vaciar()
				_arrastre = Vector2.ZERO
				_rodaba_j1 = false
				Juego.piso = clampi(m[7], 1, 9999)
				p.entrar_sala_espejo(m[3], m[2], m[5], m[6])
		A_TIC:
			if en_partida and m.size() >= 7 and m[1] is int and m[1] == n_sala:
				_aplicar_tic(m)
		A_FIN:
			if en_partida and m.size() >= 2 and m[1] is bool:
				p.acabar_espejo(m[1])
		A_PORTADA:
			if en_partida:
				en_partida = false
				Red.espejo = false
				espejo.vaciar()
				fase_anfitrion = "sala"
				p.volver_al_vestibulo()


## Un mapa con el que se puede construir la sala: cada casilla, con lo que Sala le pide.
static func _sala_valida(salas: Dictionary, pos: Vector2i) -> bool:
	if not salas.has(pos):
		return false
	for c in salas:
		var s = salas[c]
		if not (c is Vector2i) or not (s is Dictionary) or not (s.get("pos") is Vector2i) or not (s.get("tipo") is int) \
				or not (s.get("semilla") is int):
			return false
	return true


func _empezar_invitado(datos: Dictionary) -> void:
	var completo := true
	for campo in ["azar_seed", "azar_state", "cartas", "stats", "personaje", "personaje2"]:
		completo = completo and datos.has(campo)
	if not completo or not PersonajesDB.PERSONAJES.has(datos.personaje) or not PersonajesDB.PERSONAJES.has(datos.personaje2):
		return
	var seguia := en_partida  # un "empezar" con la partida en marcha: vuelta tras un corte
	en_partida = true
	Red.espejo = true
	pausa_remota = false
	_rodaba_j1 = false
	Red.cola.clear()
	espejo.vaciar()
	Juego.restaurar(_solo_conocido(datos))
	Juego.tiempo_partida = float(datos.get("tiempo_partida", 0.0))
	p.empezar_espejo(seguia)


## De lo que llega para Juego, solo los campos que existen y con el tipo que tienen aquí.
func _solo_conocido(datos: Dictionary) -> Dictionary:
	var d := {"azar_seed": int(datos.azar_seed), "azar_state": int(datos.azar_state)}
	for campo in Juego.CAMPOS_PARTIDA:
		if datos.has(campo) and typeof(datos[campo]) == typeof(Juego.get(campo)):
			d[campo] = datos[campo]
	return d


func _aplicar_tic(m: Array) -> void:
	if not (m[2] is Array) or not (m[3] is Array) or not (m[4] is Array) or not (m[5] is Dictionary):
		return
	tics_recibidos += 1
	_aplicar_jugadores(m[2])
	espejo.aplicar(m[3], [p._horda, p._ataques, p._recogibles, p._efectos])
	_aplicar_estado(m[5])
	for ev in m[4]:
		_aplicar_evento(ev)
	if _numero(m[6]) and not p._hud.jefe_espejo.is_empty():
		p._hud.jefe_espejo[1] = float(m[6])


func _aplicar_jugadores(lista: Array) -> void:
	for i in mini(lista.size(), p.jugadores.size()):
		var d = lista[i]
		if not (d is Array) or d.size() < 8 or not (d[0] is Vector2) or not (d[1] is Vector2) or not (d[3] is Vector2):
			continue
		var j = p.jugadores[i]
		var caido := bool(d[4])
		if caido != j.caido:
			if caido:
				j.caer()
			else:
				j.levantar()
				p.retenir()
		j.reanimar = float(d[5])
		var respiro := float(d[6])
		if j.remoto:  # el muñeco del anfitrión
			j.remoto_pos = d[0]
			j.remoto_dir = d[1].limit_length(1.0)
			var rueda := bool(d[2])
			if rueda and not _rodaba_j1:
				j.rodar_remoto(d[3], false)
			_rodaba_j1 = rueda
			if respiro > j.respiro() + 0.1:
				j.proteger(respiro)
		else:  # yo: me muevo solo, pero los golpes y lo que tira de mí los pone el anfitrión
			if respiro > j.respiro() + 0.15:
				j.proteger(respiro)
			_arrastre = d[7] if d[7] is Vector2 and _finito(d[7]) else Vector2.ZERO


func _aplicar_estado(e: Dictionary) -> void:
	var cartas := false
	var juego := false
	for k in e:
		if not (k is String):
			continue
		var v = e[k]
		if k.begins_with("j:"):
			var campo: String = k.substr(2)
			if CAMPOS_JUEGO.has(campo) and typeof(v) == typeof(Juego.get(campo)):
				Juego.set(campo, v)
				juego = true
				cartas = cartas or campo == "cartas"
				if campo == "transformaciones":
					p.retenir()
		elif k.begins_with("pe:"):
			_poner_en_panel(p._panel, k.substr(3), v)
		elif k.begins_with("pa:"):
			_poner_en_panel(p._panel_apuestas, k.substr(3), v)
	if e.has("fiebre") and e.fiebre is float:
		Juego.fiebre = e.fiebre
		juego = true
	if e.has("desatado_t") and e.desatado_t is float:
		Juego.set("_desatado_t", e.desatado_t)
	if e.has("pausa"):
		pausa_remota = bool(e.pausa)
	if e.has("puertas"):
		p._sala.poner_puertas(bool(e.puertas))
	if e.has("mesas") and e.mesas is Array:
		p._sala.aplicar_mesas(e.mesas)
	if e.has("limpia"):
		p.actual["limpia"] = bool(e.limpia)
	if e.has("aviso") and e.aviso is String:
		p._aviso.text = e.aviso
	if e.has("crono") and e.crono is String:
		p._crono.text = e.crono
		p._crono.visible = e.crono != ""
	if e.has("crono_a") and e.crono_a is float:
		p._crono.modulate.a = e.crono_a
	if e.has("info") and e.info is Dictionary:
		p._barra.info_externa = e.info
	if e.has("pelea"):
		p._barra.en_combate = bool(e.pelea)
		if not p._barra.en_combate:
			p._barra.parar_animacion()
	if e.has("dueno") and e.dueno is int:
		p._dueno_panel = p.jugadores[e.dueno] if e.dueno >= 0 and e.dueno < p.jugadores.size() else null
	if e.has("selector") and e.selector is Array:
		if e.selector.size() >= 2 and e.selector[0] is Array and e.selector[1] is String:
			p._selector.abrir(e.selector[0].filter(func(id): return CartasDB.CARTAS.has(id)), e.selector[1])
		else:
			p._selector.cerrar()
	if e.has("sustituir") and e.sustituir is String:
		p._carta_pendiente = e.sustituir
		p._barra.modo_sustituir = e.sustituir != ""
	if e.has("jefe") and e.jefe is String:
		p._hud.jefe_espejo = [] if e.jefe == "" else [e.jefe, 1.0]
	if e.has("a_mano"):
		p.a_mano_espejo = bool(e.a_mano)
	for par in [["pe", p._panel], ["pa", p._panel_apuestas]]:
		if e.has(par[0]):
			_ver_panel(par[1], bool(e[par[0]]))
	if p._panel.visible:
		p._panel.queue_redraw()
	if p._panel_apuestas.visible:
		p._panel_apuestas.queue_redraw()
	if cartas:
		Juego.cartas_cambiadas.emit()
	if juego:
		Juego.estado_cambiado.emit()


## Los paneles del anfitrión, aquí, son solo un dibujo: ni se mueven solos ni leen nada.
func _ver_panel(panel: Control, a_la_vista: bool) -> void:
	panel.visible = a_la_vista
	panel.set_process(false)
	panel.set_process_input(false)
	panel.set_process_unhandled_input(false)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE


func _poner_en_panel(panel: Control, nombre: String, v: Variant) -> void:
	if not _variables_de(panel).has(nombre):
		return
	var aqui = panel.get(nombre)
	if typeof(aqui) != typeof(v) and typeof(aqui) != TYPE_NIL:
		return
	if nombre == "_botones" and v is Array:
		# Aquí los botones no hacen nada, pero el panel espera que tengan con qué.
		for b in v:
			if b is Dictionary:
				b["accion"] = Callable()
	panel.set(nombre, v)


func _aplicar_evento(ev: Variant) -> void:
	if not (ev is Array) or ev.is_empty() or not (ev[0] is int):
		return
	match ev[0]:
		Red.FX:
			if ev.size() >= 3 and (ev[1] is StringName or ev[1] is String) and ev[2] is Array \
					and Jugo.REENVIABLES.has(StringName(ev[1])) and ev[2].size() <= 4:
				p._jugo.callv(StringName(ev[1]), ev[2])
		Red.SONIDO:
			if ev.size() >= 4 and ev[1] is String and _numero(ev[2]) and _numero(ev[3]):
				Sonido.tocar(ev[1], clampf(float(ev[2]), 0.2, 4.0), clampf(float(ev[3]), -40.0, 6.0))
		Red.MUSICA:
			if ev.size() >= 2 and ev[1] is String:
				Sonido.musica(ev[1])
		CARTEL:
			if ev.size() >= 3 and ev[1] is String and ev[2] is String:
				p.mostrar_cartel(ev[1], ev[2])
		VIBRAR:
			if ev.size() >= 2 and ev[1] is Array and ev[1].size() >= 3:
				Mando.vibrar([clampf(float(ev[1][0]), 0.0, 1.0), clampf(float(ev[1][1]), 0.0, 1.0), clampf(float(ev[1][2]), 0.0, 1.0)])
		CICLO:
			if ev.size() >= 2 and ev[1] is Dictionary and ev[1].has("pasos"):
				p._motor.ciclo_empezado.emit(ev[1])
		PASO:
			if ev.size() >= 2 and ev[1] is Dictionary:
				p._motor.paso_ejecutado.emit(ev[1])
		CICLO_FIN:
			p._motor.ciclo_terminado.emit()


# ------------------------------------------------------------ cortes y despedidas
func _al_irse_companero() -> void:
	var jugaba := en_partida
	_soltar()
	if red.en_sala():  # soy el anfitrión: la sala sigue siendo mía
		if jugaba:
			red.salir()  # con la partida en marcha no entra nadie más: se sigue en solitario
			p.seguir_en_solitario()
	else:
		cerrada.emit("anfitrion_fuera", jugaba)
	sala_cambiada.emit()


## El otro ha vuelto tras un corte: el anfitrión se lo cuenta todo desde cero.
func _al_volver_companero() -> void:
	if not jugando_anfitrion():
		if anfitrion():
			red.enviar([A_VESTIBULO, {"fase": fase_anfitrion}])
		elif red.invitado() and not en_partida:
			red.enviar([I_PERSONAJE, personaje_invitado])
		return
	_empezar_a_contar()
	n_sala += 1
	p.jugador2.remoto_pos = p.jugador2.position
	red.enviar([A_SALA, n_sala, p.actual.pos, p.salas, Vector2i.ZERO, p.jugador.position, p.jugador2.position, Juego.piso])


func _soltar() -> void:
	if en_partida and not red.anfitrion:
		espejo.vaciar()
	en_partida = false
	pausa_remota = false
	fase_anfitrion = "sala"
	Red.reenviando = false
	Red.espejo = false
	Red.cola.clear()
	if _pausa_mia:
		_pausa_mia = false
		if get_tree().paused and not p.algo_pausa():
			get_tree().paused = false
	p.poner_letrero("")
