#!/usr/bin/env bash
# Cooperativo online de punta a punta: el relé en local y dos juegos (anfitrión e invitado).
#   GODOT=/ruta/a/godot tests/prueba_pareja.sh
set -u
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
PUERTO="${PUERTO:-18765}"
TMP="$(mktemp -d)"
trap 'kill $RELE 2>/dev/null; rm -rf "$TMP"' EXIT

PORT=$PUERTO GRACIA_MS=25000 bun servidor/rele/servidor.ts >"$TMP/rele.log" 2>&1 &
RELE=$!
sleep 1

# Cada juego con su carpeta de datos, como dos ordenadores distintos.
lanzar() {
	XDG_DATA_HOME="$TMP/$1" timeout 240 "$GODOT" --headless --path . -s res://tests/prueba_pareja.gd \
		-- "$1" "ws://127.0.0.1:$PUERTO" "$TMP/codigo" 2>&1 | grep -vE '^Godot Engine|^$|ObjectDB|resources still|at: (cleanup|clear)'
	return "${PIPESTATUS[0]}"
}
lanzar anfitrion &
A=$!
lanzar invitado &
I=$!
wait $A; FA=$?
wait $I; FI=$?
if [ $FA -ne 0 ] || [ $FI -ne 0 ]; then
	echo "COOPERATIVO ONLINE: MAL (anfitrión $FA, invitado $FI)"
	exit 1
fi
echo "COOPERATIVO ONLINE: BIEN"
