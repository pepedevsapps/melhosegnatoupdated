# Me l'ho segnato — Serata cinema

Web app responsive, pubblicabile su GitHub Pages. Usa Supabase Auth e Postgres per gli account e i dati della serata.

## Funzioni incluse

- Registrazione con username, email e password; accesso con email e password.
- Profilo admin riservato allo username `pepe1914`.
- Una serata attiva per progetto Supabase; all'avvio vengono inclusi gli account già registrati.
- Draft delle categorie: l'admin avvia un ordine casuale persistente e i partecipanti scelgono una categoria libera a turno. L'avvio richiede almeno una categoria per ogni account partecipante.
- Bonus di scelta lineare da 0 al primo turno a 0,5 all'ultimo; il punteggio finale applica il bonus una sola volta alla media del film.
- Nomination privata: ogni partecipante vede il proprio titolo e lo stato di invio degli altri, ma non i loro titoli.
- Ricerca OMDb dei titoli con completamento automatico. I dettagli, la locandina e la valutazione IMDb compaiono quando l'admin estrae il film.
- Sorteggio casuale da parte dell'admin. Ogni nomination estratta esce definitivamente dal pool.
- Verifica anonima “L'ho visto / Non l'ho visto”, con conteggio dei voti e percentuale aggregata in tempo reale. Se più del 55% dichiara di averlo già visto, chi ha proposto il film può sostituire il titolo sulla stessa estrazione; la verifica riparte da zero.
- Valutazione dei film approvati da 1 a 5 popcorn, con mezzi punti.
- Risultati provvisori e progresso delle valutazioni durante la serata. La classifica finale viene pubblicata solo quando l'admin finalizza.
- Classifica ordinata per punteggio finale, media non corretta come spareggio e pari merito condivisi; le valutazioni mancanti non vengono conteggiate.
- La schermata finale mostra film, categoria, partecipante che ha scelto la categoria, posizione, numero di voti, media, bonus e punteggio finale, oltre alla schermata vincitore con coriandoli.
- I titoli duplicati nella stessa serata sono rifiutati dopo normalizzazione di maiuscole e spazi.
- Aggiornamento automatico della dashboard ogni 12 secondi, oltre al pulsante Aggiorna.

## Requisiti

- Un progetto Supabase.
- Un repository GitHub con GitHub Pages abilitato tramite GitHub Actions.
- Un indirizzo email da associare all'account admin.
- Un browser moderno con accesso a internet (la libreria Supabase JS viene caricata da jsDelivr).
- Una chiave API OMDb configurata come secret della Supabase Edge Function.

## 1. Configura Supabase

1. Crea un nuovo progetto Supabase.
2. Apri **SQL Editor**, incolla tutto il contenuto di `supabase/schema.sql` ed eseguilo. Lo script inizializza il progetto e può essere rieseguito per aggiornare funzioni e colonne.
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

`supabase/config.toml` imposta il Site URL di produzione su `https://pepedevsapps.github.io/melhosegnatoupdated/` e consente i redirect sia dal sito pubblicato sia dagli indirizzi locali `localhost:8000` e `127.0.0.1:8000`.

## OMDb

La chiave OMDb non va inserita nel browser o nel repository. Impostala come secret Supabase e pubblica la Edge Function:

```bash
npx supabase secrets set OMDB_API_KEY="LA_TUA_CHIAVE" --project-ref pmfnvpmfmmixmfncjvti
npx supabase functions deploy omdb --project-ref pmfnvpmfmmixmfncjvti
```

Le ricerche partono dopo una pausa nella digitazione, da tre caratteri in su, e i risultati vengono riutilizzati nella sessione e in cache condivisa. Il database blocca le richieste quando raggiungono 950 chiamate in una finestra mobile di 24 ore, lasciando 50 chiamate di margine sul limite OMDb di 1.000. I dettagli di ogni titolo vengono recuperati una sola volta e conservati per 180 giorni.

## 4. Pubblica su GitHub Pages

Il progetto è pubblicato su [GitHub](https://github.com/pepedevsapps/melhosegnatoupdated) e disponibile su [GitHub Pages](https://pepedevsapps.github.io/melhosegnatoupdated/). Il workflow `.github/workflows/pages.yml` pubblica automaticamente gli aggiornamenti a ogni push su `main`.

Le risorse HTML, CSS e JS usano percorsi relativi, quindi funzionano anche sotto il percorso `/NOME-REPOSITORY/` di GitHub Pages.

## Come si usa

1. Gli utenti si registrano prima che l'admin avvii la serata. Chi si registra dopo l'avvio potrà partecipare alla successiva.
2. L'admin preme **Avvia il draft categorie**. Il database salva un ordine casuale di tutti gli account già registrati, admin incluso.
3. I partecipanti scelgono una categoria libera uno alla volta nell'ordine mostrato. L'ordine e il bonus restano salvati anche dopo un aggiornamento della pagina.
4. Ogni utente invia una sola nomination. Gli altri vedono chi ha partecipato, senza leggere i titoli.
5. L'admin estrae un film. Tutti votano se lo hanno già visto. I conteggi sono anonimi; il film viene rifiutato se più del 55% risponde “L'ho visto”.
6. Se il film viene rifiutato, chi ha inviato la nomination lo sostituisce. Il titolo cambia sulla stessa estrazione e tutti votano di nuovo. Se viene approvato, tutti possono assegnare o aggiornare la propria valutazione.
7. La sezione Partecipanti mostra risultati provvisori e progresso dei voti. Quando tutte le nomination sono state estratte e le verifiche sono concluse, l'admin preme **Concludi e pubblica classifica**. Le valutazioni mancanti sono escluse dalle medie.
8. La classifica finale applica il bonus una sola volta al punteggio medio del film. Dopo la pubblicazione l'admin può avviare una nuova serata.

## Nota sul login

Supabase Auth autentica con email e password. Lo username viene usato per identificare e mostrare i partecipanti; non viene usato come alias di accesso.

## Architettura e sicurezza

- Tutti i sorteggi, controlli admin, voti, conteggi, punteggi e finalizzazione passano da funzioni PostgreSQL con controlli server-side.
- L'ordine del draft, i turni e le categorie scelte sono salvati nel database. Le RPC impediscono turni anticipati e categorie già selezionate.
- I punteggi provvisori e finali sono aggregati lato server; solo l'admin può finalizzare la serata, senza esporre i voti individuali.
- Le nomination sono in una tabella con policy che permette la lettura solo all'autore. Il sorteggio trasferisce il titolo estratto in `drawn_films`, visibile ai partecipanti.
- Le risposte individuali “già visto” e i voti individuali non sono leggibili dagli altri. Il browser riceve solo i risultati aggregati necessari.
- RLS è attiva sulle tabelle esposte e il client non ha permessi di scrittura diretta sulle tabelle.
- Il ruolo admin è memorizzato in `profiles`, assegnato durante la registrazione e non modificabile dall'utente.

Questa prima versione gestisce un solo gruppo condiviso per progetto Supabase e una serata attiva alla volta.
