#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════════════════════
# INSTALLATION de l'environnement de test ProCab (lancé une fois, à la création du codespace).
#
#   1. gardes            — aucune variable de production dans le codespace
#   2. clonage           — les trois dépôts, branche de développement, jeton en lecture seule
#   3. adresse publique  — /etc/hosts + certificat local (le serveur Next et l'API passent par le proxy)
#   4. Supabase local    — Postgres 15, Auth, Storage, Realtime, dans Docker
#   5. migrations        — procab-db/sql/ dans l'ordre, sans les opérations marquées `@rejeu: ignorer`
#   6. dépendances       — pnpm install --frozen-lockfile, construction de l'API et du frontend
#   7. démarrage + semis — scripts/demarrer.sh puis scripts/semer.mjs (si DEMO_PASSWORD est fourni)
#
# Rejouable : chaque étape saute ce qui est déjà fait. Rien ici ne touche un service distant
# autre que GitHub (lecture des dépôts), les registres de paquets et les registres d'images Docker.
# ════════════════════════════════════════════════════════════════════════════════════════════
set -euo pipefail
source "$(dirname "$0")/lib.sh"

# ── 1. Gardes ──────────────────────────────────────────────────────────────────────────────
garde_environnement
HOTE="$(hote_public)"
ORIGINE="https://$HOTE"
garde_locale "adresse publique" "$ORIGINE"
info "Adresse de l'environnement : $ORIGINE"

# ── 2. Clonage ─────────────────────────────────────────────────────────────────────────────
# Le jeton (secret Codespaces PROCAB_REPOS_TOKEN, fine-grained, lecture seule, 3 dépôts) est remis à
# git par un « credential helper » qui le LIT dans l'environnement au moment de la requête : il
# n'est jamais écrit dans une URL, dans .git/config, ni dans le journal. `credential.helper=` (vide)
# en premier écarte l'assistant propre à Codespaces, dont le jeton ne couvre que ce dépôt-ci.
git_procab() {
  if [ -n "${PROCAB_REPOS_TOKEN:-}" ]; then
    # shellcheck disable=SC2016  # le $ doit rester littéral : c'est le shell de l'assistant qui le lit
    git -c credential.helper= \
        -c 'credential.helper=!f() { test "$1" = get || exit 0; echo username=x-access-token; echo "password=${PROCAB_REPOS_TOKEN}"; }; f' \
        "$@"
  else
    git "$@"
  fi
}

mkdir -p "$PROCAB_DIR"
: > "$LOCAL_DIR/branches-suivies"
for depot in "${PROCAB_REPOS[@]}"; do
  cible="$PROCAB_DIR/$depot"
  url="https://github.com/$PROCAB_OWNER/$depot"
  # La branche suivie n'existe peut-être pas ENCORE dans ce dépôt (elle naît au premier push de
  # développement, et un lot peut ne toucher qu'un dépôt) : on suit alors `main`, en le disant.
  # Un refus d'ACCÈS, lui, n'est pas une branche absente : il arrête tout.
  if git_procab ls-remote --exit-code --heads "$url" "$PROCAB_BRANCH" >/dev/null 2>&1; then
    branche="$PROCAB_BRANCH"
  elif git_procab ls-remote --exit-code --heads "$url" main >/dev/null 2>&1; then
    branche="main"
    info "$depot : la branche $PROCAB_BRANCH n'existe pas encore sur GitHub — on suit main (identique à la production)"
  else
    echec "$depot : dépôt inaccessible. Vérifier l'accès : secret PROCAB_REPOS_TOKEN, ou connexion « gh auth login » puis export PROCAB_REPOS_TOKEN=\"\$(gh auth token)\"."
  fi
  if [ -d "$cible/.git" ]; then
    git_procab -C "$cible" fetch --quiet --depth 1 origin "$branche" \
      || echec "$depot : impossible de récupérer $branche."
    git -C "$cible" checkout --quiet --detach FETCH_HEAD
  else
    info "$depot : clonage de $branche"
    git_procab clone --quiet --depth 1 --branch "$branche" --single-branch "$url" "$cible" \
      || echec "$depot : clonage refusé (accès : secret PROCAB_REPOS_TOKEN ou « gh auth login »)."
  fi
  echo "$depot $branche $(git -C "$cible" rev-parse --short HEAD)" >> "$LOCAL_DIR/branches-suivies"
  ok "$depot @ $branche $(git -C "$cible" rev-parse --short HEAD)"
done

# ── 3. Adresse publique : /etc/hosts + certificat local ────────────────────────────────────
# Le navigateur joint l'adresse publique par le tunnel de Codespaces (port 3000, privé). Le serveur
# Next et l'API, eux, doivent joindre LA MÊME adresse (elle est inscrite dans les variables
# NEXT_PUBLIC_* et dans SUPABASE_URL) : depuis l'intérieur du codespace, elle est donc résolue vers
# 127.0.0.1, où le proxy écoute aussi en HTTPS avec un certificat signé par une autorité LOCALE,
# reconnue des seuls processus Node lancés ici (NODE_EXTRA_CA_CERTS).
assurer_hosts "$HOTE"
ok "/etc/hosts : $HOTE → 127.0.0.1 (dans le codespace seulement)"

CERTS="$LOCAL_DIR/certs"
mkdir -p "$CERTS"
if [ ! -f "$CERTS/serveur.crt" ] || ! openssl x509 -in "$CERTS/serveur.crt" -noout -ext subjectAltName 2>/dev/null | grep -q "$HOTE"; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 825 -subj "/CN=ProCab test - autorite locale" \
    -keyout "$CERTS/ac.key" -out "$CERTS/ac.crt" >/dev/null 2>&1
  openssl req -newkey rsa:2048 -nodes -subj "/CN=$HOTE" -keyout "$CERTS/serveur.key" -out "$CERTS/serveur.csr" >/dev/null 2>&1
  printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$HOTE" > "$CERTS/ext.cnf"
  openssl x509 -req -in "$CERTS/serveur.csr" -CA "$CERTS/ac.crt" -CAkey "$CERTS/ac.key" -CAcreateserial \
    -days 825 -extfile "$CERTS/ext.cnf" -out "$CERTS/serveur.crt" >/dev/null 2>&1
  chmod 600 "$CERTS"/*.key
fi
ok "certificat local pour $HOTE"

# ── 4. Supabase local ──────────────────────────────────────────────────────────────────────
attendre "Docker" 120 docker info
sed "s#__PUBLIC_ORIGIN__#$ORIGINE#g" "$RACINE/supabase/config.toml.modele" > "$RACINE/supabase/config.toml"
if [ ! -d "$RACINE/node_modules/supabase" ] || [ ! -d "$RACINE/node_modules/http-proxy" ]; then
  (cd "$RACINE" && npm ci --no-audit --no-fund >/dev/null)
fi
if supabase_ status >/dev/null 2>&1; then
  ok "Supabase local déjà démarré"
else
  info "Démarrage de Supabase local (premier lancement : téléchargement des images, quelques minutes)"
  if ! supabase_ start >"$LOCAL_DIR/logs/supabase-start.log" 2>&1; then
    # Le registre par défaut de la CLI (public.ecr.aws) peut refuser un téléchargement anonyme
    # (quota). Les mêmes images officielles existent sur Docker Hub.
    info "Registre par défaut refusé ou en échec — nouvel essai depuis Docker Hub (images officielles supabase/*)"
    supabase_ stop >/dev/null 2>&1 || true
    SUPABASE_INTERNAL_IMAGE_REGISTRY=docker.io supabase_ start >>"$LOCAL_DIR/logs/supabase-start.log" 2>&1 \
      || echec "Supabase local n'a pas démarré — voir $LOCAL_DIR/logs/supabase-start.log"
  fi
  ok "Supabase local démarré"
fi
supabase_ status -o env > "$LOCAL_DIR/supabase.env" 2>/dev/null
# shellcheck disable=SC1091
ANON_KEY="$(sed -n 's/^ANON_KEY="\(.*\)"$/\1/p' "$LOCAL_DIR/supabase.env")"
SERVICE_ROLE_KEY="$(sed -n 's/^SERVICE_ROLE_KEY="\(.*\)"$/\1/p' "$LOCAL_DIR/supabase.env")"
[ -n "$ANON_KEY" ] && [ -n "$SERVICE_ROLE_KEY" ] || echec "Clés du Supabase local introuvables (supabase status)."

# ── 5. Migrations ──────────────────────────────────────────────────────────────────────────
bash "$RACINE/scripts/migrer.sh"

# ── 6. Variables, dépendances, construction ────────────────────────────────────────────────
# Fichiers de variables LOCAUX (ignorés par git). Les clés sont celles du Supabase local, générées
# par la CLI : elles ne donnent accès à rien hors de ce codespace.
SEL="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
cat > "$LOCAL_DIR/api.env" <<EOF
NODE_ENV=production
PORT=$PORT_API
APP_URL=$ORIGINE
DATABASE_URL=$SUPABASE_DB_URL
SUPABASE_URL=$ORIGINE
SUPABASE_SERVICE_ROLE_KEY=$SERVICE_ROLE_KEY
AUTH_LOCAL_JWT=on
EMAIL_FROM=test@procab.test
ANALYTICS_SALT=$SEL
NODE_EXTRA_CA_CERTS=$CERTS/ac.crt
NO_PROXY=$HOTE,127.0.0.1,localhost
no_proxy=$HOTE,127.0.0.1,localhost
EOF
cat > "$LOCAL_DIR/web.env" <<EOF
NEXT_PUBLIC_SUPABASE_URL=$ORIGINE
NEXT_PUBLIC_SUPABASE_ANON_KEY=$ANON_KEY
NEXT_PUBLIC_API_URL=$ORIGINE/v1
NEXT_PUBLIC_APP_URL=$ORIGINE
NEXT_TELEMETRY_DISABLED=1
NODE_EXTRA_CA_CERTS=$CERTS/ac.crt
NO_PROXY=$HOTE,127.0.0.1,localhost
no_proxy=$HOTE,127.0.0.1,localhost
EOF
chmod 600 "$LOCAL_DIR/api.env" "$LOCAL_DIR/web.env" "$LOCAL_DIR/supabase.env"
garde_base_locale "$SUPABASE_DB_URL"

info "Dépendances du backend (pnpm, lockfile figé)"
(cd "$PROCAB_DIR/procab-backend" && pnpm_ install --frozen-lockfile >"$LOCAL_DIR/logs/install-backend.log" 2>&1) \
  || echec "pnpm install backend — voir $LOCAL_DIR/logs/install-backend.log"
info "Construction de l'API"
(cd "$PROCAB_DIR/procab-backend" && pnpm_ build >"$LOCAL_DIR/logs/build-backend.log" 2>&1) \
  || echec "construction backend — voir $LOCAL_DIR/logs/build-backend.log"

info "Dépendances du frontend (pnpm, lockfile figé)"
(cd "$PROCAB_DIR/procab-frontend" && pnpm_ install --frozen-lockfile >"$LOCAL_DIR/logs/install-frontend.log" 2>&1) \
  || echec "pnpm install frontend — voir $LOCAL_DIR/logs/install-frontend.log"
info "Construction du frontend (next build, adresse $ORIGINE inscrite dans le bundle)"
(
  set -a; source "$LOCAL_DIR/web.env"; set +a
  cd "$PROCAB_DIR/procab-frontend/apps/web" && pnpm_ exec next build >"$LOCAL_DIR/logs/build-frontend.log" 2>&1
) || echec "construction frontend — voir $LOCAL_DIR/logs/build-frontend.log"
echo "$ORIGINE" > "$LOCAL_DIR/origine-construite"
ok "API et frontend construits"

# ── 7. Démarrage et semis ──────────────────────────────────────────────────────────────────
bash "$RACINE/scripts/demarrer.sh"
deja_seme="$(docker exec -i "$SUPABASE_DB_CONTAINER" psql -U postgres -d postgres -X -tAc "select count(*) from tenants where name = 'Fiduciaire Atlas Conseil'" 2>/dev/null || echo 0)"
if [ "$deja_seme" != "0" ]; then
  ok "Données de démonstration présentes (conservées)"
elif [ -n "${DEMO_PASSWORD:-}" ]; then
  node "$RACINE/scripts/semer.mjs"
else
  info "DEMO_PASSWORD absent : données de démonstration NON créées. Saisir le mot de passe (read -rsp \"Mot de passe démo : \" DEMO_PASSWORD && export DEMO_PASSWORD), puis : node scripts/semer.mjs"
fi
ok "Environnement de test prêt : $ORIGINE"
