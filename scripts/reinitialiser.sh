#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════════════════════
# RÉINITIALISATION : base locale VIDÉE puis reconstruite (migrations + données de démonstration).
# Agit UNIQUEMENT sur le Supabase local du codespace (garde vérifiée avant toute action).
# Usage : bash scripts/reinitialiser.sh            (demande confirmation)
#         bash scripts/reinitialiser.sh --oui      (sans question)
# ════════════════════════════════════════════════════════════════════════════════════════════
set -euo pipefail
source "$(dirname "$0")/lib.sh"

garde_environnement
garde_base_locale "$SUPABASE_DB_URL"
docker inspect "$SUPABASE_DB_CONTAINER" >/dev/null 2>&1 || echec "Supabase local n'est pas démarré."

if [ "${1:-}" != "--oui" ]; then
  read -r -p "Effacer TOUTES les données du Supabase LOCAL de ce codespace et resemer ? [o/N] " r
  [ "$r" = "o" ] || [ "$r" = "O" ] || { info "Abandon."; exit 0; }
fi

# L'accès aux dépôts se vérifie AVANT d'effacer : sinon la base est vidée et rien ne la reconstruit.
verifier_acces_depots
bash "$RACINE/scripts/arreter.sh" >/dev/null 2>&1 || true
info "Remise à zéro de la base locale (schéma, comptes Auth et fichiers)"
supabase_ db reset --local --no-seed >"$LOCAL_DIR/logs/db-reset.log" 2>&1 \
  || echec "Échec de la remise à zéro — voir $LOCAL_DIR/logs/db-reset.log"
# `db reset` ne vide pas le stockage objet : on retire les fichiers déposés lors des essais.
docker exec -i "$SUPABASE_DB_CONTAINER" psql -U supabase_admin -d postgres -X -q -c "delete from storage.objects" >/dev/null 2>&1 || true
rm -f "$LOCAL_DIR/migrations-appliquees" "$LOCAL_DIR/migrations-appliquees.liste"

# L'installateur remet le code sur la branche suivie (.procab-branche), applique les migrations sur la
# base vierge, reconstruit, redémarre et resème : la base correspond alors exactement à la branche.
bash "$RACINE/scripts/installer.sh"
ok "Réinitialisation terminée"
