class_name Red
extends Node
## El cable del cooperativo online: la conexión con el relé (servidor/rele) y la sala de dos.
## Lo crea main.gd por código. Sin "servidor" en online.cfg, sección [multijugador], queda
## apagado: no se ve nada online ni se abre ninguna conexión.
##
## El relé solo junta a dos jugadores con un código y pasa lo que manda uno al otro. La
## partida la lleva el anfitrión; el invitado la ve "en espejo" (ver espejo.gd).
## Los mensajes de la partida son Arrays ([tipo, datos...]) en binario, sin objetos.

signal estado_cambiado  # conexión, sala o compañero: la pantalla se repinta
signal mensaje(m: Array)  # lo que manda el otro jugador
signal error_sala(motivo: String)  # "no_existe", "llena", "version", "lleno", "sin_conexion"
## El otro se ha ido (motivo "") o me he quedado yo sin conexión del todo ("sin_conexion").
signal companero_fuera(motivo: String)
signal companero_vuelve  # el otro ha vuelto tras un corte: el anfitrión se lo manda todo otra vez

enum Estado { APAGADO, CONECTANDO, CONECTADO, EN_SALA, VOLVIENDO }

const RUTAS_CONFIG := ["user://online.cfg", "res://online.cfg", "res://multijugador.cfg"]
## La versión del juego y, detrás, la de lo que se cuentan los dos ordenadores. Solo se juntan
## dos iguales: súbela con cada versión del juego y con cada cambio en pareja.gd o espejo.gd.
const VERSION := "1.9-2"
const TIEMPO_CONEXION := 10.0
const ECO_CADA := 5.0  # mantiene viva la conexión y mide el retraso
## Sin nada del relé en este tiempo (ni el eco) la conexión está muerta aunque no lo diga.
const SILENCIO_MAX := 12.0

const COMPRIMIR_DESDE := 200  # bytes: por debajo no merece la pena
const TOPE_MENSAJE := 240 * 1024  # el relé corta la conexión con mensajes de más de 256 KB
const TOPE_DESCOMPRIMIDO := 4 * 1024 * 1024
## Lo del invitado son peticiones diminutas (dónde está, qué pulsa): lo que pase de esto no lo es.
const TOPE_DEL_INVITADO := 16 * 1024
const PAQUETES_POR_FOTOGRAMA := 64  # lo que no quepa se lee en el siguiente: nada atasca un fotograma
const RECONECTAR_SEG := 20.0  # lo que se intenta volver tras un corte (el relé guarda el sitio 25 s)
const RECONECTAR_CADA := 2.0

## Cambia todo el reenvío de sonidos y efectos del anfitrión: false mientras se hace algo
## que el invitado ya ha hecho por su cuenta (su propia voltereta, por ejemplo).
static var eco := true
## El anfitrión está en plena partida con el invitado dentro: los sonidos y los efectos que
## pasan aquí se apuntan en la cola para que el invitado los vea y los oiga también.
static var reenviando := false
## Este ordenador es el invitado en plena partida: nada de aquí cambia la partida de verdad.
static var espejo := false
## Lo que hay apuntado para el otro: [tipo, datos...]. La vacía pareja.gd al mandarla.
static var cola: Array = []
const FX := 0  # un efecto del jugo: [FX, método, argumentos]
const SONIDO := 1  # [SONIDO, nombre, tono, ajuste_db]
const MUSICA := 2  # [MUSICA, nombre]
const MOVER_CARTA := 3  # del invitado al anfitrión: [MOVER_CARTA, origen, destino]


## Apunta un efecto del jugo para el invitado (si toca).
static func fx(metodo: StringName, argumentos: Array) -> void:
	if reenviando and eco:
		cola.append([FX, metodo, argumentos])

var servidor := ""  # wss://...
var estado := Estado.APAGADO
var codigo := ""
var anfitrion := false
var companero := ""  # el nombre del otro, "" si aún no ha entrado
var hay_companero := false
var retraso_ms := -1
## El otro se ha quedado sin conexión y el relé le guarda el sitio (o soy yo el que vuelve).
var esperando := false
var bytes_enviados := 0  # para las pruebas y para vigilar el tráfico
## Un mensaje no ha salido (no cabía o el envío ha fallado): lo que tiene el otro ya no
## cuadra. El anfitrión lo mira y se lo vuelve a contar todo (ver pareja.gd).
var falta_algo := false

var _llave := ""  # la da el relé: con ella se recupera el sitio tras un corte
var _t_volver := 0.0
var _t_reintento := 0.0
var _ws: WebSocketPeer
var _t_conexion := 0.0
var _t_eco := 0.0
var _t_silencio := 0.0
var _al_conectar: Callable


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for ruta in RUTAS_CONFIG:
		var cfg := ConfigFile.new()
		if cfg.load(ruta) == OK and String(cfg.get_value("multijugador", "servidor", "")) != "":
			servidor = String(cfg.get_value("multijugador", "servidor", ""))
			return


## ¿Hay relé configurado? Si no, el menú no enseña el cooperativo online.
func disponible() -> bool:
	return servidor != ""


func en_sala() -> bool:
	return estado == Estado.EN_SALA or estado == Estado.VOLVIENDO


func invitado() -> bool:
	return en_sala() and not anfitrion


## Jugando con otro por internet (los dos dentro de la sala).
func en_pareja() -> bool:
	return en_sala() and hay_companero


func crear_sala(nombre: String) -> void:
	_conectar_y(func(): _ordenar({"t": "crear", "nombre": nombre, "version": VERSION}))


func unirse(codigo_sala: String, nombre: String) -> void:
	_conectar_y(func(): _ordenar({"t": "unirse", "codigo": codigo_sala.strip_edges().to_upper(), "nombre": nombre, "version": VERSION}))


func salir() -> void:
	if _ws != null:
		_ordenar({"t": "salir"})  # irse a propósito: el relé no le guarda el sitio
		_ws.close()
	_ws = null
	estado = Estado.APAGADO
	codigo = ""
	companero = ""
	hay_companero = false
	anfitrion = false
	retraso_ms = -1
	esperando = false
	falta_algo = false
	_llave = ""
	estado_cambiado.emit()


## Un mensaje de la partida para el otro jugador. Los grandes viajan comprimidos:
## el primer byte dice cómo (0 tal cual, 1 comprimido y detrás su tamaño de verdad).
func enviar(m: Array) -> void:
	if _ws == null or estado != Estado.EN_SALA or not hay_companero or esperando or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	var paquete := empaquetar(m)
	if paquete.size() > TOPE_MENSAJE:
		push_warning("Red: mensaje demasiado grande (%d bytes), no se manda" % paquete.size())
		falta_algo = true
		return
	if _ws.send(paquete) != OK:
		falta_algo = true
		return
	bytes_enviados += paquete.size()


static func empaquetar(m: Array) -> PackedByteArray:
	var crudo := var_to_bytes(m)
	var paquete := PackedByteArray()
	if crudo.size() < COMPRIMIR_DESDE:
		paquete.append(0)
		paquete.append_array(crudo)
		return paquete
	paquete.resize(5)
	paquete.encode_u8(0, 1)
	paquete.encode_u32(1, crudo.size())
	paquete.append_array(crudo.compress(FileAccess.COMPRESSION_ZSTD))
	return paquete


## Lo contrario de empaquetar. Devuelve null si lo que llega no tiene sentido o, ya
## descomprimido, pasa de tope.
static func desempaquetar(paquete: PackedByteArray, tope := TOPE_DESCOMPRIMIDO) -> Variant:
	if paquete.size() < 2:
		return null
	var crudo: PackedByteArray
	if paquete[0] == 0:
		if paquete.size() - 1 > tope:
			return null
		crudo = paquete.slice(1)
	elif paquete[0] == 1 and paquete.size() > 5:
		var largo := paquete.decode_u32(1)
		if largo <= 0 or largo > tope:
			return null
		crudo = paquete.slice(5).decompress(largo, FileAccess.COMPRESSION_ZSTD)
		if crudo.size() != largo:
			return null
	else:
		return null
	return bytes_to_var(crudo)  # sin objetos: lo que venga de fuera son solo datos


func _conectar_y(siguiente: Callable) -> void:
	if not disponible():
		error_sala.emit("sin_conexion")
		return
	salir()
	if not _abrir():
		error_sala.emit("sin_conexion")
		return
	estado = Estado.CONECTANDO
	_t_conexion = 0.0
	_al_conectar = siguiente
	estado_cambiado.emit()


func _abrir() -> bool:
	_ws = WebSocketPeer.new()
	_ws.inbound_buffer_size = 4 * 1024 * 1024
	_ws.outbound_buffer_size = 4 * 1024 * 1024
	_ws.max_queued_packets = 8192
	if _ws.connect_to_url(servidor) != OK:
		_ws = null
		return false
	_t_silencio = 0.0
	return true


func _ordenar(orden: Dictionary) -> void:
	if _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send_text(JSON.stringify(orden))


func _process(delta: float) -> void:
	var real := delta / maxf(Engine.time_scale, 0.001)
	if estado == Estado.VOLVIENDO:
		_seguir_volviendo(real)
	if _ws == null:
		return
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.STATE_CONNECTING:
			_t_conexion += real
			if _t_conexion > TIEMPO_CONEXION:
				_caer("sin_conexion")
		WebSocketPeer.STATE_OPEN:
			if estado == Estado.CONECTANDO:
				estado = Estado.CONECTADO
				_al_conectar.call()
			elif estado == Estado.VOLVIENDO and _al_conectar.is_valid():
				_al_conectar.call()
				_al_conectar = Callable()
			_t_silencio += real  # antes de leer: tras un tirón largo, lo que espera en cola cuenta
			_leer()
			if _ws == null:
				return
			if estado == Estado.EN_SALA and _t_silencio > SILENCIO_MAX:
				# Ni el eco: la conexión está muerta aunque no se haya cerrado. Se vuelve con la llave.
				_ws.close()
				_caer("sin_conexion")
				return
			_t_eco += real
			if _t_eco >= ECO_CADA:
				_t_eco = 0.0
				_ordenar({"t": "eco", "n": Time.get_ticks_msec()})
		WebSocketPeer.STATE_CLOSED:
			_caer("sin_conexion")


func _leer() -> void:
	# El anfitrión no se traga nada grande del invitado: lo suyo legítimo cabe de sobra en el tope.
	var tope := TOPE_DEL_INVITADO if anfitrion else TOPE_DESCOMPRIMIDO
	var leidos := 0
	while _ws != null and _ws.get_available_packet_count() > 0 and leidos < PAQUETES_POR_FOTOGRAMA:
		leidos += 1
		_t_silencio = 0.0
		var paquete := _ws.get_packet()
		if _ws.was_string_packet():
			var datos = JSON.parse_string(paquete.get_string_from_utf8())
			if datos is Dictionary:
				_al_ordenar(datos)
			continue
		var m = desempaquetar(paquete, tope)
		if m is Array and not m.is_empty() and m[0] is int:
			mensaje.emit(m)


## Se ha cortado con la sala abierta: se vuelve a llamar al relé cada poco, con la llave.
func _seguir_volviendo(real: float) -> void:
	_t_volver += real
	if _t_volver > RECONECTAR_SEG:
		var habia := hay_companero
		salir()
		if habia:
			companero_fuera.emit("sin_conexion")
		else:
			error_sala.emit("sin_conexion")
		return
	if _ws != null:
		return
	_t_reintento -= real
	if _t_reintento > 0.0:
		return
	_t_reintento = RECONECTAR_CADA
	_t_conexion = 0.0
	if _abrir():
		_al_conectar = func(): _ordenar({"t": "volver", "codigo": codigo, "llave": _llave})


func _al_ordenar(d: Dictionary) -> void:
	match String(d.get("t", "")):
		"sala":
			estado = Estado.EN_SALA
			anfitrion = true
			codigo = String(d.get("codigo", ""))
			_llave = String(d.get("llave", ""))
		"unido":
			estado = Estado.EN_SALA
			anfitrion = false
			codigo = String(d.get("codigo", ""))
			_llave = String(d.get("llave", ""))
			companero = String(d.get("nombre", ""))
			hay_companero = true
		"vuelto":  # he recuperado mi sitio tras un corte
			estado = Estado.EN_SALA
			esperando = bool(d.get("solo", false))
			if hay_companero and not esperando:
				companero_vuelve.emit()
		"espera":  # el otro se ha quedado sin conexión: el relé le guarda el sitio un rato
			esperando = true
		"vuelve":
			esperando = false
			companero_vuelve.emit()
		"entra":
			companero = String(d.get("nombre", ""))
			hay_companero = true
		"sale":
			var habia := hay_companero
			companero = ""
			hay_companero = false
			if not anfitrion:
				salir()  # sin anfitrión no hay sala
			if habia:
				companero_fuera.emit("")
		"eco":
			retraso_ms = maxi(Time.get_ticks_msec() - int(d.get("n", 0)), 0)
		"error":
			if estado == Estado.VOLVIENDO:
				# Volviendo tras un corte, un "no" puede ser de un relé que aún no ha soltado mi
				# conexión vieja: se reintenta como cualquier otro fallo hasta RECONECTAR_SEG.
				_ws.close()
				_ws = null
				return
			var motivo := String(d.get("motivo", "sin_conexion"))
			var habia := hay_companero
			salir()
			if habia:
				companero_fuera.emit("sin_conexion")
			else:
				error_sala.emit(motivo)
			return
	estado_cambiado.emit()


func _caer(motivo: String) -> void:
	# Con la sala abierta y la llave del relé, un corte no es el final: se intenta volver.
	if (estado == Estado.EN_SALA or estado == Estado.VOLVIENDO) and _llave != "":
		if estado == Estado.EN_SALA:
			_t_volver = 0.0
			_t_reintento = 0.5
		estado = Estado.VOLVIENDO
		_ws = null
		estado_cambiado.emit()
		return
	var habia := hay_companero
	var estaba := estado
	salir()
	if habia:
		companero_fuera.emit("sin_conexion")
	elif estaba != Estado.APAGADO:
		error_sala.emit(motivo)
