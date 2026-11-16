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
			_capturar_nodo(hijo, -(i + 1), cambiados, movidos, vistos)
	var fuera := PackedInt32Array()
	for rid in _ultimo.keys():
		if not vistos.has(rid):
			_ultimo.erase(rid)
			fuera.append(rid)
	return [_texturas_nuevas, cambiados, movidos.data_array, fuera]


func _capturar_nodo(n: Node, padre: int, cambiados: Array, movidos: StreamPeerBuffer, vistos: Dictionary) -> void:
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
	for hijo in n.get_children():
		_capturar_nodo(hijo, rid, cambiados, movidos, vistos)


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
var _nodos := {}  # rid -> nodo de pega
var _tex_por_numero := {}  # número -> Texture2D


## Borra todos los nodos de pega (al cambiar de sala o salir de la partida).
func vaciar() -> void:
	for n in _nodos.values():
		if is_instance_valid(n):
			n.queue_free()
	_nodos.clear()


func aplicar(datos: Array, raices: Array) -> void:
	if datos.size() < 4:
		return
	for t in datos[0]:
		_registrar_textura(t)
	for c in datos[1]:
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
	var ruta := String(t[1])
	if ruta != "":
		# Solo imágenes del propio juego: lo que llega de fuera no elige qué se carga.
		if ruta.begins_with("res://assets/") and ResourceLoader.exists(ruta, "Texture2D"):
			_tex_por_numero[int(t[0])] = load(ruta)
		return
	var png: PackedByteArray = t[2]
	if png.is_empty() or png.size() > 262144:
		return
	var imagen := Image.new()
	if imagen.load_png_from_buffer(png) == OK:
		_tex_por_numero[int(t[0])] = ImageTexture.create_from_image(imagen)


func _aplicar_cambio(c: Array, raices: Array) -> void:
	var rid := int(c[0])
	var tipo := int(c[2])
	var mascara := int(c[6])
	var valores: Array = c[7]
	var n = _nodos.get(rid)
	if n == null or not is_instance_valid(n):
		if mascara != -1:
			return  # un cambio de algo que no llegó a crearse: se ignora
		var padre = raices[-int(c[1]) - 1] if int(c[1]) < 0 else _nodos.get(int(c[1]))
		if padre == null or not is_instance_valid(padre):
			return
		n = _crear(tipo)
		_nodos[rid] = n
		padre.add_child(n)
		_mover(n, Vector2(c[3], c[4]) / ESCALA_POS, int(c[5]), true)
	else:
		_mover(n, Vector2(c[3], c[4]) / ESCALA_POS, int(c[5]), false)
	var k := 0
	for i in 32:
		if mascara == -1 and i >= valores.size():
			break
		if mascara != -1 and (mascara & (1 << i)) == 0:
			continue
		if k >= valores.size():
			break
		_poner(n, tipo, i, valores[k])
		k += 1


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
		if cuadro < n.hframes * n.vframes:
			n.frame = cuadro
	else:
		n.position = p


func _poner(n: CanvasItem, tipo: int, casilla: int, v: Variant) -> void:
	match casilla:
		C_VISIBLE: n.visible = bool(v)
		C_ROT: n.rotation = float(v)
		C_ESCALA: n.scale = v
		C_COLOR: n.modulate = v
		C_COLOR_PROPIO: n.self_modulate = v
		C_Z: n.z_index = int(v)
		C_MATERIAL: n.material = _material_numero(int(v))
		_: _poner_de_tipo(n, tipo, casilla - C_TIPO, v)


func _poner_de_tipo(n: CanvasItem, tipo: int, i: int, v: Variant) -> void:
	match tipo:
		Tipo.SPRITE:
			var s: Pega = n
			match i:
				0: s.texture = _tex_por_numero.get(int(v))
				1: s.hframes = maxi(int(v), 1)
				2: s.vframes = maxi(int(v), 1)
				3: s.flip_h = bool(v)
				4: s.flip_v = bool(v)
				5: s.offset = v
				6: s.centered = bool(v)
				7:
					s.estela = int(v)
					s.queue_redraw()
		Tipo.TEXTO:
			var l: Label = n
			match i:
				0: l.text = String(v)
				1: l.size = v
				2: l.horizontal_alignment = int(v)
				3: l.add_theme_color_override(&"font_color", v)
				4: l.add_theme_font_size_override(&"font_size", int(v))
				5: l.add_theme_constant_override(&"outline_size", int(v))
				6: l.add_theme_color_override(&"font_outline_color", v)
				7:
					if bool(v):
						l.add_theme_font_override(&"font", Juego.fuente_grande)
		Tipo.LINEA:
			var li: Line2D = n
			match i:
				0: li.points = v
				1: li.width = float(v)
				2: li.default_color = v
				3: li.joint_mode = int(v)
				4: li.begin_cap_mode = int(v)
				5: li.end_cap_mode = int(v)
		Tipo.ZONA:
			var z: ZonaPega = n
			match i:
				0: z._radio = float(v)
				1: z._retardo = maxf(float(v), 0.001)
				2: z._duracion = float(v)


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
