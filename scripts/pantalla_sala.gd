class_name PantallaSala
extends Control
## El vestíbulo del cooperativo online: crear una sala, unirse a una con su código y esperar
## al otro. El anfitrión elige después personaje, mesa y modo en la selección de siempre; el
## invitado elige aquí su personaje. La crea main.gd por código, como las demás pantallas.

signal atras  # de vuelta al menú principal (ya fuera de la sala)
signal empezar  # el anfitrión, con el invitado dentro: a elegir personaje y mesa

enum Vista { MENU, CODIGO, CONECTANDO, SALA }

const COLOR_CREMA := Color8(247, 236, 210)
const COLOR_ORO := Color8(247, 198, 74)
const COLOR_GRIS := Color8(168, 154, 142)
const COLOR_ROJO := Color8(214, 61, 79)
const COLOR_FONDO := Color8(20, 16, 30)
const COLOR_BOTON := Color8(42, 31, 61)
const COLOR_J2 := Color8(111, 195, 232)
const ANCHO_BOTON := 260.0
const ALTO_BOTON := 18.0
const SEPARACION := 22.0
const Y_BOTONES := 262.0
const CAJA_J1 := Rect2(150, 96, 150, 120)
const CAJA_J2 := Rect2(340, 96, 150, 120)
const LETRAS_CODIGO := "ABCDEFGHJKMNPQRSTUVWXYZ23456789"  # las mismas que usa el relé
const LARGO_CODIGO := 4

var red: Red
var pareja: Pareja
var online: Online  # por el nombre público, si el jugador ya tiene uno

var _vista := Vista.MENU
var _items: Array = []
var _indice := 0
var _mensaje := ""
var _mensaje_malo := false
var _campo: LineEdit
var _t := 0.0
var _libres: Array = []  # los personajes que puede llevar el invitado


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	size = Vector2(640, 360)
	visible = false
	_campo = LineEdit.new()
	_campo.position = Vector2(260, 150)
	_campo.size = Vector2(120, 24)
	_campo.max_length = LARGO_CODIGO
	_campo.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_campo.visible = false
	var caja := StyleBoxFlat.new()
	caja.bg_color = COLOR_BOTON
	caja.border_color = COLOR_ORO
	caja.set_border_width_all(1)
	_campo.add_theme_stylebox_override("normal", caja)
	_campo.add_theme_stylebox_override("focus", caja)
	_campo.add_theme_color_override("font_color", COLOR_CREMA)
	_campo.add_theme_font_override("font", Juego.fuente_grande)
	_campo.add_theme_font_size_override("font_size", 16)
	_campo.text_changed.connect(_al_escribir)
	_campo.text_submitted.connect(func(_texto: String) -> void: _entrar())
	add_child(_campo)
	red.error_sala.connect(_al_fallar)
	red.estado_cambiado.connect(_al_cambiar_red)
	pareja.sala_cambiada.connect(queue_redraw)


# ------------------------------------------------------------ abrir y cerrar
func abrir() -> void:
	if red.en_sala():
		abrir_en_sala()
		return
	_mensaje = ""
	_ir_a(Vista.MENU)
	visible = true


## Con la sala ya abierta: al volver de la selección de personaje o de una partida.
func abrir_en_sala() -> void:
	_preparar_personajes()
	pareja.poner_fase("sala")
	_ir_a(Vista.SALA)
	visible = true


## Al menú, con una explicación de por qué (el anfitrión se ha ido, se ha cortado...).
func abrir_con_aviso(motivo: String) -> void:
	_ir_a(Vista.MENU)
	_avisar(texto_error(motivo), true)
	visible = true


func cerrar() -> void:
	visible = false
	_campo.visible = false
	_campo.release_focus()


func _ir_a(vista: Vista) -> void:
	_vista = vista
	_indice = 0
	_campo.visible = vista == Vista.CODIGO
	match vista:
		Vista.MENU:
			_items = ["crear", "unirse", "volver"]
		Vista.CODIGO:
			_items = ["entrar", "volver"]
			_campo.text = ""
			_campo.grab_focus()
		Vista.CONECTANDO:
			_items = ["cancelar"]
		Vista.SALA:
			_items = ["empezar", "salir"] if red.anfitrion else ["personaje", "salir"]
	if vista != Vista.CODIGO:
		_campo.release_focus()
	queue_redraw()


func _avisar(texto: String, malo := false) -> void:
	_mensaje = texto
	_mensaje_malo = malo
	queue_redraw()


static func texto_error(motivo: String) -> String:
	match motivo:
		"no_existe": return Idioma.t("NO HAY NINGUNA SALA CON ESE CÓDIGO")
		"llena": return Idioma.t("ESA SALA YA ESTÁ COMPLETA")
		"version": return Idioma.t("TU COMPAÑERO TIENE OTRA VERSIÓN DEL JUEGO")
		"lleno": return Idioma.t("EL SERVIDOR ESTÁ LLENO: PRUEBA DENTRO DE UN RATO")
		"anfitrion_fuera": return Idioma.t("EL ANFITRIÓN HA CERRADO LA SALA")
		"": return ""
	return Idioma.t("SIN CONEXIÓN CON EL SERVIDOR")


func _nombre_mio() -> String:
	return online.nombre if online != null else ""


# ------------------------------------------------------------ lo que hace cada botón
func _activar(id: String, sentido := 1) -> void:
	match id:
		"crear":
			Sonido.tocar("clic")
			_avisar("")
			_ir_a(Vista.CONECTANDO)
			red.crear_sala(_nombre_mio())
		"unirse":
			Sonido.tocar("clic")
			_avisar("")
			_ir_a(Vista.CODIGO)
		"entrar":
			_entrar()
		"empezar":
			if not red.hay_companero or pareja.cortado():
				Sonido.tocar("perder")
				return
			Sonido.tocar("clic")
			cerrar()
			pareja.poner_fase("eligiendo")
			empezar.emit()
		"personaje":
			_cambiar_personaje(sentido)
		"cancelar", "salir":
			Sonido.tocar("clic")
			pareja.salir()
			_ir_a(Vista.MENU)
		"volver":
			_volver()


func _volver() -> void:
	Sonido.tocar("clic")
	match _vista:
		Vista.CODIGO:
			_ir_a(Vista.MENU)
		Vista.CONECTANDO, Vista.SALA:
			pareja.salir()
			_ir_a(Vista.MENU)
		_:
			cerrar()
			atras.emit()


func _entrar() -> void:
	var codigo := _campo.text.strip_edges().to_upper()
	if codigo.length() != LARGO_CODIGO:
		Sonido.tocar("perder")
		_avisar(Idioma.t("EL CÓDIGO TIENE CUATRO LETRAS O NÚMEROS"), true)
		return
	Sonido.tocar("clic")
	_avisar("")
	_preparar_personajes()
	_ir_a(Vista.CONECTANDO)
	red.unirse(codigo, _nombre_mio())


## Solo mayúsculas y lo que puede llevar un código (la O es un 0 mal leído, etc.).
func _al_escribir(texto: String) -> void:
	var limpio := ""
	for letra in texto.to_upper():
		if LETRAS_CODIGO.contains(letra):
			limpio += letra
	if limpio != texto:
		var cursor := _campo.caret_column
		_campo.text = limpio
		_campo.caret_column = mini(cursor, limpio.length())


func _preparar_personajes() -> void:
	_libres = PersonajesDB.PERSONAJES.keys().filter(func(id): return Progreso.personaje_libre(id))
	if _libres.is_empty():
		_libres = [PersonajesDB.PERSONAJES.keys()[0]]
	if not red.anfitrion and not _libres.has(pareja.personaje_invitado):
		pareja.elegir_personaje(Juego.personaje if _libres.has(Juego.personaje) else _libres[0])


func _cambiar_personaje(sentido: int) -> void:
	if _libres.size() < 2:
		Sonido.tocar("perder")
		return
	var i := _libres.find(pareja.personaje_invitado)
	pareja.elegir_personaje(_libres[wrapi(i + sentido, 0, _libres.size())])
	Sonido.tocar("mover")


# ------------------------------------------------------------ lo que pasa en la red
func _al_fallar(motivo: String) -> void:
	if not visible:
		return
	Sonido.tocar("perder")
	_ir_a(Vista.MENU)
	_avisar(texto_error(motivo), true)


func _al_cambiar_red() -> void:
	if not visible:
		return
	if red.en_sala() and _vista != Vista.SALA:
		Sonido.tocar("mult", 1.2)
		_ir_a(Vista.SALA)
	elif not red.en_sala() and _vista == Vista.SALA:
		_ir_a(Vista.MENU)
	queue_redraw()


# ------------------------------------------------------------ entrada
func _process(delta: float) -> void:
	if visible:
		_t += delta
		queue_redraw()


func _caja(i: int) -> Rect2:
	return Rect2(320.0 - ANCHO_BOTON * 0.5, Y_BOTONES + i * SEPARACION - (SEPARACION if _items.size() > 2 else 0.0), ANCHO_BOTON, ALTO_BOTON)


func _boton_en(pos: Vector2) -> int:
	for i in _items.size():
		if _caja(i).has_point(pos):
			return i
	return -1


func _gui_input(evento: InputEvent) -> void:
	if evento is InputEventMouseMotion:
		var i := _boton_en(evento.position)
		if i != -1 and i != _indice:
			_indice = i
			Sonido.tocar("mover")
	elif evento is InputEventMouseButton and evento.pressed and evento.button_index == MOUSE_BUTTON_LEFT:
		var i := _boton_en(evento.position)
		if i != -1:
			_indice = i
			# El botón del personaje: la mitad izquierda va hacia atrás.
			_activar(_items[i], -1 if _items[i] == "personaje" and evento.position.x < 320.0 else 1)


func _input(evento: InputEvent) -> void:
	# Con el campo del código abierto, Esc vuelve (antes de que se lo quede el campo).
	if visible and _vista == Vista.CODIGO and evento is InputEventKey and evento.pressed and evento.keycode == KEY_ESCAPE:
		_volver()
		get_viewport().set_input_as_handled()
	elif visible and _vista == Vista.CODIGO and Mando.es_mando(evento):
		if _mando_codigo(Mando.tecla_mando(evento)):
			get_viewport().set_input_as_handled()


## Con el mando no hay teclado: arriba y abajo cambian la letra, derecha pasa a la siguiente,
## izquierda borra, A entra y B vuelve.
func _mando_codigo(tecla: Key) -> bool:
	var texto := _campo.text
	match tecla:
		KEY_UP, KEY_DOWN:
			if texto == "":
				texto = LETRAS_CODIGO[0]
			else:
				var i := LETRAS_CODIGO.find(texto[-1])
				texto = texto.left(-1) + LETRAS_CODIGO[wrapi(i + (1 if tecla == KEY_DOWN else -1), 0, LETRAS_CODIGO.length())]
			Sonido.tocar("mover")
		KEY_RIGHT:
			if texto.length() < LARGO_CODIGO:
				texto += texto[-1] if texto != "" else LETRAS_CODIGO[0]
				Sonido.tocar("mover")
		KEY_LEFT:
			texto = texto.left(-1)
			Sonido.tocar("mover")
		KEY_ENTER:
			_entrar()
			return true
		KEY_ESCAPE:
			_volver()
			return true
		_:
			return false
	_campo.text = texto
	_campo.caret_column = texto.length()
	return true


func _unhandled_input(evento: InputEvent) -> void:
	if not visible or _vista == Vista.CODIGO:
		return
	match Mando.tecla(evento):
		KEY_UP, KEY_W:
			_indice = wrapi(_indice - 1, 0, _items.size())
			Sonido.tocar("mover")
		KEY_DOWN, KEY_S:
			_indice = wrapi(_indice + 1, 0, _items.size())
			Sonido.tocar("mover")
		KEY_LEFT, KEY_A:
			if _items[_indice] == "personaje":
				_activar("personaje", -1)
		KEY_RIGHT, KEY_D:
			if _items[_indice] == "personaje":
				_activar("personaje", 1)
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			_activar(_items[_indice])
		KEY_ESCAPE:
			_volver()
		_:
			return
	get_viewport().set_input_as_handled()


# ------------------------------------------------------------ dibujo
func _centrado(texto: String, y: float, color: Color, grande := false, x := 0.0, ancho := 640.0) -> void:
	draw_string(Juego.fuente_grande if grande else Juego.fuente, Vector2(x, y), texto, HORIZONTAL_ALIGNMENT_CENTER,
			ancho, 16 if grande else 8, color)


func _texto_boton(id: String) -> String:
	match id:
		"crear": return Idioma.t("CREAR UNA SALA")
		"unirse": return Idioma.t("UNIRSE CON UN CÓDIGO")
		"entrar": return Idioma.t("ENTRAR")
		"empezar": return Idioma.t("ELEGIR PERSONAJE Y EMPEZAR")
		"personaje": return "<  %s  >" % PersonajesDB.nombre(pareja.personaje_invitado).to_upper()
		"cancelar": return Idioma.t("CANCELAR")
		"salir": return Idioma.t("SALIR DE LA SALA")
	return Idioma.t("VOLVER")


func _draw() -> void:
	draw_rect(Rect2(0, 0, 640, 360), COLOR_FONDO)
	_centrado(Idioma.t("COOPERATIVO ONLINE"), 40, COLOR_ORO, true)
	match _vista:
		Vista.MENU:
			_centrado(Idioma.t("DOS JUGADORES, CADA UNO EN SU CASA, EN LA MISMA PARTIDA."), 96, COLOR_CREMA)
			_centrado(Idioma.t("UNO CREA LA SALA Y LE PASA EL CÓDIGO AL OTRO."), 110, COLOR_GRIS)
			_centrado(Idioma.t("EL QUE LA CREA ELIGE LA MESA Y EL MODO, Y LLEVA LA PARTIDA."), 122, COLOR_GRIS)
		Vista.CODIGO:
			_centrado(Idioma.t("ESCRIBE EL CÓDIGO DE LA SALA"), 130, COLOR_CREMA)
			if Mando.activo:
				_centrado(Idioma.t("ARRIBA Y ABAJO: LETRA. DERECHA: SIGUIENTE. IZQUIERDA: BORRAR."), 196, COLOR_GRIS)
		Vista.CONECTANDO:
			_centrado(Idioma.t("CONECTANDO") + ".".repeat(1 + int(_t * 3.0) % 3), 150, COLOR_CREMA)
		Vista.SALA:
			_dibujar_sala()
	if _mensaje != "":
		_centrado(_mensaje, 232 if _vista != Vista.SALA else 236, COLOR_ROJO if _mensaje_malo else COLOR_CREMA)
	for i in _items.size():
		_dibujar_boton(i)


func _dibujar_boton(i: int) -> void:
	var caja := _caja(i)
	var elegido := i == _indice
	var apagado: bool = _items[i] == "empezar" and (not red.hay_companero or pareja.cortado())
	draw_rect(caja, Color8(122, 90, 160) if elegido and not apagado else COLOR_BOTON)
	draw_rect(caja, COLOR_ORO if elegido else Color8(74, 52, 102), false, 1.0)
	draw_string(Juego.fuente, Vector2(caja.position.x, caja.position.y + 12), _texto_boton(_items[i]),
			HORIZONTAL_ALIGNMENT_CENTER, caja.size.x, 8, COLOR_GRIS if apagado else COLOR_CREMA)


func _dibujar_sala() -> void:
	_centrado(Idioma.t("CÓDIGO DE LA SALA"), 62, COLOR_GRIS)
	# El código, bien grande: se dicta de viva voz.
	var ancho := Juego.fuente_grande.get_string_size(red.codigo, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x * 2.0
	draw_set_transform(Vector2(320.0 - ancho * 0.5, 90), 0.0, Vector2(2, 2))
	draw_string(Juego.fuente_grande, Vector2.ZERO, red.codigo, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, COLOR_ORO)
	draw_set_transform(Vector2.ZERO)
	var yo_anfitrion := red.anfitrion
	var nombre_otro := red.companero if red.companero != "" else Idioma.t("J2" if yo_anfitrion else "J1")
	var nombre_mio := _nombre_mio() if _nombre_mio() != "" else Idioma.t("J1" if yo_anfitrion else "J2")
	_dibujar_jugador(CAJA_J1, nombre_mio if yo_anfitrion else nombre_otro, true, "", COLOR_ORO, yo_anfitrion)
	_dibujar_jugador(CAJA_J2, nombre_otro if yo_anfitrion else nombre_mio, red.hay_companero,
			pareja.personaje_invitado, COLOR_J2, not yo_anfitrion)
	var estado := ""
	if pareja.cortado():
		estado = Idioma.t("SE HA CORTADO LA CONEXIÓN") + " " + Idioma.t("VOLVIENDO A CONECTAR...")
	elif not red.hay_companero:
		estado = Idioma.t("PÁSALE EL CÓDIGO A TU COMPAÑERO")
	elif yo_anfitrion:
		estado = Idioma.t("TÚ ELIGES LA MESA Y EL MODO")
	elif pareja.fase_anfitrion == "eligiendo":
		estado = Idioma.t("EL ANFITRIÓN ESTÁ ELIGIENDO PERSONAJE Y MESA") + ".".repeat(1 + int(_t * 3.0) % 3)
	else:
		estado = Idioma.t("ELIGE TU PERSONAJE: EL ANFITRIÓN EMPIEZA LA PARTIDA")
	if _mensaje == "":
		_centrado(estado, 236, COLOR_CREMA)
	if red.retraso_ms >= 0:
		draw_string(Juego.fuente, Vector2(540, 352), Idioma.t("RETRASO: %d MS") % red.retraso_ms, HORIZONTAL_ALIGNMENT_RIGHT, 92, 8,
				COLOR_GRIS if red.retraso_ms < 150 else COLOR_ROJO)


func _dibujar_jugador(caja: Rect2, nombre: String, presente: bool, personaje: String, color: Color, soy_yo: bool) -> void:
	draw_rect(caja, COLOR_BOTON)
	draw_rect(caja, color if presente else Color8(74, 52, 102), false, 1.0)
	var x := caja.position.x
	if not presente:
		_centrado(Idioma.t("ESPERANDO") + ".".repeat(1 + int(_t * 3.0) % 3), caja.position.y + 64, COLOR_GRIS, false, x, caja.size.x)
		return
	_centrado(nombre, caja.position.y + 16, color, false, x, caja.size.x)
	if soy_yo:
		_centrado(Idioma.t("(TÚ)"), caja.position.y + 28, COLOR_GRIS, false, x, caja.size.x)
	if personaje == "":
		_centrado(Idioma.t("ANFITRIÓN"), caja.position.y + 72, COLOR_CREMA, false, x, caja.size.x)
		_centrado(Idioma.t("ELIGE AL EMPEZAR"), caja.position.y + 86, COLOR_GRIS, false, x, caja.size.x)
		return
	var columna := 2 + int(_t * 8.0) % 4
	draw_texture_rect_region(PersonajesDB.textura(personaje), Rect2(x + caja.size.x * 0.5 - 24, caja.position.y + 36, 48, 48),
			Rect2(columna * 16, 0, 16, 16))
	_centrado(PersonajesDB.nombre(personaje).to_upper(), caja.position.y + 102, COLOR_CREMA, false, x, caja.size.x)
