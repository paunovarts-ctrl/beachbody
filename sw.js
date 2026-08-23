/* Beach Body Map — service worker.
   The app keeps all of its data in localStorage, so once the shell is cached
   the whole thing runs with no signal at all. That matters: the staff using
   this are standing on sand, and Materada does not have reliable coverage.   */

const VERSION = 'bbm-v2';
const SHELL   = VERSION + '-shell';

/* Everything needed to cold-start the app with the network switched off. */
const PRECACHE = [
  './',
  './index.html',
  './manifest.webmanifest',
  './assets/beach.jpg',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './icons/maskable-192.png',
  './icons/maskable-512.png',
  './icons/apple-touch-icon.png',
  './icons/favicon-32.png',
  './icons/favicon-16.png'
];

self.addEventListener('install', event => {
  event.waitUntil((async () => {
    const cache = await caches.open(SHELL);
    /* Added one at a time: a single 404 in addAll() throws away the whole
       install, and a missing icon should not cost us an offline app. */
    await Promise.all(PRECACHE.map(async url => {
      try {
        const res = await fetch(new Request(url, { cache: 'reload' }));
        if (res.ok) await cache.put(url, res);
      } catch (e) { /* offline at install time — runtime caching will catch it */ }
    }));
    /* Take over as soon as the new shell is cached, rather than sitting in
       "waiting" until every tab is closed. There is no update prompt to release
       it any more, and the page being replaced has already loaded its own code,
       so nothing changes underneath anyone mid-shift — the new version is
       simply what starts the next time the app is opened. */
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter(k => k !== SHELL).map(k => caches.delete(k)));
    if (self.registration.navigationPreload) {
      await self.registration.navigationPreload.enable();
    }
    await self.clients.claim();
  })());
});

const isNav = req =>
  req.mode === 'navigate' ||
  (req.method === 'GET' && (req.headers.get('accept') || '').includes('text/html'));

self.addEventListener('fetch', event => {
  const req = event.request;
  if (req.method !== 'GET') return;

  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;   // never touch cross-origin

  /* Navigations: network first, so a redeploy is picked up on the next launch,
     but fall straight back to the cached shell when there is no signal. */
  if (isNav(req)) {
    event.respondWith((async () => {
      try {
        const preload = await event.preloadResponse;
        const res = preload || await fetch(req);
        const cache = await caches.open(SHELL);
        cache.put('./index.html', res.clone());
        return res;
      } catch (e) {
        const cache = await caches.open(SHELL);
        return (await cache.match('./index.html')) ||
               (await cache.match('./')) ||
               new Response('Offline and nothing cached yet.', {
                 status: 503, headers: { 'Content-Type': 'text/plain' }
               });
      }
    })());
    return;
  }

  /* Everything else (the drone photo, icons): cache first. These are content
     addressed by the release, so a stale hit is always the right answer. */
  event.respondWith((async () => {
    const cache = await caches.open(SHELL);
    const hit = await cache.match(req);
    if (hit) return hit;
    try {
      const res = await fetch(req);
      if (res.ok && res.type === 'basic') cache.put(req, res.clone());
      return res;
    } catch (e) {
      return new Response('', { status: 504 });
    }
  })());
});
