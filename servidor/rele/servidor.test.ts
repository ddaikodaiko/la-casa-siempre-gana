import { afterAll, beforeAll, expect, test } from "bun:test";
import type { Subprocess } from "bun";

const PUERTO = 18080 + Math.floor(Math.random() * 1000);
let proceso: Subprocess;

beforeAll(async () => {
  proceso = Bun.spawn(["bun", "servidor.ts"], { cwd: import.meta.dir, env: { ...process.env, PORT: String(PUERTO), GRACIA_MS: "600" }, stdout: "ignore" });
  for (let i = 0; i < 50; i++) {
    try {
      if ((await fetch(`http://127.0.0.1:${PUERTO}/salud`)).ok) return;
    } catch {
      await Bun.sleep(100);
    }
  }
  throw new Error("el relé no arranca");
});

afterAll(() => proceso.kill());

type Mensaje = Record<string, unknown> | Uint8Array;

/** Un cliente de prueba: guarda lo que llega y deja esperar al siguiente mensaje. */
/** Irse a propósito: sin esto el relé guarda el sitio un rato, por si es un corte. */
function irse(c: { ws: WebSocket }): void {
  c.ws.send(JSON.stringify({ t: "salir" }));
  c.ws.close();
}

function cliente(): Promise<{ ws: WebSocket; siguiente: () => Promise<Mensaje> }> {
  return new Promise((listo) => {
    const ws = new WebSocket(`ws://127.0.0.1:${PUERTO}`);
    ws.binaryType = "arraybuffer";
    const cola: Mensaje[] = [];
    const esperando: ((m: Mensaje) => void)[] = [];
    ws.onmessage = (e) => {
      const m: Mensaje = typeof e.data === "string" ? JSON.parse(e.data) : new Uint8Array(e.data as ArrayBuffer);
      const quien = esperando.shift();
      if (quien) quien(m);
      else cola.push(m);
    };
    ws.onopen = () =>
      listo({ ws, siguiente: () => new Promise((r) => (cola.length > 0 ? r(cola.shift() as Mensaje) : esperando.push(r))) });
  });
}

test("crear, unirse y pasar binario en los dos sentidos", async () => {
  const a = await cliente();
  const b = await cliente();
  a.ws.send(JSON.stringify({ t: "crear", nombre: "ANA", version: "1.8" }));
  const sala = (await a.siguiente()) as { t: string; codigo: string };
  expect(sala.t).toBe("sala");
  expect(sala.codigo).toMatch(/^[A-Z2-9]{4}$/);

  b.ws.send(JSON.stringify({ t: "unirse", codigo: sala.codigo.toLowerCase(), nombre: "LUIS", version: "1.8" }));
  const unido = (await b.siguiente()) as { t: string; codigo: string; nombre: string; llave: string };
  expect(unido).toEqual({ t: "unido", codigo: sala.codigo, nombre: "ANA", llave: unido.llave });
  expect(unido.llave).toMatch(/^[0-9a-f]{32}$/);
  expect(await a.siguiente()).toEqual({ t: "entra", nombre: "LUIS" });

  a.ws.send(new Uint8Array([1, 2, 3]));
  expect(await b.siguiente()).toEqual(new Uint8Array([1, 2, 3]));
  b.ws.send(new Uint8Array([9]));
  expect(await a.siguiente()).toEqual(new Uint8Array([9]));

  // El invitado se va: el anfitrión se entera y la sala vuelve a estar libre.
  irse(b);
  expect(await a.siguiente()).toEqual({ t: "sale" });
  const c = await cliente();
  c.ws.send(JSON.stringify({ t: "unirse", codigo: sala.codigo, nombre: "EVA", version: "1.8" }));
  expect(((await c.siguiente()) as { t: string }).t).toBe("unido");
  expect(await a.siguiente()).toEqual({ t: "entra", nombre: "EVA" });

  // El anfitrión se va: la sala desaparece.
  irse(a);
  expect(await c.siguiente()).toEqual({ t: "sale" });
  c.ws.send(JSON.stringify({ t: "unirse", codigo: sala.codigo, nombre: "EVA", version: "1.8" }));
  expect(await c.siguiente()).toEqual({ t: "error", motivo: "no_existe" });
  c.ws.close();
});

test("sala llena, versión distinta, código inventado y petición rota", async () => {
  const a = await cliente();
  const b = await cliente();
  const c = await cliente();
  a.ws.send(JSON.stringify({ t: "crear", nombre: "ANA", version: "1.8" }));
  const { codigo } = (await a.siguiente()) as { codigo: string };

  c.ws.send(JSON.stringify({ t: "unirse", codigo, nombre: "VIEJO", version: "1.7" }));
  expect(await c.siguiente()).toEqual({ t: "error", motivo: "version" });
  c.ws.send(JSON.stringify({ t: "unirse", codigo: "ZZZZ", nombre: "X", version: "1.8" }));
  expect(await c.siguiente()).toEqual({ t: "error", motivo: "no_existe" });
  c.ws.send("esto no es json");
  expect(await c.siguiente()).toEqual({ t: "error", motivo: "peticion" });

  b.ws.send(JSON.stringify({ t: "unirse", codigo, nombre: "LUIS", version: "1.8" }));
  await b.siguiente();
  await a.siguiente();
  c.ws.send(JSON.stringify({ t: "unirse", codigo, nombre: "EVA", version: "1.8" }));
  expect(await c.siguiente()).toEqual({ t: "error", motivo: "llena" });

  c.ws.send(JSON.stringify({ t: "eco", n: 7 }));
  expect(await c.siguiente()).toEqual({ t: "eco", n: 7 });
  for (const x of [a, b, c]) irse(x);
});

test("un corte guarda el sitio: se vuelve con la llave y, si no, el otro se entera", async () => {
  const a = await cliente();
  const b = await cliente();
  a.ws.send(JSON.stringify({ t: "crear", nombre: "ANA", version: "1.9" }));
  const sala = (await a.siguiente()) as { codigo: string; llave: string };
  b.ws.send(JSON.stringify({ t: "unirse", codigo: sala.codigo, nombre: "LUIS", version: "1.9" }));
  const unido = (await b.siguiente()) as { llave: string };
  await a.siguiente(); // entra

  // Al invitado se le corta: el anfitrión espera y nadie le quita el sitio.
  b.ws.close();
  expect(await a.siguiente()).toEqual({ t: "espera" });
  const intruso = await cliente();
  intruso.ws.send(JSON.stringify({ t: "unirse", codigo: sala.codigo, nombre: "EVA", version: "1.9" }));
  expect(await intruso.siguiente()).toEqual({ t: "error", motivo: "llena" });
  intruso.ws.send(JSON.stringify({ t: "volver", codigo: sala.codigo, llave: "0".repeat(32) }));
  expect(await intruso.siguiente()).toEqual({ t: "error", motivo: "no_existe" });
  irse(intruso);

  // Vuelve con su llave y todo sigue pasando en los dos sentidos.
  const b2 = await cliente();
  b2.ws.send(JSON.stringify({ t: "volver", codigo: sala.codigo, llave: unido.llave }));
  expect(await b2.siguiente()).toEqual({ t: "vuelto", solo: false });
  expect(await a.siguiente()).toEqual({ t: "vuelve" });
  a.ws.send(new Uint8Array([4, 5]));
  expect(await b2.siguiente()).toEqual(new Uint8Array([4, 5]));

  // Al anfitrión se le corta y vuelve: la sala sigue viva.
  a.ws.close();
  expect(await b2.siguiente()).toEqual({ t: "espera" });
  const a2 = await cliente();
  a2.ws.send(JSON.stringify({ t: "volver", codigo: sala.codigo, llave: sala.llave }));
  expect(await a2.siguiente()).toEqual({ t: "vuelto", solo: false });
  expect(await b2.siguiente()).toEqual({ t: "vuelve" });

  // Se corta y no vuelve a tiempo: pasada la gracia, el otro recibe el "sale" de siempre.
  b2.ws.close();
  expect(await a2.siguiente()).toEqual({ t: "espera" });
  expect(await a2.siguiente()).toEqual({ t: "sale" });
  const tarde = await cliente();
  tarde.ws.send(JSON.stringify({ t: "volver", codigo: sala.codigo, llave: unido.llave }));
  expect(await tarde.siguiente()).toEqual({ t: "error", motivo: "no_existe" });
  irse(tarde);
  irse(a2);
});
