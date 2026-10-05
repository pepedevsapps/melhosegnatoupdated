# Popcorn Club — Serata cinema

Web app responsive, pubblicabile su GitHub Pages. Usa Supabase Auth e Postgres per gli account e i dati della serata.

## Funzioni incluse

- Registrazione con username, email e password; accesso con email e password.
- Profilo admin riservato allo username `pepe1914`.
- Una serata attiva per progetto Supabase; all'avvio vengono inclusi gli account già registrati.
- Assegnazione casuale delle categorie. Se le persone sono più delle categorie, le categorie ricominciano dopo una nuova mescolata.
- Nomination privata: ogni partecipante vede il proprio titolo e lo stato di invio degli altri, ma non i loro titoli.
- Sorteggio casuale da parte dell'admin. Ogni nomination estratta esce definitivamente dal pool.
- Verifica anonima “L'ho visto / Non l'ho visto”; si decide solo dopo le risposte di tutti. Se almeno il 60% dichiara di averlo già visto, il titolo viene scartato.
- Valutazione dei film approvati da 1 a 5 popcorn, con mezzi punti.
- Classifica sbloccata quando il pool è vuoto e tutti i film approvati hanno ricevuto il voto di tutti. L'admin rivela una posizione alla volta, dall'ultima fino al podio.
- I titoli duplicati nella stessa serata sono rifiutati dopo normalizzazione di maiuscole e spazi.
- Aggiornamento automatico della dashboard ogni 12 secondi, oltre al pulsante Aggiorna.

## Requisiti

- Un progetto Supabase.
- Un repository GitHub con GitHub Pages abilitato tramite GitHub Actions.
- Un indirizzo email da associare all'account admin.
- Un browser moderno con accesso a internet (la libreria Supabase JS viene caricata da jsDelivr).

## 1. Configura Supabase

1. Crea un nuovo progetto Supabase.
2. Apri **SQL Editor**, incolla tutto il contenuto di `supabase/schema.sql` ed eseguilo. Lo script è pensato per un progetto nuovo.
3. Prima di creare l'account admin, esegui questo comando sostituendo l'indirizzo:

   ```sql
   update public.admin_bootstrap
   set email = lower('INDIRIZZO_EMAIL_ADMIN')
   where singleton = true;
   ```

4. Apri l'app, scegli **Registrati** e crea l'admin con username `pepe1914`, l'indirizzo appena configurato e la password admin scelta. Il database assegna il ruolo admin solo se email e username corrispondono.
5. Dopo che il profilo admin è stato creato, puoi rimuovere l'email di bootstrap. Il ruolo rimane admin e lo username resta riservato:

   ```sql
   update public.admin_bootstrap set email = null where singleton = true;
   ```

6. In **Project Settings → API**, copia il Project URL e la anon/publishable key in `js/supabase-config.js`:

   ```js
   export const SUPABASE_URL = "https://il-tuo-progetto.supabase.co";
   export const SUPABASE_PUBLISHABLE_KEY = "la-tua-publishable-key";
   ```

   La chiave anon/publishable è pubblica e può stare nel client. **Non usare la secret key o la service_role key**: queste chiavi bypassano le policy di sicurezza.

7. In **Authentication → URL Configuration**, configura il Site URL e gli URL consentiti per le email di conferma. Aggiungi l'indirizzo locale di test e l'URL GitHub Pages, ad esempio:
   - `http://localhost:8000/`
   - `https://TUO-UTENTE.github.io/NOME-REPOSITORY/`

   Se la conferma email è attiva, il nuovo utente dovrà aprire il link ricevuto prima di accedere.

## 2. Prova in locale

Dalla cartella `serata-cinema-web`:

```bash
python3 -m http.server 8000
```

Apri `http://localhost:8000/`. Le richieste Supabase funzionano dopo aver compilato `js/supabase-config.js`.

## 3. Gestisci la configurazione Auth con Supabase CLI

La CLI è una dipendenza di sviluppo del progetto. Dopo `npm install`, accedi con `npx supabase login` e controlla le differenze prima di inviare modifiche:

```bash
npx supabase config diff --project-ref pmfnvpmfmmixmfncjvti
npx supabase config push --project-ref pmfnvpmfmmixmfncjvti
```

`supabase/config.toml` consente i redirect locali da `localhost:8000` e `127.0.0.1:8000`. Il Site URL è impostato temporaneamente su `http://localhost:8000`; dopo la pubblicazione sostituiscilo con l'URL del sito e aggiungi quell'URL ai redirect consentiti, mantenendo gli URL locali per lo sviluppo.

## 4. Pubblica su GitHub Pages

1. Crea un repository GitHub e carica il contenuto di questa cartella nella branch `main`.
2. In **Settings → Pages**, scegli **GitHub Actions** come fonte di pubblicazione.
3. Il workflow `.github/workflows/pages.yml` pubblica automaticamente la web app a ogni push su `main`.
4. Dopo il primo workflow completato, GitHub mostra l'URL del sito nelle impostazioni Pages e nel riepilogo del workflow.
5. Aggiungi quell'URL alla configurazione URL di Supabase indicata sopra.

Le risorse HTML, CSS e JS usano percorsi relativi, quindi funzionano anche sotto il percorso `/NOME-REPOSITORY/` di GitHub Pages.

## Come si usa

1. Gli utenti si registrano prima che l'admin avvii la serata. Chi si registra dopo l'avvio potrà partecipare alla successiva.
2. L'admin preme **Assegna le categorie**. Tutti gli account esistenti, admin incluso, ricevono una categoria.
3. Ogni utente invia una sola nomination. Gli altri vedono chi ha partecipato, senza leggere i titoli.
4. L'admin estrae un film. Tutti votano se lo hanno già visto. Il film viene approvato se meno del 60% lo ha già visto; con il 60% esatto viene sostituito.
5. Se approvato, tutti assegnano un voto. L'admin può quindi estrarre il prossimo titolo.
6. Quando il pool è vuoto e ogni film approvato ha un voto da tutti, si sblocca la classifica. L'admin rivela le posizioni in sequenza; i pari merito sono ordinati alfabeticamente per titolo.
7. Quando il podio è completo, l'admin può avviare una nuova serata.

## Nota sul login

Supabase Auth autentica con email e password. Lo username viene usato per identificare e mostrare i partecipanti; non viene usato come alias di accesso.

## Architettura e sicurezza

- Tutti i sorteggi, controlli admin, voti di verifica, conteggi e reveal passano da funzioni PostgreSQL con controlli server-side.
- Le nomination sono in una tabella con policy che permette la lettura solo all'autore. Il sorteggio trasferisce il titolo estratto in `drawn_films`, visibile ai partecipanti.
- Le risposte individuali “già visto” e i voti individuali non sono leggibili dagli altri. Il browser riceve solo i risultati aggregati necessari.
- RLS è attiva sulle tabelle esposte e il client non ha permessi di scrittura diretta sulle tabelle.
- Il ruolo admin è memorizzato in `profiles`, assegnato durante la registrazione e non modificabile dall'utente.

Questa prima versione gestisce un solo gruppo condiviso per progetto Supabase e una serata attiva alla volta.
