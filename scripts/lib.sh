# shellcheck shell=bash
# ════════════════════════════════════════════════════════════════════════════════════════════
# Bibliothèque commune des scripts de l'environnement de test ProCab (sourcée, jamais exécutée).
#
# ⚠️ Aucun `set -x` dans ces scripts : le jeton de clonage et le mot de passe de démonstration
# passent par l'environnement, et une trace les imprimerait dans le journal du codespace.
# ════════════════════════════════════════════════════════════════════════════════════════════

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROCAB_DIR="$RACINE/procab"          # copies de travail des trois dépôts (ignorées par git)
LOCAL_DIR="$RACINE/.local"           # fichiers générés : variables, certificats, journaux
mkdir -p "$LOCAL_DIR/logs"

# La branche des dépôts du PRODUIT que l'environnement sert : lue dans `.procab-branche` (une ligne),
# surchargeable ponctuellement par la variable PROCAB_BRANCH. Changer de branche : modifier le fichier,
# puis `bash scripts/reinitialiser.sh` (la base doit correspondre aux migrations de la branche).
PROCAB_BRANCH="${PROCAB_BRANCH:-$(tr -d '[:space:]' < "$RACINE/.procab-branche" 2>/dev/null)}"
PROCAB_BRANCH="${PROCAB_BRANCH:-claude/gifted-keller-b8s7ax}"
PROCAB_OWNER="anashaouzi"
PROCAB_REPOS=(procab-db procab-backend procab-frontend)

# Référence du projet Supabase de PRODUCTION. Elle n'apparaît ici que pour être REFUSÉE.
PROD_REF="yknycpdxraduiinhswnb"

# Ports INTERNES (jamais redirigés hors du codespace — cf. devcontainer.json).
PORT_PROXY=3000      # le SEUL port exposé, en visibilité privée
PORT_API=3001
PORT_NEXT=3002
PORT_PROXY_TLS=443   # écoute 127.0.0.1 uniquement : chemin du serveur Next et de l'API vers l'adresse publique
SUPABASE_API="http://127.0.0.1:54321"
SUPABASE_DB_URL="postgresql://postgres:postgres@127.0.0.1:54322/postgres"
SUPABASE_DB_CONTAINER="supabase_db_procab-test"

info()  { printf '\033[1;34m[procab-test]\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m[procab-test] ✔\033[0m %s\n' "$*"; }
echec() { printf '\033[1;31m[procab-test] ✘ %s\033[0m\n' "$*" >&2; exit 1; }

# Exécute avec sudo seulement si on n'est pas déjà root (root dans cette session d'essai, `node` en codespace).
privilege() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }

pnpm_() { npx -y pnpm@9.12.0 "$@"; }
supabase_() { (cd "$RACINE" && npx --no-install supabase "$@"); }

# ── Adresse publique ───────────────────────────────────────────────────────────────────────
# En codespace : https://<nom>-3000.<domaine de redirection>. Hors codespace (essai local), on exige
# une adresse explicite plutôt que d'en deviner une.
hote_public() {
  if [ -n "${PROCAB_PUBLIC_HOST:-}" ]; then
    printf '%s' "$PROCAB_PUBLIC_HOST"
  elif [ -n "${CODESPACE_NAME:-}" ] && [ -n "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]; then
    printf '%s-%s.%s' "$CODESPACE_NAME" "$PORT_PROXY" "$GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN"
  else
    echec "Adresse publique inconnue : hors codespace, définir PROCAB_PUBLIC_HOST (ex. essai-local-3000.app.github.dev)."
  fi
}

# ── Gardes ─────────────────────────────────────────────────────────────────────────────────
# Refuse toute valeur qui désignerait la production ou une machine distante. Appelée avant chaque
# démarrage de l'API et avant chaque écriture en base. Elle ne fait confiance à aucune variable
# héritée : elle relit ce qui va RÉELLEMENT être utilisé.
garde_locale() {
  local nom="$1" valeur="$2"
  case "$valeur" in
    *"$PROD_REF"*) echec "GARDE : $nom désigne le projet de PRODUCTION ($PROD_REF). Arrêt." ;;
    *supabase.co*|*supabase.com*|*pooler.supabase*) echec "GARDE : $nom désigne un Supabase HÉBERGÉ ($valeur). Seul le Supabase local est permis." ;;
  esac
}

garde_base_locale() {
  local url="$1"
  garde_locale DATABASE_URL "$url"
  case "$url" in
    postgres://*@127.0.0.1:*|postgresql://*@127.0.0.1:*|postgres://*@localhost:*|postgresql://*@localhost:*) ;;
    *) echec "GARDE : DATABASE_URL ne vise pas une base locale. Arrêt." ;;
  esac
}

# Variables de production qui ne doivent JAMAIS exister dans ce codespace (secrets mal rangés).
garde_environnement() {
  local v
  for v in RESEND_API_KEY SENTRY_DSN NEXT_PUBLIC_SENTRY_DSN UPSTASH_REDIS_URL UPSTASH_REDIS_TOKEN; do
    if [ -n "${!v:-}" ]; then
      echec "GARDE : la variable $v est définie dans le codespace. Elle n'a rien à faire ici (aucun envoi, aucun service externe) : retirez-la des secrets Codespaces."
    fi
  done
  garde_locale SUPABASE_URL "${SUPABASE_URL:-}"
  garde_locale DATABASE_URL "${DATABASE_URL:-}"
}

attendre() { # attendre <description> <secondes> <commande...>
  local quoi="$1" max="$2"; shift 2
  local i
  for ((i = 0; i < max; i++)); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  echec "Délai dépassé en attendant : $quoi"
}

# ── Adresse publique → proxy local ─────────────────────────────────────────────────────────
# ⚠️ Docker RÉÉCRIT /etc/hosts à chaque démarrage du conteneur : l'entrée posée à l'installation
# disparaît au premier redémarrage du codespace. Elle se repose donc à CHAQUE démarrage. Sans elle,
# le serveur Next et l'API joignent l'adresse publique par le tunnel GitHub (port privé), qui répond
# 302 vers la connexion GitHub : la session n'est jamais reconnue et l'écran revient au login.
assurer_hosts() {
  local hote="$1"
  if ! grep -qE "^127\.0\.0\.1[[:space:]]+$hote\$" /etc/hosts; then
    echo "127.0.0.1 $hote" | privilege tee -a /etc/hosts >/dev/null
  fi
}

# Vrai seulement si l'adresse publique se RÉSOUT vers 127.0.0.1 ET que Supabase local répond 200
# par le proxy. Un 302 (tunnel GitHub) ou tout autre code est un ÉCHEC : `curl -f` acceptait les
# redirections et laissait passer exactement la panne qu'il devait voir.
chemin_interne_ok() {
  local hote="$1" cacert="$2"
  getent hosts "$hote" | grep -q '^127\.0\.0\.1[[:space:]]' || return 1
  [ "$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --cacert "$cacert" "https://$hote/auth/v1/health" -H 'apikey: x')" = "200" ]
}

