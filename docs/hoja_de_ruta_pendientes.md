# Pendientes del TOP 5 solicitado el 14-11-2026

Los cinco agentes Opus se lanzaron y el límite de uso los cortó antes de que escribieran código útil. Los prompts quedan aquí para relanzarlos en frío.

## 1. Personajes con regla propia
Dar a cada uno de los seis personajes una regla única y memorable, no solo un mazo distinto:
- **El Tahúr:** cada 10 bajas seguidas sin recibir golpe, el próximo ciclo dobla el daño. Al recibir golpe se reinicia.
- **El Borracho:** pierde una moneda cada 2 s pero las bajas dan +50 % de oro. Si llega a 0, deja de perder pero las cartas van un 10 % más lentas.
- **La Crupier:** tras cada jefe roba una carta del jefe (definir cartas únicas en `cartas_db.gd`).
- **La Heredera:** empieza con 40 monedas, no suelta oro al matar, descuento del 20 % en la tienda. A 0 monedas y golpe: fin.
- **El Gorila:** voltereta tarda un 40 % más en recargar pero golpea a enemigos cercanos.
- **El Ilusionista:** cartas duplicadas sin combo pero con efecto, +1 ranura, +1 carta trampa.

Archivos: `scripts/personajes_db.gd`, `scripts/player.gd`, `scripts/juego.gd`, `scripts/progreso.gd`. En cooperativo, decidir si la regla es del J1, del equipo o cada uno la suya.

## 2. Ediciones de carta estilo Balatro
Modificadores por carta (Normal, Foil +6 fijo, Holo +4 mult, Policromo ×1.4, Negativo +1 ranura efectiva).

Migrar `Juego.cartas` de `Array[String]` a `Array[Dictionary]` con `{"id":"as_picas","ed":0}`. Compatibilidad con guardados antiguos.

Archivos principales: `scripts/combo.gd`, `motor_cartas.gd`, `main.gd`, `selector.gd`, `barra_cartas.gd`, `coleccion.gd`, `guardado.gd`.

Precio: +50 % por edición. Rarezas en la tienda: Normal 70 %, Foil 11 %, Holo 9 %, Policromo 7 %, Negativo 3 %.

## 3. Narrativa del Dueño
Ampliar `scripts/frases_db.gd`:
- 40+ frases de bienvenida al empezar cada partida, según partidas totales, personaje, racha, modo.
- 3-5 frases propias por cada uno de los 13 jefes al vencerlos.
- Hilo narrativo que avanza con `Progreso.partidas`: en la 5, 10, 20 el Dueño suelta pistas.
- Final alternativo al vencer al Dueño con todas las pistas vistas.

Historia en 400-600 palabras, cínica, humor seco, estilo noir años 20, sin palabrotas ni marcas. Progreso: `Progreso.frases_vistas`. UI: rótulo bajo con retrato del Dueño, saltable con tecla/botón.

## 4. Boss Rush
13 jefes seguidos, con "respiro" entre jefes (una de 3 cartas o uno de 2 objetos). Cura de 2 corazones entre jefes. Vida de jefes ×1.4. Dueño siempre al final. Orden aleatorio.

Desbloqueo: al vencer al Dueño por primera vez. Antes NO aparece (no solo bloqueado).

Modo propio, no combina con extremo/imposible/infinito/Contrato. Puntuación por tiempo y golpes. Récord por personaje en Progreso. Cooperativo SÍ se permite.

Archivos: `scripts/main.gd`, `scripts/juego.gd`, `scripts/menu.gd`, `scripts/seleccion.gd`, `scripts/progreso.gd`.

## 5. Logros secretos
12 logros nuevos con `"secreto": true` en `scripts/logros_db.gd`. Hasta desbloquearlos: silueta y "???". Rótulo propio "LOGRO SECRETO" en color oro oscuro.

Ideas:
- Deuda saldada (200 al prestamista en una partida)
- Siete, siete, siete (tres 777 en la tragaperras)
- La bola amañada (5 rojo/negro seguidos)
- Sin dejar huellas (sin volcar mesas)
- El pez volador (Pez Rojo < 10 s)
- Último baile (ganar con 1 corazón)
- Mano vacía (llegar al Dueño sin cartas)
- El golpe perfecto (piso sin golpes)
- Matemáticas de casino (combo ≥ ×25)
- La casa pierde (Dueño < 20 s)
- Amigos íntimos (10 reanimaciones en coop)
- Cliente habitual (7 retos seguidos)

Añadir contadores donde falten en `Progreso`. Pantalla de logros: "X/Y, Z secretos descubiertos de 12".

## Cómo lanzar los agentes
Cada tarea en su worktree desde main 2.0. Prompts completos en los mensajes del usuario del 14-11-2026. Ejecutar con `XDG_DATA_HOME` propio para no pisarse.

## Pendientes operativos
- Encender tabla mundial (crear proyecto Supabase, pegar `servidor/esquema.sql`, rellenar `online.cfg`).
- Encender cooperativo online (desplegar `servidor/rele/` en Cloud Run o similar, rellenar `[multijugador] servidor` en `online.cfg`).
- Subir a Google Play (25 USD, formato AAB, 12 testers 14 días; detalles en `docs/hoja_de_ruta.md`).
- Apple App Store (99 €/año, Mac en la nube o GitHub Actions; `docs/hoja_de_ruta.md`).
