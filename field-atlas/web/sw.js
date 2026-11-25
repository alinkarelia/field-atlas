const CACHE='field-atlas-v14';
const FILES=['/','/index.html','/styles.css','/field-ui.css','/screen.js','/app-icon-180.png','/app-icon-192.png','/app-icon-512.png','/app.js','/core.js','/db.js','/fixtures.js','/icons.js','/forms.js','/map.js','/sync.js','/identity.js','/model-view.js','/map-navigation.js','/room-plan.js','/room-plan-core.js','/backup.js','/backup-core.js','/conflicts.js','/ceiling.js','/manifest.webmanifest'];
self.addEventListener('install',event=>event.waitUntil(caches.open(CACHE).then(c=>c.addAll(FILES))));
self.addEventListener('activate',event=>event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim())));
self.addEventListener('fetch',event=>{
  const url=new URL(event.request.url);
  if(event.request.method!=='GET'||url.origin!==self.location.origin||url.pathname.startsWith('/api/'))return;
  event.respondWith(fetch(event.request).catch(()=>caches.match(event.request).then(r=>r||new Response('Нет локальной копии',{status:503}))));
});
