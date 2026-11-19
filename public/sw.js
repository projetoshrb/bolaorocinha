// Service worker do BOLAO ROCINHA: guarda a "casca" do app para abrir mesmo sem internet.
// Nunca guarda dados: as chamadas ao Apps Script (outro domínio, método POST) e à função de imagens passam direto.
const V = 'bolao-v1';
const CASCA = ['./', 'index.html', 'manifest.webmanifest', 'icon-192.png', 'icon-512.png', 'icon-180.png'];
self.addEventListener('install', e => {
  e.waitUntil(caches.open(V).then(c => c.addAll(CASCA)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== V).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const r = e.request, u = new URL(r.url);
  if (r.method !== 'GET' || u.origin !== location.origin || u.pathname.indexOf('/.netlify/') === 0) return;
  // Rede primeiro (assim as atualizações aparecem na hora); sem internet, usa o que está guardado.
  e.respondWith(fetch(r).then(res => {
    if (res.ok) { const cp = res.clone(); caches.open(V).then(c => c.put(r, cp)); }
    return res;
  }).catch(() => caches.match(r).then(m => m || caches.match('index.html'))));
});
