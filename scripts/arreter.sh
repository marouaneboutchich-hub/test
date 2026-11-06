#!/usr/bin/env bash
# Arrête le proxy, le frontend et l'API ; avec --tout, arrête aussi Supabase local (les données
# restent dans les volumes Docker et reviennent au prochain démarrage).
set -uo pipefail
source "$(dirname "$0")/lib.sh"

for nom in proxy web api; do
  f="$LOCAL_DIR/pids/$nom"
  if [ -f "$f" ]; then
    privilege kill "$(cat "$f")" 2>/dev/null || true
    rm -f "$f"
  fi
done
# Filet : un processus orphelin d'un démarrage précédent garderait le port.
privilege pkill -f "$RACINE/scripts/proxy.mjs" 2>/dev/null || true
pkill -f "next start -p $PORT_NEXT" 2>/dev/null || true
pkill -f "dist/instrument.js dist/server.js" 2>/dev/null || true
ok "Proxy, frontend et API arrêtés"

if [ "${1:-}" = "--tout" ]; then
  supabase_ stop >/dev/null 2>&1 && ok "Supabase local arrêté (données conservées)"
fi
