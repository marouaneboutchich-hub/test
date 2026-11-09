#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════════════════════
# Applique procab-db/sql/ sur le Postgres du Supabase LOCAL, dans l'ordre des numéros — de façon
# INCRÉMENTALE : la liste des fichiers déjà appliqués est tenue dans .local/migrations-appliquees.liste.
#
#   · base vierge            → toutes les migrations ;
#   · base déjà construite   → seulement les fichiers NOUVEAUX de la branche (ceux que Claude vient de
#                              pousser), sans toucher aux données ;
#   · base DIVERGENTE        → un fichier appliqué n'existe plus dans la branche suivie (changement de
#                              branche, migration renommée) : arrêt, avec la commande de réinitialisation.
#                              Rejouer par-dessus une base qui porte le schéma d'une AUTRE branche donnerait
#                              un état qu'aucune base réelle n'a jamais eu.
#
# Même règle que la CI « Rejeu du schéma » de procab-db : un fichier dont la PREMIÈRE ligne porte
# `@rejeu: ignorer` est une opération ponctuelle sur des données de production — il est SAUTÉ.
# Aucun substitut n'est nécessaire : le Supabase local fournit auth.jwt(), storage.* et les rôles.
# ════════════════════════════════════════════════════════════════════════════════════════════
set -euo pipefail
source "$(dirname "$0")/lib.sh"

psql_local() { docker exec -i "$SUPABASE_DB_CONTAINER" psql -U postgres -d postgres -X -q -v ON_ERROR_STOP=1 "$@"; }

docker inspect "$SUPABASE_DB_CONTAINER" >/dev/null 2>&1 || echec "Conteneur $SUPABASE_DB_CONTAINER absent : Supabase local n'est pas démarré."

LISTE="$LOCAL_DIR/migrations-appliquees.liste"
SQL_DIR="$PROCAB_DIR/procab-db/sql"
base_construite="$(psql_local -tAc "select to_regclass('public.tenants') is not null")"

if [ "$base_construite" = "t" ] && [ ! -f "$LISTE" ]; then
  echec "La base contient déjà des tables mais aucune liste de migrations appliquées (installation interrompue, ou installation antérieure à la mise à jour incrémentale). Repartir de zéro : bash scripts/reinitialiser.sh"
fi

if [ "$base_construite" = "t" ]; then
  # Divergence : un fichier appliqué que la branche suivie ne contient plus.
  absents=""
  while IFS= read -r nom; do
    [ -n "$nom" ] && [ ! -f "$SQL_DIR/$nom" ] && absents="$absents $nom"
  done < "$LISTE"
  if [ -n "$absents" ]; then
    echec "La base locale porte des migrations ABSENTES de la branche $PROCAB_BRANCH :$absents. Elle a été construite depuis une autre branche. Repartir de zéro (données de démonstration recréées) : bash scripts/reinitialiser.sh"
  fi
else
  : > "$LISTE"
  # ── Préparation de la PLATEFORME (pas une migration), une seule fois sur base vierge ────────
  # Le Supabase LOCAL pose, pour le rôle `supabase_admin`, des droits PAR DÉFAUT qui accordent
  # tables, séquences et fonctions futures de `public` à `anon` et `authenticated`. La migration 0134
  # retire ces droits et son contrôle REFUSE de conclure tant qu'il en reste ; or seul `supabase_admin`
  # peut modifier ses propres droits par défaut, et les migrations s'exécutent en `postgres`, comme en
  # production. On les retire donc ici, en `supabase_admin` — exactement le geste que 0134 attend,
  # appliqué au rôle qu'elle ne peut pas atteindre. Rien n'est assoupli : le contrôle de 0134 juge
  # ensuite l'état obtenu.
  docker exec -i "$SUPABASE_DB_CONTAINER" psql -U supabase_admin -d postgres -X -q -v ON_ERROR_STOP=1 <<'SQL'
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public REVOKE ALL ON TABLES    FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM anon, authenticated;
SQL
  ok "Plateforme préparée : droits par défaut de supabase_admin retirés à anon / authenticated"
fi

joues=0; sautes=0
for f in "$SQL_DIR"/*.sql; do
  nom="$(basename "$f")"
  if head -1 "$f" | grep -q '@rejeu: ignorer'; then
    sautes=$((sautes + 1))
    [ "$base_construite" = "t" ] || info "SAUTÉ  $nom — $(head -1 "$f" | sed 's/.*ignorer — //' | cut -c1-110)"
    continue
  fi
  grep -qxF "$nom" "$LISTE" && continue
  [ "$base_construite" = "t" ] && info "NOUVELLE migration : $nom"
  if ! psql_local < "$f" >"$LOCAL_DIR/logs/migration-courante.log" 2>&1; then
    cat "$LOCAL_DIR/logs/migration-courante.log" >&2
    echec "La migration $nom échoue sur le Supabase local (journal ci-dessus). Les migrations précédentes restent appliquées ; celle-ci a été annulée."
  fi
  echo "$nom" >> "$LISTE"
  joues=$((joues + 1))
done

# ── Complément de schéma : ce que la PRODUCTION a et que le dépôt ne crée pas ────────────────
# `mission_members.planned_start` / `planned_end` existent en production et sont lues par le backend,
# mais aucune migration ne les créait avant 0158 (branche de développement). Sur une branche qui n'a
# pas 0158 (dont `main`), une base reconstruite depuis sql/ ne les aurait pas, et toute lecture des
# membres d'une mission échouerait. On les crée donc, telles qu'en production — idempotent, sans
# effet quand 0158 est présente. À retirer dès que 0158 est sur toutes les branches suivies.
psql_local <<'SQL'
ALTER TABLE mission_members ADD COLUMN IF NOT EXISTS planned_start date;
ALTER TABLE mission_members ADD COLUMN IF NOT EXISTS planned_end   date;
SQL

tables="$(psql_local -tAc "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r'")"
sans_rls="$(psql_local -tAc "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r' and not c.relrowsecurity")"
bucket="$(psql_local -tAc "select count(*) from storage.buckets where id='documents'")"
[ "$tables" -gt 0 ] || echec "Aucune table construite."
[ "$bucket" = "1" ] || echec "Le bucket de stockage « documents » n'existe pas après les migrations."
echo "procab-db @ $(git -C "$PROCAB_DIR/procab-db" rev-parse --short HEAD) ($PROCAB_BRANCH), $(wc -l < "$LISTE") migrations appliquées, $(date -u +%FT%TZ)" > "$LOCAL_DIR/migrations-appliquees"
if [ "$joues" -eq 0 ] && [ "$base_construite" = "t" ]; then
  ok "Schéma à jour : aucune nouvelle migration — $tables tables, $sans_rls sans RLS"
else
  ok "Migrations : $joues appliquées maintenant, $sautes opérations sautées — $tables tables, $sans_rls sans RLS, bucket « documents » présent"
fi
