# ProCab — environnement de test (GitHub Codespaces)

Un ProCab **complet et isolé**, qui tourne entièrement dans un codespace : Supabase local (Postgres 15,
authentification, stockage, temps réel), l'API et le frontend de la branche de développement
`claude/jolly-keller-orcvzj`, et un jeu de données **fictives** prêt à manipuler.

Ce dépôt ne contient que la configuration de l'environnement. Les trois dépôts du produit
(`anashaouzi/procab-db`, `procab-backend`, `procab-frontend`) sont **clonés en lecture** au démarrage ;
rien n'y est jamais écrit ni poussé.

## Ce que l'environnement garantit

| | |
|---|---|
| **Production** | Jamais touchée. Aucun identifiant de production n'est nécessaire ni admis : les scripts refusent de démarrer si une variable désigne le projet `yknycpdxraduiinhswnb`, un Supabase hébergé ou une base distante. |
| **Réseau** | Un **seul** port redirigé, le 3000, en visibilité **privée** (accessible au seul titulaire du codespace, connecté à GitHub). L'API et Supabase restent internes au codespace, derrière un proxy. |
| **E-mails** | Aucun envoi : pas de clé Resend, adresses en `.test` (domaine réservé, RFC 2606). Les messages que l'application enverrait sont seulement journalisés ; ceux de Supabase Auth sont capturés en local (Mailpit, interne). |
| **Paiements** | Aucun prestataire de paiement dans l'application : les « virements » de démonstration sont déclarés puis vérifiés dans la console de test. |
| **Données** | Entièrement fictives. Réinitialisables à tout moment. |
| **Déploiement** | Aucun : rien n'est poussé vers les dépôts du produit, donc ni Railway ni Vercel ne voient quoi que ce soit. |

## Avant de créer le codespace

### 1. Rester dans le GRATUIT

L'environnement est réglé pour la plus petite machine qui suffit : **2 cœurs / 8 Go** (`hostRequirements`).
Mesuré le 06/11 : pic de 4,5 Go de mémoire pendant l'installation, environ 1,5 Go en fonctionnement.

**Quota gratuit d'un compte personnel GitHub (par mois) :**

| Ressource | Quota gratuit | Ce que l'environnement consomme |
|---|---|---|
| Calcul | 120 heures-cœur | Machine 2 cœurs = **2 heures-cœur par heure ouverte** → environ **60 h d'utilisation par mois** |
| Stockage | 15 Go-mois | Le codespace occupe **environ 9 Go** (images Supabase ~4 Go, code et dépendances ~3 Go, construction ~1 Go). Gardé tout un mois : ~9 Go-mois ; supprimé après deux semaines : ~4,5 Go-mois |

**Pour ne JAMAIS payer :**

1. GitHub → **Settings → Billing and plans → Spending limits** (ou *Budgets*) : vérifier que la limite de
   dépense Codespaces est à **0 $**. C'est la valeur par défaut d'un compte personnel sans moyen de paiement :
   une fois le quota épuisé, les codespaces s'arrêtent, rien n'est facturé.
2. Settings → **Codespaces** → *Default idle timeout* : **30 minutes** (ou moins). Un codespace inactif
   s'arrête seul, et un codespace **arrêté ne consomme plus d'heures-cœur**.
3. Quand vous avez fini une séance : *Codespaces → ⋯ → Stop codespace* (ou fermer l'onglet et laisser
   l'arrêt automatique faire). Les données restent.
4. Quand vous n'en avez plus besoin pour plusieurs semaines : *⋯ → Delete*. Le stockage n'est compté que
   tant que le codespace existe. Le recréer plus tard refait l'installation (15-20 min) et resème des
   données neuves.
5. **Un seul codespace à la fois** : deux codespaces doublent le stockage (2 × 9 Go dépasse le quota).
6. Suivre la consommation : Settings → **Billing and plans → Usage** (Codespaces : heures-cœur et Go-mois).

> Les chiffres de quota sont ceux du forfait GitHub Free connus à ce jour : les vérifier sur la page de
> facturation de votre compte, qui fait foi.

### 2. Créer les deux secrets Codespaces

GitHub → **Settings → Codespaces → Secrets → New secret**, chacun **attribué au dépôt `test`** :

| Secret | Valeur |
|---|---|
| `PROCAB_REPOS_TOKEN` | Un jeton **fine-grained** (Settings → Developer settings → Personal access tokens → Fine-grained) : propriétaire **anashaouzi**, accès limité aux **trois** dépôts `procab-db`, `procab-backend`, `procab-frontend`, permission **Contents : Read-only** et rien d'autre, date d'expiration courte. Il est lu par git au moment du clonage et n'est écrit nulle part (ni URL, ni `.git/config`, ni journal). |
| `DEMO_PASSWORD` | Le mot de passe commun des comptes de démonstration : 12 caractères minimum, avec une majuscule, un chiffre et un caractère spécial. Choisi par vous, jamais écrit dans le dépôt. |

> Si le propriétaire des dépôts est une organisation qui exige l'approbation des jetons fine-grained, la
> demande doit être approuvée avant le premier clonage.

## Créer et ouvrir l'environnement

1. Sur `marouaneboutchich-hub/test` : **Code → Codespaces → ⋯ → New with options**, branche
   `claude/gifted-keller-b8s7ax`, machine **2-core** (la plus petite proposée).
2. L'installation se lance d'elle-même (`scripts/installer.sh`, ~15 à 20 min la première fois sur 2 cœurs :
   images Docker, dépendances, construction). Elle se termine par la liste des comptes.
3. Onglet **PORTS** de VS Code → ligne **« ProCab (test) »** (port 3000, visibilité *Private*) → ouvrir
   l'adresse `https://<codespace>-3000.app.github.dev`.

À chaque réouverture du codespace, `scripts/demarrer.sh` relance les services automatiquement.

## Comptes de démonstration

Mot de passe : la valeur de votre secret `DEMO_PASSWORD`.

| Compte | Rôle | Arrive sur |
|---|---|---|
| `superadmin@procab.test` | Super-administrateur plateforme | Console `/admin` |
| `admin@atlas-conseil.test` — Karim Alaoui | Admin du cabinet (associé) | Espace cabinet |
| `directrice@atlas-conseil.test` — Salma Idrissi | Directrice (manager) — droits Achats + validation des RIB | Espace collaborateur (+ cabinet) |
| `manager@atlas-conseil.test` — Youssef Berrada | Manager — droits Achats | Espace collaborateur (+ cabinet) |
| `senior@atlas-conseil.test` — Nadia Tazi | Collaboratrice senior | Espace collaborateur |
| `assistant@atlas-conseil.test` — Omar Fassi | Collaborateur assistant | Espace collaborateur |
| `contact@oasis-distribution.test` — Hicham Bennani | Client portail, tous droits | Portail |
| `comptable@marrakech-textile.test` — Imane Zerouali | Client portail **restreint** (ni factures ni devis) | Portail |
| `admin@benjelloun-associes.test` | Admin d'un cabinet **en essai, J-5** | Accueil (onboarding) |
| `admin@comptoir-souss.test` | Admin d'un cabinet **suspendu** | Écran de fin d'essai |

## Ce que contient le jeu de données

- **Fiduciaire Atlas Conseil** (Casablanca) — abonnée (offre Business, 12 mois, virement déclaré puis vérifié
  dans la console), modules **Facturation** et **Achats** activés :
  6 clients ; 2 contacts portail ; 4 missions avec équipe et tâches (clôture annuelle, TVA, CNSS en retard,
  conseil avec un consultant externe) ; ~30 saisies de temps sur trois semaines ; une demande de pièces ;
  une facture payée, une facture échue impayée, un brouillon, un devis émis ; Achats : société « cabinet »
  et société cliente, un fournisseur, une facture d'achat déposée (PDF fictif) en brouillon.
- **Cabinet Benjelloun & Associés** (Rabat) — en essai, fin dans 5 jours.
- **Comptoir Comptable du Souss** (Agadir) — suspendu depuis la console.

Ce qui n'est **pas** semé, et se teste à la main : le partage d'une facture au portail (il envoie le PDF
généré par le navigateur), les messages, les congés, les évaluations, les notes de frais, la validation des
feuilles de temps, la double validation d'un RIB.

## Scénarios de test suggérés

1. **Cycle d'une mission** — l'assistant marque une tâche faite et saisit son temps ; la senior la révise ;
   le manager la valide ; la rentabilité bouge (compte directrice).
2. **Quatre yeux** — la réviseuse ne peut pas valider une tâche dont elle n'est pas cheffe de mission.
3. **Portail** — le client Oasis dépose une pièce sur la demande ouverte ; le cabinet l'accepte et la range.
4. **Facturation** — émettre le brouillon, le partager, le voir au portail Oasis ; relancer la facture échue.
5. **Droits portail** — le contact Marrakech Textile n'a ni menu ni accès aux factures.
6. **Achats** — compléter la facture d'achat en brouillon ; proposer un RIB (manager) puis le valider
   (directrice, un autre compte).
7. **Abonnement** — avec Benjelloun : souscrire, déclarer un virement ; avec le super-admin : le vérifier.
8. **Verrouillage** — Souss : écran de fin d'essai ; réactivation depuis la console.
9. **Isolation** — aucun compte d'un cabinet ne voit les données d'un autre.

## Commandes

```bash
bash scripts/demarrer.sh              # relancer les services
```

```bash
bash scripts/arreter.sh               # arrêter API, frontend et proxy (--tout : aussi Supabase)
```

```bash
bash scripts/reinitialiser.sh         # TOUT effacer (base locale) et resemer
```

```bash
tail -f .local/logs/api.log           # journaux : api, web, proxy, installation, migrations
```

## Comment c'est construit

```
navigateur ──(tunnel GitHub, port 3000 privé)──▶ proxy :3000 ─┬─ /v1/*, /health ──────────▶ API Fastify :3001
                                                              ├─ /auth|storage|realtime|rest/v1 ▶ Supabase local :54321
serveur Next, API ──(adresse publique → 127.0.0.1)──▶ :443 ───┴─ le reste ────────────────▶ Next.js :3002
```

- Le frontend est construit avec l'adresse publique du codespace (`NEXT_PUBLIC_*`) et l'API reçoit
  `SUPABASE_URL` = cette même adresse : le navigateur, le serveur Next et l'API parlent tous à **la même
  adresse**. Dans le codespace, `/etc/hosts` la résout vers `127.0.0.1`, où le proxy écoute aussi en HTTPS
  avec un certificat signé par une autorité **locale** (reconnue des seuls processus Node lancés ici).
- Le proxy réécrit vers l'adresse publique les redirections que Next construit avec son adresse interne
  (`localhost:3002`) — ce que fait Vercel en production.
- Base : `procab-db/sql/` appliqué dans l'ordre, sans les opérations marquées `@rejeu: ignorer`, comme la
  CI « Rejeu du schéma ». Une seule préparation de plateforme précède les migrations : retirer à
  `anon`/`authenticated` les droits par défaut que le Supabase local accorde pour `supabase_admin` (la
  migration 0134 l'exige, et seul `supabase_admin` peut le faire) — rien n'est assoupli, le contrôle de 0134
  juge ensuite l'état obtenu.
- Données : créées par l'API du produit (inscription, invitations, clients, missions, factures, Achats,
  abonnement, console), donc sous les mêmes contrôles qu'un vrai cabinet. Trois écritures directes
  seulement : l'inscription du super-admin dans `platform_admins`, le mot de passe des comptes invités (à la
  place du lien d'activation), la fin d'essai du cabinet « J-5 ».

## Dépannage

| Symptôme | Cause / geste |
|---|---|
| « clonage refusé » | Secret `PROCAB_REPOS_TOKEN` absent, expiré, non attribué au dépôt `test`, ou sans accès aux trois dépôts. |
| « Supabase local n'a pas démarré » | Voir `.local/logs/supabase-start.log`. Le registre d'images par défaut peut refuser un téléchargement (quota) : le script réessaie automatiquement depuis Docker Hub. |
| « Le frontend a été construit pour … » | Le nom du codespace a changé : relancer `bash scripts/installer.sh`. |
| Page « Service local indisponible » | Un service démarre encore ou s'est arrêté : `bash scripts/demarrer.sh`, puis les journaux. |
| Semis : « DEMO_PASSWORD absent » | Créer le secret, redémarrer le codespace (les secrets sont lus au démarrage), puis `node scripts/semer.mjs`. |
