// Relé del cooperativo online de "La casa siempre gana".
//
// Dos jugadores se encuentran con un código de sala y, a partir de ahí, todo lo que manda
// uno en binario le llega al otro tal cual. El relé no entiende la partida: la lleva el
// anfitrión (ver scripts/red.gd, scripts/pareja.gd y scripts/espejo.gd). Las órdenes de sala
// van en JSON de texto.
//
//   cliente -> relé   {"t":"crear","nombre":"ANA","version":"1.9"}
//                     {"t":"unirse","codigo":"K7QF","nombre":"LUIS","version":"1.9"}
//                     {"t":"volver","codigo":"K7QF","llave":"..."}   (tras un corte)
//                     {"t":"salir"}                            (irse a propósito)
//                     {"t":"eco","n":123}                      (para medir el retraso)
//   relé -> cliente   {"t":"sala","codigo":"K7QF","llave":"..."}     (al que crea)
//                     {"t":"entra","nombre":"LUIS"}            (al anfitrión)
//                     {"t":"unido","codigo":"K7QF","nombre":"ANA","llave":"..."}  (al invitado)
//                     {"t":"espera"}                           (el otro se ha quedado sin conexión)
//                     {"t":"vuelve"}                           (y ha vuelto)
//                     {"t":"vuelto","solo":false}              (al que vuelve; solo: el otro no está ahora)
//                     {"t":"sale"}                             (el otro se ha ido del todo)
//                     {"t":"error","motivo":"no_existe"|"llena"|"version"|"peticion"|"lleno"}
//
// Una conexión que se corta sin decir "salir" conserva su sitio GRACIA_MS: puede volver con
// su llave y la partida sigue. Pasado ese tiempo es como si se hubiera ido.
//
// Todo vive en memoria: tiene que haber UNA sola instancia (en Cloud Run, --max-instances=1).

import type { ServerWebSocket } from "bun";

const PUERTO = Number(process.env.PORT ?? 8080);
const MAX_SALAS = Number(process.env.MAX_SALAS ?? 200);
const MAX_MENSAJE = 256 * 1024; // bytes por mensaje
const MAX_POR_SEGUNDO = Number(process.env.MAX_POR_SEGUNDO ?? 400 * 1024); // bytes por conexión
const GRACIA_MS = Number(process.env.GRACIA_MS ?? 25 * 1000); // lo que se guarda el sitio tras un corte
const SALA_VACIA_MS = 10 * 60 * 1000; // una sala sin invitado caduca
const SALA_MAX_MS = 6 * 60 * 60 * 1000; // y ninguna dura más que esto
const LETRAS = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"; // sin 0/O, 1/I/L: se dictan de viva voz
const LARGO_CODIGO = 4;

type Socket = ServerWebSocket<Conexion>;

interface Conexion {
  sala: Sala | null;
  asiento: 0 | 1; // 0 el anfitrión, 1 el invitado
  bytes: number; // en el segundo en curso
  segundo: number;
}

interface Asiento {
  ws: Socket | null; // null: se le ha cortado y se le guarda el sitio
  nombre: string;
  llave: string;
  fuera: number; // cuándo se cortó (0 si está conectado)
}

interface Sala {
  codigo: string;
  version: string;
  asientos: [Asiento, Asiento | null];
  creada: number;
}

type Orden =
  | { t: "crear"; nombre: string; version: string }
  | { t: "unirse"; codigo: string; nombre: string; version: string }
  | { t: "volver"; codigo: string; llave: string }
  | { t: "salir" }
  | { t: "eco"; n: number };

const salas = new Map<string, Sala>();

function codigoNuevo(): string {
  for (;;) {
    const azar = crypto.getRandomValues(new Uint8Array(LARGO_CODIGO));
    let codigo = "";
    for (const b of azar) codigo += LETRAS[b % LETRAS.length];
    if (!salas.has(codigo)) return codigo;
  }
}

function llaveNueva(): string {
  return Array.from(crypto.getRandomValues(new Uint8Array(16)), (b) => b.toString(16).padStart(2, "0")).join("");
}

function texto(valor: unknown, max: number): string {
  return typeof valor === "string" ? valor.slice(0, max) : "";
}

function leerOrden(crudo: string): Orden | null {
  let datos: unknown;
  try {
    datos = JSON.parse(crudo);
  } catch {
    return null;
  }
  if (typeof datos !== "object" || datos === null) return null;
  const d = datos as Record<string, unknown>;
  const nombre = texto(d.nombre, 16);
  const version = texto(d.version, 12);
  const codigo = texto(d.codigo, 8).toUpperCase();
  switch (d.t) {
    case "crear":
      return { t: "crear", nombre, version };
    case "unirse":
      return { t: "unirse", codigo, nombre, version };
    case "volver":
      return { t: "volver", codigo, llave: texto(d.llave, 64) };
    case "salir":
      return { t: "salir" };
    case "eco":
      return { t: "eco", n: typeof d.n === "number" ? d.n : 0 };
  }
  return null;
}

function decir(ws: Socket | null | undefined, mensaje: Record<string, unknown>): void {
  if (ws) ws.send(JSON.stringify(mensaje));
}

function elOtro(ws: Socket): Asiento | null {
  const sala = ws.data.sala;
  if (sala === null) return null;
  return sala.asientos[ws.data.asiento === 0 ? 1 : 0];
}

/** Ese asiento se queda libre del todo: si era el del anfitrión, la sala se cierra. */
function vaciarAsiento(sala: Sala, cual: 0 | 1): void {
  const asiento = sala.asientos[cual];
  if (asiento === null) return;
  if (asiento.ws !== null) asiento.ws.data.sala = null;
  const otro = sala.asientos[cual === 0 ? 1 : 0];
  if (cual === 0) {
    salas.delete(sala.codigo);
    if (otro !== null && otro.ws !== null) otro.ws.data.sala = null;
  } else {
    sala.asientos[1] = null;
  }
  if (otro !== null) decir(otro.ws, { t: "sale" });
}

/** Quien se va a propósito deja la sala en el acto. */
function dejarSala(ws: Socket): void {
  const sala = ws.data.sala;
  if (sala !== null && sala.asientos[ws.data.asiento]?.ws === ws) vaciarAsiento(sala, ws.data.asiento);
  ws.data.sala = null;
}

/** Se ha cortado sin avisar: se le guarda el sitio un rato y el otro espera. */
function alCortarse(ws: Socket): void {
  const sala = ws.data.sala;
  if (sala === null) return;
  const asiento = sala.asientos[ws.data.asiento];
  if (asiento === null || asiento.ws !== ws) return;
  ws.data.sala = null;
  if (GRACIA_MS <= 0) {
    asiento.ws = null;
    vaciarAsiento(sala, ws.data.asiento);
    return;
  }
  asiento.ws = null;
  asiento.fuera = Date.now();
  decir(elOtroDe(sala, ws.data.asiento)?.ws, { t: "espera" });
}

function elOtroDe(sala: Sala, cual: 0 | 1): Asiento | null {
  return sala.asientos[cual === 0 ? 1 : 0];
}

function alRecibirOrden(ws: Socket, orden: Orden): void {
  switch (orden.t) {
    case "eco":
      decir(ws, { t: "eco", n: orden.n });
      return;
    case "salir":
      dejarSala(ws);
      return;
    case "crear": {
      dejarSala(ws);
      if (salas.size >= MAX_SALAS) {
        decir(ws, { t: "error", motivo: "lleno" });
        return;
      }
      const anfitrion: Asiento = { ws, nombre: orden.nombre, llave: llaveNueva(), fuera: 0 };
      const sala: Sala = { codigo: codigoNuevo(), version: orden.version, asientos: [anfitrion, null], creada: Date.now() };
      salas.set(sala.codigo, sala);
      ws.data.sala = sala;
      ws.data.asiento = 0;
      decir(ws, { t: "sala", codigo: sala.codigo, llave: anfitrion.llave });
      return;
    }
    case "unirse": {
      dejarSala(ws);
      const sala = salas.get(orden.codigo);
      if (sala === undefined) {
        decir(ws, { t: "error", motivo: "no_existe" });
        return;
      }
      if (sala.asientos[1] !== null) {
        decir(ws, { t: "error", motivo: "llena" });
        return;
      }
      if (sala.version !== orden.version) {
        decir(ws, { t: "error", motivo: "version" });
        return;
      }
      const invitado: Asiento = { ws, nombre: orden.nombre, llave: llaveNueva(), fuera: 0 };
      sala.asientos[1] = invitado;
      ws.data.sala = sala;
      ws.data.asiento = 1;
      decir(ws, { t: "unido", codigo: sala.codigo, nombre: sala.asientos[0].nombre, llave: invitado.llave });
      decir(sala.asientos[0].ws, { t: "entra", nombre: orden.nombre });
      return;
    }
    case "volver": {
      dejarSala(ws);
      const sala = salas.get(orden.codigo);
      const cual = sala === undefined ? -1 : sala.asientos.findIndex((a) => a !== null && a.ws === null && a.llave === orden.llave && orden.llave !== "");
      if (sala === undefined || cual < 0) {
        decir(ws, { t: "error", motivo: "no_existe" });
        return;
      }
      const asiento = sala.asientos[cual] as Asiento;
      asiento.ws = ws;
      asiento.fuera = 0;
      ws.data.sala = sala;
      ws.data.asiento = cual as 0 | 1;
      const otro = elOtroDe(sala, cual as 0 | 1);
      decir(ws, { t: "vuelto", solo: otro !== null && otro.ws === null });
      decir(otro?.ws, { t: "vuelve" });
      return;
    }
  }
}

/** Un tope de bytes por segundo y conexión: el relé no es un túnel para lo que sea. */
function pasaElTope(ws: Socket, bytes: number): boolean {
  const ahora = Math.floor(Date.now() / 1000);
  if (ws.data.segundo !== ahora) {
    ws.data.segundo = ahora;
    ws.data.bytes = 0;
  }
  ws.data.bytes += bytes;
  return ws.data.bytes <= MAX_POR_SEGUNDO;
}

const servidor = Bun.serve<Conexion, never>({
  port: PUERTO,
  fetch(peticion, srv) {
    const ruta = new URL(peticion.url).pathname;
    if (ruta === "/salud") return Response.json({ ok: true, salas: salas.size });
    if (srv.upgrade(peticion, { data: { sala: null, asiento: 0, bytes: 0, segundo: 0 } })) return undefined;
    return new Response("La casa siempre gana: relé del cooperativo online.\n", { status: 200 });
  },
  websocket: {
    maxPayloadLength: MAX_MENSAJE,
    idleTimeout: 120, // segundos sin tráfico; el juego manda un eco cada pocos segundos
    message(ws, mensaje) {
      if (typeof mensaje === "string") {
        const orden = leerOrden(mensaje);
        if (orden === null) decir(ws, { t: "error", motivo: "peticion" });
        else alRecibirOrden(ws, orden);
        return;
      }
      if (!pasaElTope(ws, mensaje.byteLength)) {
        ws.close(1008, "demasiado tráfico");
        return;
      }
      const otro = elOtro(ws);
      if (otro !== null && otro.ws !== null) otro.ws.sendBinary(mensaje);
    },
    close(ws) {
      alCortarse(ws);
    },
  },
});

// Ni los sitios guardados ni las salas olvidadas se quedan para siempre.
setInterval(() => {
  const ahora = Date.now();
  for (const sala of [...salas.values()]) {
    for (const cual of [1, 0] as const) {
      const asiento = sala.asientos[cual];
      if (asiento !== null && asiento.ws === null && ahora - asiento.fuera > GRACIA_MS) vaciarAsiento(sala, cual);
    }
    if (!salas.has(sala.codigo)) continue;
    const vieja = ahora - sala.creada;
    if (vieja > SALA_MAX_MS || (sala.asientos[1] === null && vieja > SALA_VACIA_MS)) {
      sala.asientos[1]?.ws?.close(1000, "sala caducada");
      sala.asientos[0].ws?.close(1000, "sala caducada");
      if (salas.has(sala.codigo)) vaciarAsiento(sala, 0);
    }
  }
}, Math.max(Math.min(GRACIA_MS / 4, 5000), 100));

console.log(`relé escuchando en :${servidor.port}`);
