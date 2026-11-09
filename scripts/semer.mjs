// ════════════════════════════════════════════════════════════════════════════════════════════
// SEMIS des données de DÉMONSTRATION de l'environnement de test ProCab.
//
// Tout est FICTIF : cabinets, personnes, sociétés, ICE, montants. Les adresses sont en `.test`,
// domaine réservé (RFC 2606) : aucun e-mail ne peut y être remis, même par erreur.
//
// Méthode : on passe par l'API du produit (inscription, invitations, clients, missions, factures,
// Achats, abonnement, console) — les données naissent comme celles d'un vrai cabinet, sous les mêmes
// contrôles. Trois gestes seulement s'écrivent directement :
//   · l'inscription du super-administrateur dans `platform_admins` (aucune API ne crée le premier) ;
//   · le mot de passe des comptes INVITÉS (au lieu du lien d'activation, qui n'est envoyé nulle part) ;
//   · la date de fin d'essai du cabinet « en essai à J-5 » (pour rendre ce cas visible sans attendre).
//
// Gardes : refus si l'API ou la base ne sont pas LOCALES, ou si la référence de production apparaît.
// Mot de passe : variable DEMO_PASSWORD (secret Codespaces), jamais écrit dans le dépôt ni affiché.
// Idempotence : si le cabinet « Fiduciaire Atlas Conseil » existe déjà, on s'arrête (reinitialiser.sh
// repart de zéro).
// ════════════════════════════════════════════════════════════════════════════════════════════
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const RACINE = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const PROD_REF = 'yknycpdxraduiinhswnb';
const API = 'http://127.0.0.1:3001/v1';
const SUPABASE = 'http://127.0.0.1:54321';
const CONTENEUR_DB = 'supabase_db_procab-test';

// ── Gardes ─────────────────────────────────────────────────────────────────────────────────
function lireEnv(fichier) {
  const out = {};
  for (const ligne of readFileSync(fichier, 'utf8').split('\n')) {
    const m = ligne.match(/^([A-Z0-9_]+)="?(.*?)"?$/);
    if (m) out[m[1]] = m[2];
  }
  return out;
}
const apiEnv = lireEnv(`${RACINE}/.local/api.env`);
const sbEnv = lireEnv(`${RACINE}/.local/supabase.env`);
for (const [nom, valeur] of Object.entries({ DATABASE_URL: apiEnv.DATABASE_URL, SUPABASE_URL: apiEnv.SUPABASE_URL })) {
  if (!valeur || valeur.includes(PROD_REF) || /supabase\.(co|com)/.test(valeur)) {
    console.error(`GARDE : ${nom} n'est pas local (${valeur}). Arrêt.`);
    process.exit(1);
  }
}
if (!/@(127\.0\.0\.1|localhost):/.test(apiEnv.DATABASE_URL)) {
  console.error('GARDE : DATABASE_URL ne vise pas une base locale. Arrêt.');
  process.exit(1);
}
const MDP = process.env.DEMO_PASSWORD ?? '';
if (MDP.length < 12 || !/[A-Z]/.test(MDP) || !/\d/.test(MDP) || !/[^A-Za-z0-9]/.test(MDP)) {
  console.error('DEMO_PASSWORD absent ou trop faible : 12 caractères min., avec une majuscule, un chiffre et un caractère spécial.');
  process.exit(1);
}
const ANON = sbEnv.ANON_KEY;
const SERVICE = sbEnv.SERVICE_ROLE_KEY;

// ── Outils ─────────────────────────────────────────────────────────────────────────────────
const bilan = { ok: [], echecs: [] };
function sql(requete) {
  return execFileSync('docker', ['exec', '-i', CONTENEUR_DB, 'psql', '-U', 'postgres', '-d', 'postgres', '-X', '-tA', '-v', 'ON_ERROR_STOP=1', '-c', requete], {
    encoding: 'utf8',
  }).trim();
}
const lit = (s) => `'${String(s).replace(/'/g, "''")}'`;

async function http(methode, url, { jeton, corps, apikey } = {}) {
  const res = await fetch(url, {
    method: methode,
    headers: {
      ...(corps !== undefined ? { 'content-type': 'application/json' } : {}),
      ...(jeton ? { authorization: `Bearer ${jeton}` } : {}),
      ...(apikey ? { apikey } : {}),
    },
    body: corps !== undefined ? JSON.stringify(corps) : undefined,
  });
  const texte = await res.text();
  let json;
  try {
    json = texte ? JSON.parse(texte) : null;
  } catch {
    json = { brut: texte.slice(0, 300) };
  }
  if (!res.ok) {
    const err = new Error(`${methode} ${url.replace(API, '/v1')} → ${res.status} ${JSON.stringify(json?.error ?? json).slice(0, 400)}`);
    err.status = res.status;
    throw err;
  }
  return json;
}
const api = (methode, chemin, jeton, corps) => http(methode, `${API}${chemin}`, { jeton, corps });

/** Une étape : réussie ou échouée, elle est NOMMÉE dans le bilan. `critique` arrête le semis. */
async function etape(nom, fn, { critique = false } = {}) {
  try {
    const r = await fn();
    bilan.ok.push(nom);
    console.log(`  ✔ ${nom}`);
    return r;
  } catch (e) {
    bilan.echecs.push(`${nom} — ${e.message}`);
    console.log(`  ✘ ${nom}\n      ${e.message}`);
    if (critique) {
      afficherBilan();
      process.exit(1);
    }
    return undefined;
  }
}

async function connexion(email) {
  const r = await http('POST', `${SUPABASE}/auth/v1/token?grant_type=password`, { apikey: ANON, corps: { email, password: MDP } });
  // Premier appel authentifié : l'API enregistre l'activation (users.first_activated_at).
  await api('GET', '/auth/me', r.access_token);
  return r.access_token;
}

/** Compte INVITÉ : on remplace le lien d'activation (envoyé nulle part) par le mot de passe de démo. */
async function activerInvite(email) {
  const uid = sql(`select supabase_uid from users where lower(email) = lower(${lit(email)}) and deleted_at is null`);
  if (!uid) throw new Error(`aucun compte pour ${email}`);
  await http('PUT', `${SUPABASE}/auth/v1/admin/users/${uid}`, {
    apikey: SERVICE,
    jeton: SERVICE,
    corps: { password: MDP, email_confirm: true },
  });
  return connexion(email);
}

const JOUR = 86_400_000;
const iso = (d) => d.toISOString().slice(0, 10);
const aujourdhui = new Date(`${new Date().toISOString().slice(0, 10)}T00:00:00Z`);
const jour = (n) => iso(new Date(aujourdhui.getTime() + n * JOUR));
const lundi = (() => {
  const d = new Date(aujourdhui);
  const j = d.getUTCDay();
  d.setUTCDate(d.getUTCDate() + (j === 0 ? -6 : 1 - j));
  return d;
})();
/** Jour ouvré `n` semaines en arrière (0 = cette semaine), `j` = 0 lundi … 4 vendredi, à `h` heures UTC. */
const creneau = (semaine, j, h) => new Date(lundi.getTime() - semaine * 7 * JOUR + j * JOUR + h * 3_600_000).toISOString();

function afficherBilan() {
  console.log(`\n── Bilan du semis : ${bilan.ok.length} étape(s) réussie(s), ${bilan.echecs.length} échec(s)`);
  for (const e of bilan.echecs) console.log(`   ✘ ${e}`);
}

// ── Données ────────────────────────────────────────────────────────────────────────────────
const D = 'atlas-conseil.test';
const ATLAS = {
  cabinet: { name: 'Fiduciaire Atlas Conseil', type: 'fiduciaire', email: `cabinet@${D}`, city: 'Casablanca', phone: '+212522000101', size: '5-20', legalForm: 'SARL' },
  admin: { email: `admin@${D}`, fullName: 'Karim Alaoui' },
  equipe: [
    { cle: 'directrice', email: `directrice@${D}`, fullName: 'Salma Idrissi', grade: 'directeur', monthlyCost: 32000, monthlyHours: 169 },
    { cle: 'manager', email: `manager@${D}`, fullName: 'Youssef Berrada', grade: 'manager', monthlyCost: 22000, monthlyHours: 169 },
    { cle: 'senior', email: `senior@${D}`, fullName: 'Nadia Tazi', grade: 'senior', monthlyCost: 14000, monthlyHours: 169 },
    { cle: 'assistant', email: `assistant@${D}`, fullName: 'Omar Fassi', grade: 'assistant', monthlyCost: 9000, monthlyHours: 169 },
  ],
  clients: [
    { cle: 'oasis', companyName: 'SARL Oasis Distribution', legalForm: 'SARL', ice: '001234567000081', city: 'Casablanca', contactName: 'Hicham Bennani', contactEmail: 'contact@oasis-distribution.test', paymentTermsDays: 30 },
    { cle: 'textile', companyName: 'Société Marrakech Textile SA', legalForm: 'SA', ice: '001234567000082', city: 'Marrakech', contactName: 'Imane Zerouali', contactEmail: 'comptable@marrakech-textile.test', paymentTermsDays: 60 },
    { cle: 'bati', companyName: 'Bâti Sud Construction SARL', legalForm: 'SARL', ice: '001234567000083', city: 'Agadir', contactName: 'Rachid Amrani', paymentTermsDays: 45 },
    { cle: 'cafe', companyName: 'Café des Arts SARL AU', legalForm: 'SARL', ice: '001234567000084', city: 'Rabat', contactName: 'Leila Mansouri', paymentTermsDays: 30 },
    { cle: 'assoc', companyName: 'Association Lumière du Savoir', city: 'Fès', contactName: 'Driss Kettani', paymentTermsDays: 30 },
    { cle: 'tech', companyName: 'Atlas Tech Solutions SA', legalForm: 'SA', ice: '001234567000086', city: 'Tanger', contactName: 'Mehdi Lahlou', paymentTermsDays: 30 },
  ],
};
const BENJELLOUN = {
  cabinet: { name: 'Cabinet Benjelloun & Associés', type: 'expert_comptable', email: 'cabinet@benjelloun-associes.test', city: 'Rabat', phone: '+212537000202', size: '1-5' },
  admin: { email: 'admin@benjelloun-associes.test', fullName: 'Amina Benjelloun' },
};
const SOUSS = {
  cabinet: { name: 'Comptoir Comptable du Souss', type: 'comptable_agree', email: 'cabinet@comptoir-souss.test', city: 'Agadir', phone: '+212528000303', size: 'independant' },
  admin: { email: 'admin@comptoir-souss.test', fullName: 'Brahim Ait Ouahmane' },
};
const SUPERADMIN = { email: 'superadmin@procab.test' };

async function inscrire(c) {
  const r = await api('POST', '/auth/register', undefined, {
    cabinet: c.cabinet,
    admin: { ...c.admin, password: MDP },
    acceptedLegal: true,
  });
  const tenantId = sql(`select id from tenants where name = ${lit(c.cabinet.name)} and deleted_at is null`);
  if (!tenantId) throw new Error(`cabinet introuvable après inscription (${JSON.stringify(r).slice(0, 200)})`);
  return tenantId;
}

// ── Déroulé ────────────────────────────────────────────────────────────────────────────────
async function main() {
  console.log('Semis des données de démonstration (fictives) — environnement de test local');
  if (sql(`select count(*) from tenants where name = ${lit(ATLAS.cabinet.name)}`) !== '0') {
    console.log('Les données de démonstration existent déjà — rien à faire. (Repartir de zéro : bash scripts/reinitialiser.sh)');
    return;
  }

  // 1. Super-administrateur de la plateforme (console /admin).
  console.log('\n1. Super-administrateur');
  await etape(
    'compte super-admin (Auth) + inscription dans platform_admins',
    async () => {
      await http('POST', `${SUPABASE}/auth/v1/admin/users`, {
        apikey: SERVICE,
        jeton: SERVICE,
        corps: { email: SUPERADMIN.email, password: MDP, email_confirm: true },
      });
      sql(`insert into platform_admins (email, role, active) values (${lit(SUPERADMIN.email)}, 'owner', true)`);
    },
    { critique: true },
  );
  const jetonSA = await etape('connexion super-admin', async () => {
    const r = await http('POST', `${SUPABASE}/auth/v1/token?grant_type=password`, { apikey: ANON, corps: { email: SUPERADMIN.email, password: MDP } });
    await api('GET', '/admin/me', r.access_token);
    return r.access_token;
  });

  // 2. Trois cabinets, par le parcours d'inscription réel.
  console.log('\n2. Cabinets');
  const tAtlas = await etape(`inscription « ${ATLAS.cabinet.name} »`, () => inscrire(ATLAS), { critique: true });
  const tBenj = await etape(`inscription « ${BENJELLOUN.cabinet.name} »`, () => inscrire(BENJELLOUN));
  const tSouss = await etape(`inscription « ${SOUSS.cabinet.name} »`, () => inscrire(SOUSS));
  const jA = await etape('connexion admin Atlas', () => connexion(ATLAS.admin.email), { critique: true });
  // Le module Achats n'existe que sur certaines branches (absent de `main`) : une route inconnue répond 404.
  const achatsPresents = await api('GET', '/purchases/entities', jA).then(() => true, (e) => e.status !== 404);
  if (tBenj) await etape('connexion admin Benjelloun', () => connexion(BENJELLOUN.admin.email));
  if (tSouss) await etape('connexion admin Souss', () => connexion(SOUSS.admin.email));

  if (jetonSA) {
    for (const flag of achatsPresents ? ['billing', 'purchases'] : ['billing']) {
      await etape(`console : module « ${flag} » activé pour Atlas`, () => api('POST', `/admin/cabinets/${tAtlas}/flag`, jetonSA, { flag, enabled: true }));
    }
  }

  // 3. Équipe d'Atlas.
  console.log('\n3. Équipe');
  const membres = {};
  for (const m of ATLAS.equipe) {
    await etape(`invitation ${m.fullName} (${m.grade})`, () =>
      api('POST', '/auth/invite-user', jA, { email: m.email, fullName: m.fullName, grade: m.grade, monthlyCost: m.monthlyCost, monthlyHours: m.monthlyHours, hireDate: jour(-400) }),
    );
    const jeton = await etape(`activation ${m.fullName}`, () => activerInvite(m.email));
    membres[m.cle] = { ...m, jeton, id: sql(`select id from users where lower(email)=lower(${lit(m.email)})`) };
  }
  membres.admin = { id: sql(`select id from users where lower(email)=lower(${lit(ATLAS.admin.email)})`), jeton: jA };
  const droitsAchats = ['purchases:suppliers:read', 'purchases:suppliers:write', 'purchases:suppliers:rib', 'purchases:invoices:read', 'purchases:invoices:write', 'purchases:settings'];
  for (const [cle, extra] of achatsPresents ? [['manager', []], ['directrice', ['purchases:suppliers:rib:validate']]] : []) {
    if (!membres[cle]?.id) continue;
    await etape(`droits Achats → ${membres[cle].fullName}`, () =>
      api('PATCH', `/cabinet/team/${membres[cle].id}/permissions`, jA, {
        permissions: Object.fromEntries([...droitsAchats, ...extra].map((c) => [c, true])),
      }),
    );
  }

  // 4. Clients et portail.
  console.log('\n4. Clients et portail');
  const clients = {};
  for (const c of ATLAS.clients) {
    const { cle, ...corps } = c;
    const r = await etape(`client ${c.companyName}`, () => api('POST', '/clients', jA, { ...corps, assignedTo: membres.manager?.id ?? null }));
    clients[cle] = r?.data?.id ?? r?.id ?? r?.client?.id ?? sql(`select id from clients where company_name = ${lit(c.companyName)} and tenant_id = ${lit(tAtlas)}`);
  }
  await etape('portail : contact principal de SARL Oasis Distribution (tous droits)', async () => {
    await api('POST', `/clients/${clients.oasis}/portal`, jA, { email: 'contact@oasis-distribution.test', fullName: 'Hicham Bennani' });
    await activerInvite('contact@oasis-distribution.test');
  });
  await etape('portail : contact restreint de Marrakech Textile (sans factures ni devis)', async () => {
    await api('POST', `/clients/${clients.textile}/portal-users`, jA, {
      email: 'comptable@marrakech-textile.test',
      fullName: 'Imane Zerouali',
      rights: { missions: true, documents: true, messagerie: true, factures: false, devis: false, engagements: false, depot_spontane: true },
      seesAllMissions: true,
    });
    await activerInvite('comptable@marrakech-textile.test');
  });

  // 5. Missions (création complète : équipe + tâches en une transaction).
  console.log('\n5. Missions et tâches');
  const m = (cle) => membres[cle]?.id;
  const missions = {};
  const defs = [
    {
      cle: 'cloture', client: 'oasis', name: 'Clôture annuelle 2026', type: 'cloture_annuelle', start: -40, deadline: 45, fiscalPeriod: '2026',
      team: [['manager', 'lead', 60], ['senior', 'contributeur', 80], ['assistant', 'contributeur', 120]],
      tasks: [
        ['Collecte des relevés bancaires', 'assistant', 'senior', 1, 6],
        ['Saisie des achats et ventes du T4', 'assistant', 'senior', 2, 16],
        ['Rapprochement bancaire décembre', 'senior', 'manager', 3, 6],
        ['Revue des comptes de charges', 'senior', 'manager', 4, 8],
        ['Préparation de la liasse fiscale', 'manager', 'directrice', 5, 10],
      ],
    },
    {
      cle: 'tva', client: 'textile', name: 'Déclaration TVA — octobre 2026', type: 'tva_mensuelle', start: -10, deadline: 14, fiscalPeriod: '2026-10',
      team: [['senior', 'lead', 10], ['assistant', 'contributeur', 12]],
      tasks: [
        ['Réception des factures d’achat', 'assistant', 'senior', 1, 3],
        ['Contrôle et saisie', 'assistant', 'senior', 2, 5],
        ['Validation de la déclaration', 'senior', 'manager', 3, 2],
      ],
    },
    {
      cle: 'cnss', client: 'bati', name: 'Déclaration CNSS — octobre 2026', type: 'cnss', start: -20, deadline: -2, fiscalPeriod: '2026-10',
      team: [['assistant', 'lead', 6]],
      tasks: [['Calcul des cotisations', 'assistant', 'senior', 2, 3]],
    },
    {
      cle: 'conseil', client: 'tech', name: 'Conseil — structuration du groupe', type: 'conseil', start: -5, deadline: 60,
      team: [['directrice', 'lead', 30], ['manager', 'contributeur', 20]],
      tasks: [['Cadrage avec la direction', 'directrice', 'manager', 1, 4], ['Analyse des schémas possibles', 'manager', 'directrice', 2, 12]],
      consultants: [{ fullName: 'Cabinet Juridique Noor', hourlyRate: 900, allocatedHours: 10 }],
    },
  ];
  for (const d of defs) {
    const r = await etape(`mission « ${d.name} » (${ATLAS.clients.find((c) => c.cle === d.client).companyName})`, () =>
      api('POST', '/missions', jA, {
        clientId: clients[d.client],
        name: d.name,
        type: d.type,
        startDate: jour(d.start),
        deadline: jour(d.deadline),
        fiscalPeriod: d.fiscalPeriod,
        leadId: m(d.team[0][0]),
        team: d.team.filter(([k]) => m(k)).map(([k, role, h]) => ({ userId: m(k), role, allocatedHours: h })),
        tasks: d.tasks
          .filter(([, a]) => m(a))
          .map(([title, a, rv, step, h]) => ({ title, assignedTo: m(a), reviewerId: m(rv) ?? null, stepNumber: step, estimatedHours: h, dueDate: jour(Math.min(d.deadline, d.start + step * 7)) })),
        consultants: d.consultants ?? [],
        contactIds: [],
        typeTasksIncluded: false,
      }),
    );
    const id = r?.data?.[0]?.id ?? r?.missions?.[0]?.id ?? r?.data?.id ?? r?.id ?? sql(`select id from missions where name = ${lit(d.name)} and tenant_id = ${lit(tAtlas)} limit 1`);
    missions[d.cle] = id;
  }
  // 6. Temps saisis (trois dernières semaines) par l'assistant et la senior.
  console.log('\n6. Temps');
  const tachesDe = (mission) =>
    sql(`select id || '|' || coalesce(assigned_to::text,'') from tasks where mission_id = ${lit(mission)} order by step_number, created_at`)
      .split('\n')
      .filter(Boolean)
      .map((l) => ({ id: l.split('|')[0], assignee: l.split('|')[1] }));
  let saisies = 0;
  for (const qui of ['assistant', 'senior']) {
    if (!membres[qui]?.jeton) continue;
    const mesTaches = [...tachesDe(missions.cloture), ...tachesDe(missions.tva)].filter((t) => t.assignee === m(qui));
    for (let semaine = 2; semaine >= 0; semaine--) {
      for (let j = 0; j < 5; j++) {
        if (semaine === 0 && new Date(creneau(0, j, 9)) > new Date()) continue;
        const t = mesTaches[(semaine + j) % Math.max(mesTaches.length, 1)];
        if (!t) continue;
        const missionId = tachesDe(missions.cloture).some((x) => x.id === t.id) ? missions.cloture : missions.tva;
        try {
          await api('POST', '/time-entries', membres[qui].jeton, {
            missionId, taskId: t.id, startedAt: creneau(semaine, j, 8), durationMin: 240 + 30 * ((j + semaine) % 4),
            description: 'Travaux de la mission (saisie de démonstration)', isBillable: true,
          });
          saisies++;
        } catch (e) {
          bilan.echecs.push(`temps ${qui} S-${semaine} J${j} — ${e.message}`);
        }
      }
    }
  }
  console.log(`  ✔ ${saisies} saisies de temps`);
  if (saisies > 0) bilan.ok.push(`${saisies} saisies de temps`);

  // 7. Demandes de pièces (portail Oasis).
  console.log('\n7. Demandes de pièces');
  await etape('demande de pièces « Clôture 2026 » à SARL Oasis Distribution', () =>
    api('POST', `/clients/${clients.oasis}/document-requests`, jA, {
      missionId: missions.cloture,
      dueDate: jour(10),
      notify: false,
      items: [{ label: 'Relevés bancaires de décembre 2026' }, { label: 'Inventaire physique au 31/12' }, { label: 'Contrats de bail en vigueur' }],
    }),
  );

  // 8. Facturation : une facture payée, une émise en retard, un brouillon, un devis.
  console.log('\n8. Facturation');
  const facture = async (client, lignes, dates) => {
    const r = await api('POST', '/invoices', jA, { clientId: clients[client], freeLines: lignes, tvaRate: 20, ...dates });
    return r?.data?.id ?? r?.invoice?.id ?? r?.id;
  };
  await etape('facture émise et encaissée — SARL Oasis Distribution', async () => {
    const id = await facture('oasis', [{ label: 'Honoraires — tenue comptable T3 2026', amountHt: 12000 }], { issueDate: jour(-45), dueDate: jour(-15) });
    await api('POST', `/invoices/${id}/issue`, jA, { issueDate: jour(-45), confirmSequence: true, confirmOverBudget: true });
    await api('POST', `/invoices/${id}/paid`, jA, { paid: true });
  });
  await etape('facture émise, échue et impayée — Bâti Sud Construction', async () => {
    const id = await facture('bati', [{ label: 'Honoraires — déclarations sociales T3 2026', amountHt: 4500 }], { issueDate: jour(-70), dueDate: jour(-25) });
    await api('POST', `/invoices/${id}/issue`, jA, { issueDate: jour(-70), confirmSequence: true, confirmOverBudget: true });
  });
  await etape('facture en brouillon — Atlas Tech Solutions', () => facture('tech', [{ label: 'Mission de conseil — acompte', amountHt: 15000 }], {}));
  await etape('devis émis — Café des Arts', async () => {
    const r = await api('POST', '/quotes', jA, {
      clientId: clients.cafe,
      object: 'Tenue comptable et déclarations fiscales 2027',
      lines: [{ label: 'Tenue comptable mensuelle', quantity: 12, unitPrice: 1500 }, { label: 'Bilan et liasse fiscale', quantity: 1, unitPrice: 8000 }],
      tvaRate: 20,
    });
    const id = r?.data?.id ?? r?.quote?.id ?? r?.id;
    await api('POST', `/quotes/${id}/issue`, jA, {});
  });

  // 9. Achats — seulement si la branche suivie contient le module (absent de `main`).
  console.log('\n9. Achats');
  if (!achatsPresents) {
    console.log('  – module Achats absent de cette branche : étape sautée');
  } else {
    await etape('Achats : société « cabinet » activée', () => api('POST', '/purchases/entities', jA, { kind: 'cabinet' }));
    const entite = await etape('Achats : société cliente SARL Oasis Distribution activée', () =>
      api('POST', '/purchases/entities', jA, { kind: 'client', clientId: clients.oasis }),
    );
    await etape('Achats : fournisseur « Papeterie du Littoral »', () =>
      api('POST', '/purchases/suppliers', jA, {
        legalName: 'Papeterie du Littoral', legalForm: 'sarl', country: 'MA', ice: '002345678000091',
        ifNumber: '45678912', rcNumber: '123456', rcCourt: 'Casablanca', city: 'Casablanca', email: 'ventes@papeterie-littoral.test',
      }),
    );
    const entiteId = entite?.entity?.id ?? entite?.data?.id ?? entite?.id ?? sql(`select id from accounting_entities where tenant_id = ${lit(tAtlas)} and client_id = ${lit(clients.oasis)} limit 1`);
    await etape('Achats : facture d’achat déposée (PDF fictif) → brouillon créé', async () => {
      // Un PDF minimal mais valide, fabriqué ici : aucune pièce réelle.
      const pdf = Buffer.from(
        '%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj 2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj ' +
          '3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 595 842]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj ' +
          '4 0 obj<</Length 74>>stream\nBT /F1 18 Tf 60 760 Td (Facture fictive - Papeterie du Littoral - 1 450,00 MAD) Tj ET\nendstream endobj ' +
          '5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n',
      );
      const ticket = await api('POST', `/purchases/entities/${entiteId}/invoices/uploads`, jA, {
        name: 'facture-papeterie-littoral-demo.pdf', mimeType: 'application/pdf', sizeBytes: pdf.length,
      });
      const documentId = ticket?.document?.id ?? ticket?.documentId;
      if (!ticket?.uploadUrl || !documentId) throw new Error(`ticket inattendu : ${JSON.stringify(ticket).slice(0, 200)}`);
      // Même envoi que le navigateur (FormData, en-têtes storage-js) ; l'adresse publique est ramenée
      // au Supabase local, que le semis joint directement.
      const url = ticket.uploadUrl.replace(apiEnv.SUPABASE_URL, SUPABASE);
      const form = new FormData();
      form.append('cacheControl', '3600');
      form.append('', new Blob([pdf], { type: 'application/pdf' }), 'facture-papeterie-littoral-demo.pdf');
      const put = await fetch(url, { method: 'PUT', body: form, headers: { authorization: `Bearer ${ANON}`, apikey: ANON, 'x-upsert': 'false' } });
      if (!put.ok) throw new Error(`envoi au stockage refusé : ${put.status} ${(await put.text()).slice(0, 200)}`);
      await api('POST', `/purchases/entities/${entiteId}/invoices/uploads/${documentId}/confirm`, jA, {});
    });
  }

  // 10. États d'abonnement des deux autres cabinets.
  console.log('\n10. États des cabinets');
  if (tBenj) {
    await etape('Benjelloun : essai ramené à J-5 (fin d’essai dans 5 jours)', async () => {
      sql(`update tenants set trial_ends_at = now() + interval '5 days' where id = ${lit(tBenj)} and status = 'trial'`);
      if (sql(`select count(*) from tenants where id = ${lit(tBenj)} and trial_ends_at::date = (now() + interval '5 days')::date`) !== '1') {
        throw new Error('la date de fin d’essai n’a pas été posée (cabinet hors essai ?)');
      }
    });
  }
  if (tSouss && jetonSA) {
    await etape('Souss : suspendu depuis la console (motif saisi)', () =>
      api('POST', `/admin/cabinets/${tSouss}/suspend`, jetonSA, { motif: 'Cabinet de démonstration : essai échu, cas de verrouillage.' }),
    );
  }

  // 11. Abonnement d'Atlas par le circuit réel : souscrire → déclarer le virement → vérifier.
  console.log('\n11. Abonnement d’Atlas (virement fictif)');
  await etape('Atlas : souscription Business 12 mois, virement déclaré puis vérifié par la console', async () => {
    const sub = await api('POST', '/subscription/subscribe', jA, { planCode: 'business', termMonths: 12 });
    const pay = await api('GET', '/subscription/payment', jA);
    const montant = Number(pay?.payment?.amountTtc ?? pay?.amountTtc ?? sub?.payment?.amountTtc ?? sub?.amountTtc);
    if (!Number.isFinite(montant) || montant <= 0) throw new Error(`montant à régler introuvable (${JSON.stringify(pay).slice(0, 200)})`);
    await api('POST', '/subscription/payment/declare', jA, { declaredOn: jour(0), declaredAmountTtc: montant });
    const pid = sql(`select id from subscription_payments where tenant_id = ${lit(tAtlas)} order by created_at desc limit 1`);
    if (!jetonSA) throw new Error('pas de session super-admin pour vérifier le virement');
    await api('POST', `/admin/payments/${pid}/verify`, jetonSA, { valueOn: jour(0), verifiedAmountTtc: montant });
  });

  afficherBilan();
  console.log(`
── Comptes de démonstration (mot de passe : la valeur du secret DEMO_PASSWORD)
   Super-admin plateforme   ${SUPERADMIN.email}                  → console /admin
   Atlas — admin (associé)  ${ATLAS.admin.email}
${ATLAS.equipe.map((x) => `   Atlas — ${x.grade.padEnd(16)} ${x.email}`).join('\n')}
   Portail Oasis (complet)  contact@oasis-distribution.test
   Portail Textile (limité) comptable@marrakech-textile.test
   Benjelloun — admin       ${BENJELLOUN.admin.email}   (essai, J-5)
   Souss — admin            ${SOUSS.admin.email}        (suspendu)`);
  if (bilan.echecs.length > 0) process.exitCode = 2;
}

main().catch((e) => {
  console.error(e);
  afficherBilan();
  process.exit(1);
});
