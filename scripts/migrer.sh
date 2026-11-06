#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════════════════════
# Applique procab-db/sql/ sur le Postgres du Supabase LOCAL, dans l'ordre des numéros.
#
# Même règle que la CI « Rejeu du schéma » de procab-db : un fichier dont la PREMIÈRE ligne porte
# `@rejeu: ignorer` est une opération ponctuelle sur des données de production (reprise, remise à
# zéro, semis de Cabinet_Test) — il est SAUTÉ et annoncé. Aucun substitut n'est nécessaire ici :
# le Supabase local fournit déjà auth.jwt(), storage.* et les rôles anon / authenticated.
#
# Ne s'exécute que sur une base VIERGE (pas de table `tenants`) : rejouer l'historique sur une base
# déjà construite n'a pas de sens. Pour repartir de zéro : scripts/reinitialiser.sh.
# ════════════════════════════════════════════════════════════════════════════════════════════
set -euo pipefail
source "$(dirname "$0")/lib.sh"

psql_local() { docker exec -i "$SUPABASE_DB_CONTAINER" psql -U postgres -d postgres -X -q -v ON_ERROR_STOP=1 "$@"; }

docker inspect "$SUPABASE_DB_CONTAINER" >/dev/null 2>&1 || echec "Conteneur $SUPABASE_DB_CONTAINER absent : Supabase local n'est pas démarré."

MARQUEUR="$LOCAL_DIR/migrations-appliquees"
if [ "$(psql_local -tAc "select to_regclass('public.tenants') is not null")" = "t" ]; then
  if [ -f "$MARQUEUR" ]; then
    ok "Schéma déjà en place ($(cat "$MARQUEUR")) — migrations non rejouées"
    exit 0
  fi
  echec "La base contient déjà des tables mais aucune installation complète n'est enregistrée (migration interrompue ?). Repartir de zéro : bash scripts/reinitialiser.sh"
fi

# ── Préparation de la PLATEFORME (pas une migration) ───────────────────────────────────────
# Le Supabase LOCAL pose, pour le rôle `supabase_admin`, des droits PAR DÉFAUT qui accordent
# tables, séquences et fonctions futures de `public` à `anon` et `authenticated`. La migration 0134
# retire ces droits et son contrôle REFUSE de conclure tant qu'il en reste ; or seul
# `supabase_admin` peut modifier ses propres droits par défaut, et les migrations s'exécutent en
# `postgres`, comme en production. On les retire donc ici, en `supabase_admin` — exactement le geste
# que 0134 attend, appliqué au rôle qu'elle ne peut pas atteindre. Rien n'est assoupli : le contrôle
# de 0134 s'exécute ensuite tel quel et juge l'état obtenu.
docker exec -i "$SUPABASE_DB_CONTAINER" psql -U supabase_admin -d postgres -X -q -v ON_ERROR_STOP=1 <<'SQL'
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public REVOKE ALL ON TABLES    FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM anon, authenticated;
SQL
ok "Plateforme préparée : droits par défaut de supabase_admin retirés à anon / authenticated"

joues=0; sautes=0
for f in "$PROCAB_DIR"/procab-db/sql/*.sql; do
  nom="$(basename "$f")"
  if head -1 "$f" | grep -q '@rejeu: ignorer'; then
    sautes=$((sautes + 1))
    info "SAUTÉ  $nom — $(head -1 "$f" | sed 's/.*ignorer — //' | cut -c1-110)"
    continue
  fi
  if ! psql_local < "$f" >"$LOCAL_DIR/logs/migration-courante.log" 2>&1; then
    cat "$LOCAL_DIR/logs/migration-courante.log" >&2
    echec "La migration $nom échoue sur le Supabase local (journal ci-dessus)."
  fi
  joues=$((joues + 1))
done

tables="$(psql_local -tAc "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r'")"
sans_rls="$(psql_local -tAc "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r' and not c.relrowsecurity")"
bucket="$(psql_local -tAc "select count(*) from storage.buckets where id='documents'")"
[ "$tables" -gt 0 ] || echec "Aucune table construite."
[ "$bucket" = "1" ] || echec "Le bucket de stockage « documents » n'existe pas après les migrations."
echo "procab-db @ $(git -C "$PROCAB_DIR/procab-db" rev-parse --short HEAD), $joues migrations, $(date -u +%FT%TZ)" > "$MARQUEUR"
ok "Migrations : $joues appliquées, $sautes opérations sautées — $tables tables, $sans_rls sans RLS, bucket « documents » présent"
