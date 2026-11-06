// ════════════════════════════════════════════════════════════════════════════════════════════
// PROXY de l'environnement de test ProCab — le SEUL point d'entrée exposé du codespace.
//
//   :3000 (HTTP, port Codespaces PRIVÉ)    ← navigateur, via le tunnel authentifié de GitHub
//   :443  (HTTPS, 127.0.0.1 seulement)     ← serveur Next et API, qui joignent la MÊME adresse publique
//                                            (/etc/hosts la résout vers 127.0.0.1 dans le codespace)
//
// Aiguillage par chemin :
//   /v1/*, /health                         → API Fastify      127.0.0.1:3001
//   /auth/v1, /rest/v1, /storage/v1,
//   /realtime/v1 (WebSocket), /graphql/v1  → Supabase local   127.0.0.1:54321
//   tout le reste                          → Next.js          127.0.0.1:3002
//
// L'API et Supabase ne sont donc JAMAIS joignables directement de l'extérieur : leurs ports ne sont
// pas redirigés (devcontainer.json), et seul ce proxy les relaie, derrière l'authentification
// GitHub du port 3000.
// ════════════════════════════════════════════════════════════════════════════════════════════
import { readFileSync } from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import httpProxy from 'http-proxy';

const HOTE = process.env.PROCAB_HOTE;
const CERTS = process.env.PROCAB_CERTS;
if (!HOTE || !CERTS) {
  console.error('[proxy] PROCAB_HOTE et PROCAB_CERTS sont requis.');
  process.exit(1);
}

const CIBLES = {
  api: 'http://127.0.0.1:3001',
  supabase: 'http://127.0.0.1:54321',
  next: 'http://127.0.0.1:3002',
};
const PREFIXES_SUPABASE = ['/auth/v1', '/rest/v1', '/storage/v1', '/realtime/v1', '/graphql/v1'];

function cible(url = '/') {
  if (url === '/health' || url.startsWith('/health?') || url === '/v1' || url.startsWith('/v1/')) return CIBLES.api;
  if (PREFIXES_SUPABASE.some((p) => url === p || url.startsWith(`${p}/`) || url.startsWith(`${p}?`))) return CIBLES.supabase;
  return CIBLES.next;
}

// `xfwd` : X-Forwarded-For/Proto/Host. L'en-tête Host est réécrit vers l'adresse PUBLIQUE pour Next :
// ses redirections (`new URL('/login', request.url)`) doivent viser l'adresse que voit le navigateur,
// quelle que soit la façon dont le tunnel de Codespaces présente la requête.
const proxy = httpProxy.createProxyServer({ ws: true, xfwd: true, proxyTimeout: 600_000, timeout: 600_000 });

proxy.on('proxyReq', (proxyReq, req) => {
  proxyReq.setHeader('x-forwarded-proto', 'https');
  proxyReq.setHeader('x-forwarded-host', HOTE);
  if (cible(req.url) === CIBLES.next) proxyReq.setHeader('host', HOTE);
});

// Next construit ses redirections ABSOLUES (middleware : `new URL('/portail/dashboard', request.url)`)
// à partir de son adresse d'écoute interne (`localhost:3002`), et non de l'adresse publique. En
// production, Vercel fait cette traduction ; ici, c'est le rôle du proxy : toute redirection qui vise
// une adresse interne est ramenée à l'adresse publique, en gardant le chemin.
const INTERNE = /^https?:\/\/(localhost|127\.0\.0\.1|0\.0\.0\.0)(:\d+)?(?=\/|$)/;
proxy.on('proxyRes', (proxyRes) => {
  for (const entete of ['location', 'x-middleware-rewrite', 'x-nextjs-redirect']) {
    const v = proxyRes.headers[entete];
    if (typeof v === 'string' && INTERNE.test(v)) proxyRes.headers[entete] = v.replace(INTERNE, `https://${HOTE}`);
  }
});

proxy.on('error', (err, req, res) => {
  const message = `[proxy] ${req.method} ${req.url} → ${cible(req.url)} : ${err.code ?? err.message}`;
  console.error(message);
  if (res && 'writeHead' in res && !res.headersSent) {
    res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' });
    res.end('Service local indisponible (démarrage en cours ?). Voir .local/logs/.\n');
  } else if (res && 'destroy' in res) {
    res.destroy();
  }
});

function gerer(req, res) {
  proxy.web(req, res, { target: cible(req.url) });
}
function gererUpgrade(req, socket, head) {
  proxy.ws(req, socket, head, { target: cible(req.url) });
}

const enClair = http.createServer(gerer);
enClair.on('upgrade', gererUpgrade);
enClair.listen(3000, '0.0.0.0', () => console.log(`[proxy] http://0.0.0.0:3000 → ${HOTE}`));

const chiffre = https.createServer(
  { key: readFileSync(`${CERTS}/serveur.key`), cert: readFileSync(`${CERTS}/serveur.crt`) },
  gerer,
);
chiffre.on('upgrade', gererUpgrade);
chiffre.listen(443, '127.0.0.1', () => console.log(`[proxy] https://${HOTE} (127.0.0.1:443, interne)`));
