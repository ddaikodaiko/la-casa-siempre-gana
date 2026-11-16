class_name Espejo
extends RefCounted
## El "espejo" del cooperativo online: copia lo que se ve del mundo del anfitrión (enemigos,
## balas, monedas, avisos...) al invitado, sin que el invitado simule nada.
##
## El anfitrión llama a capturar() varias veces por segundo con los nodos raíz (Horda,
## Ataques, Recogibles, Efectos). Sale un mensaje con solo lo que ha cambiado: nodos nuevos o
## con otra pinta, los que se han movido (posición y fotograma, muy apretados) y los que ya no
## están. El invitado llama a aplicar() con ese mensaje y sus propias raíces: crea, mueve y
## borra nodos de pega (sin lógica) que se dibujan igual.
##
## No hay clases de enemigo ni de bala aquí: todo son Sprite2D, Label, Line2D y los avisos
## de zona. Si algo nuevo del juego se dibuja con esos nodos, sale en el espejo sin tocar esto.

enum Tipo { GRUPO, SPRITE, TEXTO, LINEA, ZONA }

const ESCALA_POS := 16.0  # las posiciones viajan en dieciseisavos de píxel
## Lo más hondo que se copia, contando desde la raíz: lo más hondo del juego son los precios
## de la tienda (Recogibles > artículo > grupo del precio > número y moneda).
const PROFUNDIDAD := 3
# Topes del invitado: lo que llega de fuera nunca crece sin fin ni pide imágenes enormes.
const TOPE_NODOS := 3000
const TOPE_TEXTURAS := 512  # el anfitrión las numera desde 1 en cada reiniciar()
const TOPE_PNG := 262144  # bytes
const TOPE_LADO_PNG := 1024  # píxeles
const TOPE_TEXTO := 256  # letras de un Label
const TOPE_PUNTOS := 256  # de una línea
const MATERIALES := [0, 1, 10 + Enemigo.Rango.RARO, 10 + Enemigo.Rango.ELITE]  # ver _material_de()
# Casillas de lo que se compara de cada nodo (las mismas para todos, luego las de su tipo).
const C_VISIBLE := 0
const C_ROT := 1
const C_ESCALA := 2
const C_COLOR := 3
const C_COLOR_PROPIO := 4
const C_Z := 5
const C_MATERIAL := 6
const C_TIPO := 7  # desde aquí, según el tipo

# ------------------------------------------------------------ anfitrión
var _siguiente := 1
var _ultimo := {}  # rid -> [x, y, fotograma, casillas...]
var _texturas := {}  # Texture2D -> número
var _texturas_nuevas: Array = []  # [número, ruta, png]
var _material_suma: Material


## Olvida lo mandado: el siguiente capturar() lo manda todo otra vez (al entrar el invitado).
func reiniciar() -> void:
	_ultimo.clear()
	_texturas.clear()


## [texturas nuevas, nodos nuevos o cambiados, movidos (bytes), los que ya no están]
func capturar(raices: Array) -> Array:
	var cambiados: Array = []
	var movidos := StreamPeerBuffer.new()
	var vistos := {}
	_texturas_nuevas = []
	for i in raices.size():
		for hijo in raices[i].get_children():
			_capturar_nodo(hijo, -(i + 1), 1, cambiados, movidos, vistos)
	var fuera := PackedInt32Array()
	for rid in _ultimo.keys():
		if not vistos.has(rid):
			_ultimo.erase(rid)
			fuera.append(rid)
	return [_texturas_nuevas, cambiados, movidos.data_array, fuera]


func _capturar_nodo(n: Node, padre: int, hondo: int, cambiados: Array, movidos: StreamPeerBuffer, vistos: Dictionary) -> void:
	if n.is_queued_for_deletion() or not (n is CanvasItem):
		return
	var tipo := _tipo_de(n)
	if tipo < 0:
		return
	var rid: int = n.get_meta(&"rid", 0)
	if rid == 0:
		rid = _siguiente
		_siguiente += 1
		n.set_meta(&"rid", rid)
	vistos[rid] = true
	var ahora := _casillas(n, tipo)
	var p: Vector2 = n.position
	var x := roundi(p.x * ESCALA_POS)
	var y := roundi(p.y * ESCALA_POS)
	var cuadro: int = n.frame if tipo == Tipo.SPRITE else 0
	var antes = _ultimo.get(rid)
	if antes == null:
		cambiados.append([rid, padre, tipo, x, y, cuadro, -1, ahora])
		_ultimo[rid] = [x, y, cuadro, ahora]
	else:
		var viejas: Array = antes[3]
		var mascara := 0
		var valores: Array = []
		for i in ahora.size():
			if ahora[i] != viejas[i]:
				mascara |= 1 << i
				valores.append(ahora[i])
		if mascara != 0:
			cambiados.append([rid, padre, tipo, x, y, cuadro, mascara, valores])
			antes[3] = ahora
		elif antes[0] != x or antes[1] != y or antes[2] != cuadro:
			movidos.put_u32(rid)
			movidos.put_16(clampi(x, -32768, 32767))
			movidos.put_16(clampi(y, -32768, 32767))
			movidos.put_u8(cuadro & 0xff)
		antes[0] = x
		antes[1] = y
		antes[2] = cuadro
	if hondo < PROFUNDIDAD:  # más abajo el invitado no lo admite
		for hijo in n.get_children():
			_capturar_nodo(hijo, rid, hondo + 1, cambiados, movidos, vistos)


func _tipo_de(n: Node) -> int:
	if n is ZonaPeligro:
		return Tipo.ZONA
	if n is Sprite2D:
		return Tipo.SPRITE
	if n is Label:
		return Tipo.TEXTO
	if n is Line2D:
		return Tipo.LINEA
	if n is Node2D and n.get_script() == null:
		return Tipo.GRUPO
	return -1


func _casillas(n: CanvasItem, tipo: int) -> Array:
	var c: Array = [n.visible, n.rotation, n.scale, n.modulate, n.self_modulate, n.z_index, _material_de(n)]
	match tipo:
		Tipo.SPRITE:
			var s: Sprite2D = n
			var estela := 0
			if s is Proyectil and not s._enemigo and not s._vuelve and s.giro == 0.0:
				estela = 2 if s.fuerte else 1
			c.append_array([_textura_de(s.texture), s.hframes, s.vframes, s.flip_h, s.flip_v, s.offset, s.centered, estela])
		Tipo.TEXTO:
			var l: Label = n
			c.append_array([l.text, l.size, l.horizontal_alignment, l.get_theme_color(&"font_color"),
				l.get_theme_font_size(&"font_size"), l.get_theme_constant(&"outline_size"),
				l.get_theme_color(&"font_outline_color"), l.get_theme_font(&"font") == Juego.fuente_grande])
		Tipo.LINEA:
			var li: Line2D = n
			c.append_array([li.points, li.width, li.default_color, li.joint_mode, li.begin_cap_mode, li.end_cap_mode])
		Tipo.ZONA:
			var z: ZonaPeligro = n
			c.append_array([z._radio, z._retardo, z._duracion])
	return c


## 0: ninguno; 1: el que suma luz; 10 + rango: el contorno de raros y élites.
func _material_de(n: CanvasItem) -> int:
	var m := n.material
	if m == null:
		return 0
	if m is CanvasItemMaterial and m.blend_mode == CanvasItemMaterial.BLEND_MODE_ADD:
		return 1
	for r in [Enemigo.Rango.RARO, Enemigo.Rango.ELITE]:
		if m == Enemigo.material_rango(r):
			return 10 + r
	return 0


func _textura_de(t: Texture2D) -> int:
	if t == null:
		return 0
	if not _texturas.has(t):
		var numero := _texturas.size() + 1
		_texturas[t] = numero
		# Casi todas salen de un archivo; las hechas por código viajan como imagen, una vez.
		if t.resource_path != "":
			_texturas_nuevas.append([numero, t.resource_path, PackedByteArray()])
		else:
			var imagen := t.get_image()
			_texturas_nuevas.append([numero, "", imagen.save_png_to_buffer() if imagen != null else PackedByteArray()])
	return _texturas[t]


# ------------------------------------------------------------ invitado
# Lo que llega viene de otro ordenador: se mira todo (tipos, rangos, topes) y lo que no
# cuadra se ignora sin romper nada.
var _nodos := {}  # rid -> nodo de pega (con su tipo y su profundidad en metas)
var _tex_por_numero := {}  # número -> Texture2D

## El tipo de cada casilla: las comunes (C_VISIBLE...) y, detrás, las de cada tipo de nodo.
const FORMA_COMUN := [TYPE_BOOL, TYPE_FLOAT, TYPE_VECTOR2, TYPE_COLOR, TYPE_COLOR, TYPE_INT, TYPE_INT]
const FORMA_TIPO := {
	Tipo.GRUPO: [],
	Tipo.SPRITE: [TYPE_INT, TYPE_INT, TYPE_INT, TYPE_BOOL, TYPE_BOOL, TYPE_VECTOR2, TYPE_BOOL, TYPE_INT],
	Tipo.TEXTO: [TYPE_STRING, TYPE_VECTOR2, TYPE_INT, TYPE_COLOR, TYPE_INT, TYPE_INT, TYPE_COLOR, TYPE_BOOL],
	Tipo.LINEA: [TYPE_PACKED_VECTOR2_ARRAY, TYPE_FLOAT, TYPE_COLOR, TYPE_INT, TYPE_INT, TYPE_INT],
	Tipo.ZONA: [TYPE_FLOAT, TYPE_FLOAT, TYPE_FLOAT],
}
const FIRMA_PNG := [137, 80, 78, 71, 13, 10, 26, 10]


## Borra todos los nodos de pega (al cambiar de sala o salir de la partida). Las texturas
## también: el anfitrión llama a reiniciar() antes de cada cosa que aquí acaba en vaciar()
## (A_SALA, A_EMPEZAR) y vuelve a mandarlas; tras el final o la portada no hace falta ninguna.
func vaciar() -> void:
	for n in _nodos.values():
		if is_instance_valid(n):
			n.queue_free()
	_nodos.clear()
	_tex_por_numero.clear()


func aplicar(datos: Array, raices: Array) -> void:
	if datos.size() < 4 or not (datos[0] is Array) or not (datos[1] is Array) or not (datos[2] is PackedByteArray) \
			or not (datos[3] is PackedInt32Array):
		return
	for t in datos[0]:
		if t is Array:
			_registrar_textura(t)
	for c in datos[1]:
		if c is Array:
			_aplicar_cambio(c, raices)
	var movidos := StreamPeerBuffer.new()
	movidos.data_array = datos[2]
	while movidos.get_available_bytes() >= 9:
		var rid := movidos.get_u32()
		var x := movidos.get_16() / ESCALA_POS
		var y := movidos.get_16() / ESCALA_POS
		var cuadro := movidos.get_u8()
		var n = _nodos.get(rid)
		if n != null and is_instance_valid(n):
			_mover(n, Vector2(x, y), cuadro, false)
	for rid in datos[3]:
		var n = _nodos.get(rid)
		if n != null and is_instance_valid(n):
			n.queue_free()
		_nodos.erase(rid)


func _registrar_textura(t: Array) -> void:
	if t.size() < 3 or not (t[0] is int) or not (t[1] is String) or not (t[2] is PackedByteArray):
		return
	var numero: int = t[0]
	if numero < 1 or numero > TOPE_TEXTURAS:
		return
	var ruta: String = t[1]
	if ruta != "":
		# Solo imágenes del propio juego: lo que llega de fuera no elige qué se carga.
		if ruta.begins_with("res://assets/") and not ruta.contains("..") and ResourceLoader.exists(ruta, "Texture2D"):
			var tex = load(ruta)
			if tex is Texture2D:
				_tex_por_numero[numero] = tex
		return
	var png: PackedByteArray = t[2]
	if png.is_empty() or png.size() > TOPE_PNG or not _png_cabe(png):
		return
	var imagen := Image.new()
	if imagen.load_png_from_buffer(png) == OK:
		_tex_por_numero[numero] = ImageTexture.create_from_image(imagen)


## El tamaño que dice la cabecera del PNG (su IHDR va siempre primero), leído antes de
## descomprimir nada: una imagen enorme ni se abre.
static func _png_cabe(png: PackedByteArray) -> bool:
	if png.size() < 24 or png.slice(0, 8) != PackedByteArray(FIRMA_PNG) or png.slice(12, 16).get_string_from_ascii() != "IHDR":
		return false
	var ancho := (png[16] << 24) | (png[17] << 16) | (png[18] << 8) | png[19]
	var alto := (png[20] << 24) | (png[21] << 16) | (png[22] << 8) | png[23]
	return ancho >= 1 and alto >= 1 and ancho <= TOPE_LADO_PNG and alto <= TOPE_LADO_PNG


func _aplicar_cambio(c: Array, raices: Array) -> void:
	if c.size() < 8 or not (c[7] is Array):
		return
	for i in 7:
		if not (c[i] is int):
			return
	var rid: int = c[0]
	var padre_rid: int = c[1]
	var tipo: int = c[2]
	var mascara: int = c[6]
	var valores: Array = c[7]
	if tipo < Tipo.GRUPO or tipo > Tipo.ZONA:
		return
	var donde := Vector2(c[3], c[4]) / ESCALA_POS
	var n = _nodos.get(rid)
	if n == null or not is_instance_valid(n):
		if mascara != -1 or _nodos.size() >= TOPE_NODOS:
			return  # un cambio de algo que no llegó a crearse (o ya hay demasiados): se ignora
		# El padre: una raíz, o un nodo ya creado que no esté tan hondo como para no tener hijos.
		var padre: Node = null
		var hondo := 1
		if padre_rid < 0:
			if -padre_rid <= raices.size():
				padre = raices[-padre_rid - 1]
		else:
			var de = _nodos.get(padre_rid)
			if de != null and is_instance_valid(de):
				padre = de
				hondo = int(de.get_meta(&"hondo", PROFUNDIDAD)) + 1
		if padre == null or hondo > PROFUNDIDAD:
			return
		n = _crear(tipo)
		n.set_meta(&"tipo", tipo)
		n.set_meta(&"hondo", hondo)
		_nodos[rid] = n
		padre.add_child(n)
		_mover(n, donde, c[5], true)
	elif int(n.get_meta(&"tipo", -1)) != tipo:
		return  # el mismo número con otro tipo de nodo: no cuadra
	else:
		_mover(n, donde, c[5], false)
	var k := 0
	for i in 32:
		if mascara == -1 and i >= valores.size():
			break
		if mascara != -1 and (mascara & (1 << i)) == 0:
			continue
		if k >= valores.size():
			break
		if _de_su_tipo(tipo, i, valores[k]):
			_poner(n, tipo, i, valores[k])
		k += 1


## La casilla trae el tipo que le toca (un entero vale donde van decimales) y nada infinito.
func _de_su_tipo(tipo: int, casilla: int, v: Variant) -> bool:
	var forma: Array = FORMA_COMUN if casilla < C_TIPO else FORMA_TIPO[tipo]
	var i := casilla if casilla < C_TIPO else casilla - C_TIPO
	if i >= forma.size():
		return false
	match int(forma[i]):
		TYPE_FLOAT:
			return (v is float or v is int) and is_finite(float(v))
		TYPE_VECTOR2:
			return v is Vector2 and is_finite(v.x) and is_finite(v.y)
		TYPE_PACKED_VECTOR2_ARRAY:
			if not (v is PackedVector2Array) or v.size() > TOPE_PUNTOS:
				return false
			for punto in v:
				if not is_finite(punto.x) or not is_finite(punto.y):
					return false
			return true
	return typeof(v) == int(forma[i])


func _crear(tipo: int) -> CanvasItem:
	match tipo:
		Tipo.SPRITE: return Pega.new()
		Tipo.TEXTO:
			var l := Label.new()
			l.mouse_filter = Control.MOUSE_FILTER_IGNORE
			return l
		Tipo.LINEA: return Line2D.new()
		Tipo.ZONA: return ZonaPega.new()
	return Node2D.new()


func _mover(n: CanvasItem, p: Vector2, cuadro: int, de_golpe: bool) -> void:
	if n is Pega:
		n.destino = p
		if de_golpe:
			n.position = p
		if cuadro >= 0 and cuadro < n.hframes * n.vframes:
			n.frame = cuadro
	else:
		n.position = p


## Cada valor ya trae su tipo (ver _de_su_tipo); aquí se acota a lo que tiene sentido.
func _poner(n: CanvasItem, tipo: int, casilla: int, v: Variant) -> void:
	match casilla:
		C_VISIBLE: n.visible = v
		C_ROT: n.rotation = float(v)
		C_ESCALA: n.scale = (v as Vector2).clamp(Vector2(-64, -64), Vector2(64, 64))
		C_COLOR: n.modulate = v
		C_COLOR_PROPIO: n.self_modulate = v
		C_Z: n.z_index = clampi(v, RenderingServer.CANVAS_ITEM_Z_MIN, RenderingServer.CANVAS_ITEM_Z_MAX)
		C_MATERIAL:
			if MATERIALES.has(v):
				n.material = _material_numero(v)
		_: _poner_de_tipo(n, tipo, casilla - C_TIPO, v)


func _poner_de_tipo(n: CanvasItem, tipo: int, i: int, v: Variant) -> void:
	match tipo:
		Tipo.SPRITE:
			var s: Pega = n
			match i:
				0: s.texture = _tex_por_numero.get(v)
				1: s.hframes = clampi(v, 1, 256)
				2: s.vframes = clampi(v, 1, 256)
				3: s.flip_h = v
				4: s.flip_v = v
				5: s.offset = (v as Vector2).clamp(Vector2(-4096, -4096), Vector2(4096, 4096))
				6: s.centered = v
				7:
					s.estela = clampi(v, 0, 2)
					s.queue_redraw()
		Tipo.TEXTO:
			var l: Label = n
			match i:
				0: l.text = (v as String).left(TOPE_TEXTO)
				1: l.size = (v as Vector2).clamp(Vector2.ZERO, Vector2(1280, 720))
				2: l.horizontal_alignment = clampi(v, HORIZONTAL_ALIGNMENT_LEFT, HORIZONTAL_ALIGNMENT_FILL) as HorizontalAlignment
				3: l.add_theme_color_override(&"font_color", v)
				4: l.add_theme_font_size_override(&"font_size", clampi(v, 1, 64))
				5: l.add_theme_constant_override(&"outline_size", clampi(v, 0, 16))
				6: l.add_theme_color_override(&"font_outline_color", v)
				7:
					if v:
						l.add_theme_font_override(&"font", Juego.fuente_grande)
		Tipo.LINEA:
			var li: Line2D = n
			match i:
				0: li.points = v
				1: li.width = clampf(v, 0.0, 64.0)
				2: li.default_color = v
				3: li.joint_mode = clampi(v, Line2D.LINE_JOINT_SHARP, Line2D.LINE_JOINT_ROUND) as Line2D.LineJointMode
				4: li.begin_cap_mode = clampi(v, Line2D.LINE_CAP_NONE, Line2D.LINE_CAP_ROUND) as Line2D.LineCapMode
				5: li.end_cap_mode = clampi(v, Line2D.LINE_CAP_NONE, Line2D.LINE_CAP_ROUND) as Line2D.LineCapMode
		Tipo.ZONA:
			var z: ZonaPega = n
			match i:
				0: z._radio = clampf(v, 0.0, 640.0)
				1: z._retardo = clampf(v, 0.001, 30.0)
				2: z._duracion = clampf(v, 0.0, 30.0)


## Solo los de MATERIALES (ver _material_de): otro número ni crea nada ni se guarda.
func _material_numero(numero: int) -> Material:
	if numero == 1:
		if _material_suma == null:
			var m := CanvasItemMaterial.new()
			m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
			_material_suma = m
		return _material_suma
	if numero > 10:
		return Enemigo.material_rango(numero - 10)
	return null


## Un sprite de pega: va hacia donde dice el anfitrión, suavizando los saltos entre mensajes.
class Pega extends Sprite2D:
	var destino := Vector2.ZERO
	var estela := 0  # la de las balas del jugador: 0 no, 1 normal, 2 fuerte

	func _process(delta: float) -> void:
		if position != destino:
			# Lo que está muy lejos (un salto de verdad) no se arrastra por la pantalla.
			if position.distance_squared_to(destino) > 6400.0:
				position = destino
			else:
				position = position.lerp(destino, clampf(delta * 28.0, 0.0, 1.0))

	func _draw() -> void:
		if estela <= 0:
			return
		var fuerte := estela == 2
		var largo := 13.0 if fuerte else 8.0
		draw_line(Vector2(-3.0, 0.0), Vector2(-3.0 - largo, 0.0), Color(1.0, 0.75, 0.35, 0.5 if fuerte else 0.3), 2.0)
		draw_line(Vector2(-3.0, 0.0), Vector2(-3.0 - largo * 0.55, 0.0), Color(1.0, 0.95, 0.8, 0.8 if fuerte else 0.55), 1.0)


## El aviso de zona de pega: se dibuja igual que el de verdad, pero ni quema ni estalla.
class ZonaPega extends ZonaPeligro:
	func _init() -> void:
		z_index = 2

	func _physics_process(delta: float) -> void:
		_t += delta
		queue_redraw()
