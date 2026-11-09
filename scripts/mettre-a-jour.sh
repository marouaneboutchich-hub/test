#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════════════════════
# MISE À JOUR : récupère les derniers commits de la branche suivie (.procab-branche) dans les trois
# dépôts du produit, applique les migrations NOUVELLES (sans effacer les données), reconstruit l'API
# et le frontend, puis redémarre. À lancer après chaque livraison de Claude sur la branche.
# Si la base a été construite depuis une autre branche, le script s'arrête et indique la
# réinitialisation à faire.
# ════════════════════════════════════════════════════════════════════════════════════════════
set -euo pipefail
source "$(dirname "$0")/lib.sh"
info "Mise à jour sur la branche $PROCAB_BRANCH"
for depot in "${PROCAB_REPOS[@]}"; do
  [ -d "$PROCAB_DIR/$depot/.git" ] && info "$depot : actuellement $(git -C "$PROCAB_DIR/$depot" rev-parse --short HEAD)"
done
bash "$RACINE/scripts/installer.sh"
