#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════════════════════
# DÉMARRAGE (à chaque ouverture du codespace) : Supabase local, API, frontend, proxy.
# Les services tournent en arrière-plan ; journaux dans .local/logs/, PID dans .local/pids/.
# ════════════════════════════════════════════════════════════════════════════════════════════
set -euo pipefail
source "$(dirname "$0")/lib.sh"

[ -f "$LOCAL_DIR/api.env" ] || echec "Environnement non installé : lancer d'abord scripts/installer.sh"
garde_environnement
HOTE="$(hote_public)"
ORIGINE="https://$HOTE"
if [ "$(cat "$LOCAL_DIR/origine-construite" 2>/dev/null)" != "$ORIGINE" ]; then
  echec "Le frontend a été construit pour $(cat "$LOCAL_DIR/origine-construite" 2>/dev/null || echo '?') et non pour $ORIGINE : relancer scripts/installer.sh."
fi

# Les variables de l'API sont relues et REVÉRIFIÉES ici, pas seulement à l'installation.
set -a; source "$LOCAL_DIR/api.env"; set +a
garde_base_locale "$DATABASE_URL"
garde_locale SUPABASE_URL "$SUPABASE_URL"

bash "$RACINE/scripts/arreter.sh" --services-seulement >/dev/null 2>&1 || true
mkdir -p "$LOCAL_DIR/pids"

attendre "Docker" 120 docker info
if ! supabase_ status >/dev/null 2>&1; then
  info "Démarrage de Supabase local"
  supabase_ start >>"$LOCAL_DIR/logs/supabase-start.log" 2>&1 \
    || SUPABASE_INTERNAL_IMAGE_REGISTRY=docker.io supabase_ start >>"$LOCAL_DIR/logs/supabase-start.log" 2>&1 \
    || echec "Supabase local n'a pas démarré — voir $LOCAL_DIR/logs/supabase-start.log"
fi
ok "Supabase local"

lancer() { # lancer <nom> <répertoire> <fichier env> <commande...>
  local nom="$1" dir="$2" envf="$3"; shift 3
  (
    cd "$dir"
    set -a; source "$envf"; set +a
    setsid nohup "$@" >"$LOCAL_DIR/logs/$nom.log" 2>&1 < /dev/null &
    echo $! >"$LOCAL_DIR/pids/$nom"
  )
}

lancer api "$PROCAB_DIR/procab-backend/packages/api" "$LOCAL_DIR/api.env" \
  node --enable-source-maps --import ./dist/instrument.js dist/server.js
lancer web "$PROCAB_DIR/procab-frontend/apps/web" "$LOCAL_DIR/web.env" \
  node node_modules/next/dist/bin/next start -p "$PORT_NEXT" -H 127.0.0.1

# Le proxy écoute aussi sur 443 (127.0.0.1) : il faut le droit d'ouvrir un port < 1024.
privilege env PROCAB_HOTE="$HOTE" PROCAB_CERTS="$LOCAL_DIR/certs" \
  setsid nohup "$(command -v node)" "$RACINE/scripts/proxy.mjs" >"$LOCAL_DIR/logs/proxy.log" 2>&1 < /dev/null &
echo $! >"$LOCAL_DIR/pids/proxy"

attendre "API (port $PORT_API)" 90 curl -sf --noproxy "*" "http://127.0.0.1:$PORT_API/health"
attendre "frontend (port $PORT_NEXT)" 90 curl -sf --noproxy "*" -o /dev/null "http://127.0.0.1:$PORT_NEXT/login"
attendre "proxy (port $PORT_PROXY)" 30 curl -sf --noproxy "*" -o /dev/null "http://127.0.0.1:$PORT_PROXY/login"
# Le chemin INTERNE (serveur Next et API → adresse publique) doit fonctionner, avec le certificat local.
attendre "chemin interne https://$HOTE" 30 curl -sf --noproxy "*" --cacert "$LOCAL_DIR/certs/ac.crt" "$ORIGINE/auth/v1/health" -H "apikey: x"

ok "API, frontend et proxy démarrés"
info "Ouvrir : $ORIGINE   (onglet PORTS de VS Code → « ProCab (test) », port 3000, visibilité Privée)"
