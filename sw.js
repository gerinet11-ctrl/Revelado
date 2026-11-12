// Moon · service worker
// - Los archivos de la app se piden siempre a la red, sin la copia temporal del navegador: así al abrir llega
//   la última versión. Se guarda una copia para poder abrir la app sin conexión.
// - Las fuentes se guardan la primera vez y después salen de la copia.
const CACHE = "moon-v1";

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", e => e.waitUntil((async () => {
  for (const k of await caches.keys()) if (k !== CACHE) await caches.delete(k);
  await self.clients.claim();
})()));

self.addEventListener("fetch", e => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.protocol !== "http:" && url.protocol !== "https:") return;
  const own = url.origin === self.location.origin;
  const fonts = url.hostname === "fonts.googleapis.com" || url.hostname === "fonts.gstatic.com";
  if (!own && !fonts) return;

  e.respondWith((async () => {
    const cache = await caches.open(CACHE);
    const key = own ? url.origin + url.pathname : req.url;   // sin «?v=…»
    if (fonts) {
      const hit = await cache.match(key);
      if (hit) return hit;
      const res = await fetch(req);
      if (res.ok || res.type === "opaque") cache.put(key, res.clone());
      return res;
    }
    const net = fetch(url.href, { cache: "no-store" });
    try {
      // Si la red tarda más de 5 s y hay copia guardada, se abre con la copia.
      const res = await Promise.race([net, new Promise((_, rej) => setTimeout(() => rej(new Error("lenta")), 5000))]);
      if (res.ok) cache.put(key, res.clone());
      return res;
    } catch (err) {
      const hit = await cache.match(key);
      if (hit) return hit;
      return net;   // sin copia: se sigue esperando a la red
    }
  })());
});
