const CACHE = 'dks-v2';

// Berre statiske assets i cache-shell – ikkje HTML
const SHELL = ['manifest.json', 'dks-icon.svg'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)));
  self.skipWaiting(); // ta over med ein gong, ikkje vent på at faner lukkas
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(ks =>
      Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))
    )
  );
  self.clients.claim(); // kontroller eksisterande faner straks
});

self.addEventListener('fetch', e => {
  if (new URL(e.request.url).origin !== self.location.origin) return;

  const url = new URL(e.request.url);
  const isHTML = url.pathname.endsWith('.html') || url.pathname === '/';

  if (isHTML) {
    // Network-first for HTML: tving henting frå server (ikkje HTTP-cache)
    e.respondWith(
      fetch(new Request(e.request, {cache: 'reload'}))
        .then(res => {
          if (res.ok) caches.open(CACHE).then(c => c.put(e.request, res.clone()));
          return res;
        })
        .catch(() => caches.match(e.request))
    );
  } else {
    // Cache-first for statiske assets (ikon, manifest)
    e.respondWith(
      caches.match(e.request).then(cached =>
        cached || fetch(e.request).then(res => {
          if (res.ok) caches.open(CACHE).then(c => c.put(e.request, res.clone()));
          return res;
        })
      )
    );
  }
});
