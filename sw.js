const CACHE = 'dks-v4';

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
  // Datafiler (dks_turne_data.json, dks_program_data_*.json,
  // dks_historikk_transport.json) vert oppdaterte jamleg av
  // hent_dks_data.ps1/dks_hent_historikk_transport.py — dei må ALLTID
  // hentast ferskt, same prinsipp som HTML. RETTA 01.09.2026: desse låg
  // tidlegare i cache-first-greina under (kun meint for ikon/manifest),
  // som gjorde at denne service workeren — sjølv om han berre vert
  // REGISTRERT frå dks_program.html — kontrollerte ALLE sider på same
  // opphav (inkl. transport_enkeltsok-8-2.html, som ikkje registrerer
  // nokon SW sjølv) og cacha turnédataen for alltid ved fyrste treff.
  // manifest.json er unnateke — reelt statisk PWA-shell-asset.
  const isDataJSON = url.pathname.endsWith('.json') && !url.pathname.endsWith('manifest.json');

  if (isHTML || isDataJSON) {
    // Network-first: tving henting frå server (ikkje HTTP-cache)
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
