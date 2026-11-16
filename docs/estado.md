# Estado del proyecto · La Casa Siempre Gana

Última versión publicada: **2.0** (commit `47b29c8`). Archivos en `builds/` del equipo de Jaime.

## Qué incluye la 2.0
- **Mando** completo (juego, menús, fila de cartas, tragaperras, ruleta), con vibración.
- **Sala de apuestas** (tragaperras, ruleta) con monedas y corazones, nunca dinero real.
- **Enemigos raros y élites** con ocho modificadores; camareros y sprites repasados.
- **Reto diario determinista** con intento puntuable único, racha y botón de "copiar resultado".
- **Tabla mundial y cuentas** construidas (apagadas hasta que se configure Supabase; pasos en `servidor/README.md`).
- **Enganche del TOP 8** del documento `docs/hoja_de_ruta.md` (todos los 8 puntos).
- **Seis idiomas**: español, inglés, portugués de Brasil, francés, alemán, italiano (874 textos cada uno).
- **Cooperativo local** con dos jugadores en la misma pantalla.
- **Cooperativo online** de la PR #4 (necesita un relé propio, instrucciones en `servidor/README.md`).
- Arreglos de PRs #2 y #3 de Marcos (tope de 2 copias por carta, tienda sin cobrar por nada, deuda del coop a medias).

## Pruebas
- 16 pruebas automáticas en verde (`prueba_coop, mando, menu, interfaz, tactil, progreso, modos, mecanicas, combo, apuestas, idiomas, rangos, enganche_a, enganche_b, diario, online`). La 17ª (`pareja`) es para el cooperativo online y la lanza `tests/prueba_pareja.sh`.
- Bot en solitario gana una partida completa en modo invencible.

## Lo que falta
Mejoras pedidas pero sin empezar (se lanzaron agentes y el límite de uso los cortó nada más arrancar; tenían 0-6 líneas cada uno). Al retomar, el plan está en los prompts de los agentes dentro de este documento:

1. **Personajes con mecánica propia.** Cada uno de los seis con una regla única (racha de bajas, oro perdido, cartas de jefe, descuento sin oro, voltereta que golpea, cartas duplicadas sin combo).
2. **Ediciones de carta estilo Balatro.** Normal, Foil (+6 fijo), Holo (+4 mult), Policromo (×1.4), Negativo (+1 ranura efectiva). Migrar `Juego.cartas` a `Array[Dictionary]`.
3. **Narrativa del Dueño.** Frase al empezar la partida, al vencer cada jefe, hilo narrativo que avanza con `Progreso.partidas`, final alternativo al desbloquear. 40+ frases nuevas con sus traducciones.
4. **Boss Rush.** 13 jefes seguidos, con cura y una carta u objeto entre jefes. Desbloqueado al vencer al Dueño. Modo propio sin mezclas con extremo/imposible/infinito.
5. **12 logros secretos.** Con silueta y "???" hasta descubrirlos, con pistas y rótulo propio.

## Después de /clear
Para retomar la sesión:
1. Lee este documento y `docs/hoja_de_ruta.md`.
2. El repo en `~/repo` es `main` de GitHub: `jcamara1240-hub/la-casa-siempre-gana`.
3. Para lanzar los cinco agentes Opus de los pendientes, hazlo cada uno en su worktree (rama partiendo de `main`) con el prompt de la sesión anterior. Si los diste por perdidos, están escritos en los mensajes de usuario a Claude; si no, aquí tienes el resumen de cada uno.
4. La clave del keystore de Android está en `~/claves/`. Nunca va al repo.
5. El servidor del cooperativo online no está desplegado. Los pasos para montarlo (Bun + Docker + Cloud Run) están en `servidor/README.md`.

## Convenciones
- Commits a nombre de **Jaime <jcamara1240-hub@users.noreply.github.com>**, sin "Co-Authored-By: Claude", sin "Generated with Claude Code", sin enlace de sesión. Sin rastro de IA en el repo ni en comentarios.
- Código y comentarios en **español**. Textos visibles por `Idioma.t()` con traducción EN y los cuatro idiomas secundarios (pt, fr, de, it).
- Godot 4.7, GDScript, renderer Compatibility, viewport 640×360.
- No autoloads nuevos. No tocar `project.godot` salvo imprescindible. No tocar `export_presets.cfg` salvo para subir versión.
- Pruebas: ejecutables con `timeout 220 $G --headless --fixed-fps 60 --path . -s res://tests/prueba_X.gd`. Scripts de test no deben nombrar clases que usen `Juego` directamente (los autoloads cargan después).
