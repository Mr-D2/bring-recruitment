# br-ing · Recruitment Docenti — AS 2026/27

Webapp di selezione docenti esterni basata sulla **Griglia di Selezione v1.3**.
Stadio 1 completo (form pubblico + backoffice); Stadio 2 e 3 già progettati nel
database come contenitori, da popolare con i materiali del Blocco A.

## Contenuto

| File | Cosa fa |
|---|---|
| `index.html` | Form pubblico di candidatura (Stadio 1) — testi dal Foglio 7 della griglia |
| `privacy.html` | Informativa privacy candidati v1.0 (cancello di consenso) |
| `admin.html` | Backoffice team: lista candidature, dettaglio risposte, download CV, override C1 con log, export CSV |
| `assets/config.js` | Chiavi di collegamento a Supabase (da compilare, vedi sotto) |
| `supabase/schema.sql` | Schema completo del database: tabelle dei 3 stadi, Pool C1 (24 combinazioni), assegnazione round-robin, sicurezza (RLS), bucket CV |

## Messa online — 4 passi

### 1 · Prepara Supabase (una volta sola)
1. Su [supabase.com](https://supabase.com) apri il tuo progetto (regione UE).
2. Menu **SQL Editor** → nuova query → incolla l'intero contenuto di `supabase/schema.sql` → **Run**. Deve terminare senza errori.
3. Menu **Authentication → Users → Add user**: crea gli utenti del team che accederanno al backoffice (email + password). Solo questi utenti vedranno le candidature.

### 2 · Collega la webapp a Supabase
1. Nel progetto Supabase: **Project Settings → API**.
2. Copia **Project URL** e **anon public key**.
3. Apri `assets/config.js` (su GitHub: clic sul file → matita "Edit") e incolla i due valori. Salva (Commit changes).

> La chiave *anon* è fatta per stare nel browser: i dati sono protetti dalle
> regole di sicurezza del database (RLS), non dalla segretezza della chiave.
> Non inserire mai la chiave *service_role*.

### 3 · Attiva GitHub Pages
1. Nel repo: **Settings → Pages**.
2. Source: **Deploy from a branch** · Branch: **main** · cartella **/ (root)** → Save.
3. Dopo 1-2 minuti il sito è online su `https://<utente>.github.io/bring-recruitment/`.

### 4 · Prova end-to-end
1. Apri il link del form, compila una candidatura di prova con una tua email.
2. Verifica su `admin.html` (stesso indirizzo + `/admin.html`) che la candidatura
   compaia, che la combinazione C1 sia assegnata e che il CV si scarichi.
3. Cancella il record di prova da Supabase (**Table Editor → candidates**).

## Cosa fa il sistema (in breve)

- **Assegnazione C1** al termine della Sezione 0: round-robin sulla strategia
  meno usata per area, topic estratto tra gli ammessi meno usati (matrice del
  Foglio 6), combinazione **persistita sul record** (stessa email → stessa
  combinazione) e pronta per la reiniezione nella consegna di Stadio 2.
- **Salvataggio automatico** sul dispositivo del candidato: può chiudere e
  riprendere, come promesso nel testo di apertura.
- **KO invisibili**: il form non mostra mai soglie o esclusioni; lo scoring
  avviene solo in backoffice/griglia.
- **Consensi** raccolti con caselle distinte e non pre-selezionate; il primo
  blocca l'invio, il secondo (conservazione 12 mesi) è indipendente.
- **Sicurezza**: nessun accesso anonimo diretto alle tabelle — i candidati
  passano solo dalle due funzioni di scrittura; il team autenticato legge tutto;
  i CV stanno in un bucket privato (PDF, max 5 MB) accessibile solo con login.
- **Override manuale** della combinazione in backoffice, con motivo e log
  (regola 5 del Foglio 6).

## Da fare nei prossimi passi (fuori da questo go-live)

- **Email di conferma automatica** al candidato dopo l'invio (ora la conferma è
  a schermo; l'impegno dei 5 giorni resta un task con owner nel planner).
- **Stadio 2**: generazione consegne con reiniezione della combinazione C1,
  upload elaborati → tabella `stage2_submissions` (già pronta).
- **Pre-screening AI** delle risposte aperte via API Anthropic da Edge Function
  Supabase (proposta in `ai_prescore`, validazione umana in `human_score`).
- **Stadio 3**: registrazione colloqui → tabella `stage3_interviews` (già pronta).

## Nota sulla riservatezza

Questo repository è pubblico e contiene **solo il modulo**: nessuna rubrica di
valutazione, nessuna soglia, nessun peso, nessun prompt AI. Tutto il materiale
valutativo resta nella griglia Excel confidenziale e, in prospettiva, dentro
Supabase — mai nel codice.
