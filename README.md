# space_audit.sh

Audit **in sola lettura** dell'occupazione di un filesystem Linux: trova file
grandi/vecchi, mappa le directory più pesanti, evidenzia i dati oltre i 10 anni
e produce un report testuale, una dashboard HTML e gli export per la revisione.

Lo strumento **non cancella né modifica nulla** sul filesystem analizzato: usa
solo `find -printf` per leggere i metadati. Scrive esclusivamente nelle proprie
cartelle di output/log e rimuove solo i propri file temporanei.

---

## Indice

- [Sicurezza (sola lettura)](#sicurezza-sola-lettura)
- [Caratteristiche](#caratteristiche)
- [Requisiti](#requisiti)
- [Installazione](#installazione)
- [Uso](#uso)
- [Parametri](#parametri)
- [Avanzamento a schermo](#avanzamento-a-schermo)
- [Output prodotti](#output-prodotti)
- [Dashboard HTML](#dashboard-html)
- [Dati oltre i 10 anni (gz + CSV)](#dati-oltre-i-10-anni-gz--csv)
- [Come funziona](#come-funziona)
- [Prestazioni e RAM](#prestazioni-e-ram)
- [Scalabilità (filesystem molto grandi / NFS / SMB)](#scalabilità-filesystem-molto-grandi--nfs--smb)
- [Esclusioni](#esclusioni)
- [Script di monitoraggio](#script-di-monitoraggio)
- [Conformità e retention](#conformità-e-retention)
- [Limiti noti](#limiti-noti)
- [Troubleshooting](#troubleshooting)

---

## Sicurezza (sola lettura)

Garanzie di non distruttività:

- la scansione usa **solo** `find ... -printf` (lettura metadati): nessuna
  scrittura, rinomina o cancellazione sul filesystem analizzato;
- l'unico `rm` presente rimuove **solo** i temporanei creati dallo script
  (path esatti via `mktemp`, ripuliti da un `trap ... EXIT`);
- tutte le scritture avvengono in `OUTDIR`, `LOGDIR` e `WORK_TMP`, che sono
  anche esclusi dalla scansione;
- di default la scansione **non attraversa i mount point** (`-xdev`), così non
  si sconfina per errore su altri volumi.

Adatto quindi anche su share di produzione: nel peggiore dei casi consuma I/O e
CPU (mitigati con `ionice`/`nice`), mai integrità dei dati.

## Caratteristiche

- Singola materializzazione del dataset (`find` → `.tsv.gz`) riusata da tutte le
  analisi: scansione e analytics sono due fasi separate.
- Aggregatore **single-pass** con accumulo per-file O(1) sulla directory foglia
  e **rollup bottom-up** in fase finale → dimensioni/conteggi **ricorsivi** per
  directory (vedi [Come funziona](#come-funziona)).
- Distribuzione per età in 8 fasce, fino alla coorte **> 10 anni**.
- Top file per dimensione, top file più vecchi di una soglia, candidati a
  cleanup (punteggio `dimensione × ln(età+1)²`), top directory per dimensione e
  per numero file, top estensioni.
- **Avanzamento a schermo**: contatore live in scansione e **percentuale** in
  aggregazione.
- **Dashboard HTML** scura con sezioni **comprimibili** (drill-down chiusi di
  default) e sezione dedicata ai file > 10 anni.
- **Export per la revisione**: elenco completo > 10 anni in `.over10y.gz` (per
  tool esterni) e **CSV** `posizione;nome;data;peso_GB` (apribile in Excel).
- Priorità I/O/CPU bassa (`ionice -c3 nice -n19`); `pigz` se disponibile.
- Guardie di robustezza: cattura errori di `find`, cap memoria mappa directory
  (`MAX_DIR_KEYS`), `set -euo pipefail`, `LC_ALL=C`.

## Requisiti

- **bash** (lo script è bash, non POSIX sh — vedi nota CRLF in Installazione);
- `find`, `awk` (mawk o gawk), `sort`, `gzip`/`zcat`, `sed`, `date`, `df`,
  `hostname`, `du`;
- opzionali: `pigz` (compressione/decompressione parallela), `ionice`,
  `findmnt`, `realpath`, `nproc`.

Tutto è standard su una distribuzione Linux tipica. In assenza degli opzionali
lo script degrada con alternative (es. `gzip`/`zcat` al posto di `pigz`).

> **Portabilità `awk`.** I programmi `awk` evitano costrutti specifici di GNU awk
> e funzionano anche con il **mawk storico** (1.3.3) e con BusyBox: niente classi
> di caratteri con escape come `[\r\n]` né slash non escappati dentro `[^/]` nei
> *regex literal* (gawk e mawk 1.3.4 li tollerano, mawk 1.3.3 no). La separazione
> di path/nome usa `substr`/`index`, non regex con `/`.

## Installazione

```bash
chmod +x space_audit.sh
```

> **Importante (CRLF):** lo script deve avere line ending **Unix (LF)**. Se è
> stato salvato/trasferito da Windows può contenere `CR` e dare
> `syntax error near unexpected token` su Linux. Normalizzalo:
>
> ```bash
> dos2unix space_audit.sh          # oppure:
> perl -i -pe 's/\x0D//g' space_audit.sh
> # verifica (deve stampare 0):
> od -An -tx1 space_audit.sh | tr ' ' '\n' | grep -c '^0d'
> ```

`OUTDIR` e `LOGDIR` vengono creati accanto allo script (`output/` e `log/`) se
non passati esplicitamente.

## Uso

```bash
./space_audit.sh [ROOT] [OUTDIR] [TOPN] [OLD_DAYS] [YEARS_VIEW]
```

Esempi rapidi:

```bash
# audit dell'intero sistema (default)
./space_audit.sh

# audit di una share specifica, con temporanei su disco locale veloce
WORK_TMP=/var/tmp ./space_audit.sh /mnt/Antiriciclaggio_WS

# run lunga in background, log a parte
nohup ./space_audit.sh /dati > audit.out 2>&1 &
```

## Parametri

### Posizionali

| # | Nome | Default | Significato |
|---|------|---------|-------------|
| 1 | `ROOT` | `/` | Directory radice da analizzare |
| 2 | `OUTDIR` | `<dir_script>/output` | Dove scrivere gli output |
| 3 | `TOPN` | `30` | Numero di voci nelle classifiche (top file/dir…) |
| 4 | `OLD_DAYS` | `3650` | Soglia (giorni) per "recuperabile"/cleanup (≈10 anni) |
| 5 | `YEARS_VIEW` | `10` | Soglia (anni) della sezione "file più vecchi di N anni" |

### Variabili d'ambiente

| Variabile | Default | Significato |
|-----------|---------|-------------|
| `WORK_TMP` | `=OUTDIR` | Cartella per temporanei e spill di `sort`. **Mettila su disco locale veloce** se `OUTDIR` è su NFS/SMB. |
| `SCAN_JOBS` | `1` | `>1` = esegue `find` in parallelo, una sottocartella di primo livello per worker (max `SCAN_JOBS` concorrenti). Accelera molto su storage di rete (SMB/NFS) e SSD; lasciare `1` su singolo disco rotante. Vedi [Scansione parallela](#scansione-parallela). |
| `CROSS_MOUNTS` | `0` | `1` = attraversa i mount point (rimuove `-xdev`). |
| `AGG_DEPTH` | `20` | Livelli massimi di directory tracciati sotto `ROOT`. |
| `MAX_DIR_KEYS` | `5000000` | Tetto al numero di directory tracciate (guardia OOM reale: vale **sia** durante la passata, sulla mappa foglia, **sia** sul rollup finale; `0` = illimitato). Oltre il tetto i totali globali restano esatti, si perde solo il dettaglio per-directory eccedente (warning). |
| `PROGRESS_EVERY` | `1000000` | Ogni quanti file aggiornare l'avanzamento a schermo (`0` = disattiva). |
| `SORT_MEM` | `10%` | Buffer RAM per `sort` (es. `25%` su server dedicati). |
| `GZIP_LEVEL` | `6` (`1` se `FAST=1`) | Livello di compressione del dataset (`1` = CPU minima ma file più grande; `6` = bilanciato). Utile solo se la **compressione** è il collo di bottiglia (raro: di norma lo è `find`). |
| `FAST` | `0` | `1` = modalità veloce: **salta** Top Files, Older, Cleanup e l'export > 10 anni (riduce la CPU per-file: niente `ln()`, niente top-N) e abbassa `GZIP_LEVEL` a `1`. Restano KPI, distribuzione per età/tipologia/dimensione, Top directory, trend, estensioni. |
| `STREAM` | `0` | `1` = scansione+aggregazione in **streaming** (`find → awk` diretto): **non** produce il dataset `.tsv.gz` intermedio. Meno I/O e CPU (un giro gzip in meno), ma si perde l'artefatto dataset e l'avanzamento in `%` (solo conteggio). Forza la scansione seriale (`SCAN_JOBS` ignorato). |
| `FROM_DATASET` | *(vuoto)* | Path a un `.tsv.gz` **esistente**: **riaggrega senza riscansionare**. Salta del tutto il `find` (minuti invece di ore), rigenera report/HTML/CSV/JSON con un nuovo timestamp. Il dataset di input **non** viene modificato né rimosso. Vedi [Rigenerazione da dataset](#rigenerazione-da-dataset). |
| `AS_OF` | *(vuoto)* | Solo con `FROM_DATASET`: riferimento temporale per il calcolo dell'età (epoch o data leggibile da `date -d`). Default: il timestamp `YYYYMMDD_HHMMSS` estratto dal nome del dataset; fallback all'ora corrente. |
| `STRICT_SCAN` | `0` | `1` = **fallisce** (exit ≠ 0) se gli errori di `find` superano `FIND_ERR_MAX` o se lo spazio in `WORK_TMP` è sotto `MIN_FREE_MB`. Default: solo `WARNING` e prosecuzione. |
| `FIND_ERR_MAX` | `10000` | Soglia di errori `find` (accessi negati ecc.) tollerati: rilevante solo con `STRICT_SCAN=1`. |
| `MIN_FREE_MB` | `512` | Spazio minimo (MB) richiesto in `WORK_TMP`: sotto soglia → `WARNING` (o abort se `STRICT_SCAN=1`). |
| `CLEANUP_SKIP` | *(vuoto)* | Regex di path da **non** suggerire nei candidati cleanup. |
| `EXTRA_EXCLUDES` | *(vuoto)* | Glob aggiuntivi da escludere dalla scansione (separati da spazio). |

#### Robustezza e correttezza

Lo script gestisce alcuni casi limite tipici di archivi grandi e "sporchi":

- **mtime nel futuro**: i file con data di modifica futura (orologi sballati,
  copie con metadati alterati) avrebbero età negativa; l'età viene azzerata
  (`age < 0 → 0`) per non falsare le fasce né i calcoli logaritmici del cleanup.
- **profondità path**: la profondità massima è calcolata **relativa a `ROOT`**
  (livelli sotto la radice), non in valore assoluto.
- **scansione parallela**: ogni worker `find` scrive il proprio exit code; se
  un worker termina con codice ≠ 0 (di norma "permessi negati") viene loggato un
  `WARNING`. I temporanei `.part.*` usano nomi univoci (`mktemp` + timestamp del
  run) per non collidere con esecuzioni concorrenti, e vengono rimossi all'uscita.
- **spazio di lavoro**: prima della scansione viene verificato lo spazio libero
  in `WORK_TMP` (vedi `MIN_FREE_MB` / `STRICT_SCAN`).
- **nomi file "sporchi"**: un nome con **TAB** spezza i campi del TSV; il path
  viene ricomposto da tutti i campi dopo l'`mtime`, quindi è recuperato per
  intero. Un nome con **a-capo letterale** spezza il record su più righe: la coda
  (record senza i campi attesi) viene **scartata** per non gonfiare i conteggi né
  falsare le fasce d'età, con un `WARNING` di riepilogo. Il file resta contato una
  volta (dimensione ed età corrette; solo il path risulta troncato all'a-capo).
  Non si usa il parsing NUL (`-print0`) per non propagarlo a tutta la pipeline:
  su share alimentate da client Windows questi caratteri nei nomi sono comunque
  impossibili.
- **memoria su altissima cardinalità di directory**: il consumo di RAM di `awk`
  è guidato dal numero di **directory contenenti file** (non dal numero di file).
  `MAX_DIR_KEYS` limita questo numero già durante la passata (non solo nel rollup
  finale): è la vera guardia anti-OOM.
- **mount multipli + parallelismo**: con `-xdev` attivo (default) il `find`
  seriale resta sul filesystem di `ROOT`. In modalità parallela, le sottocartelle
  di primo livello che sono **mount separati** vengono escluse dalle unità di
  scan, così il risultato coincide con quello seriale. Per includere altri mount,
  usare `CROSS_MOUNTS=1` (vale per entrambe le modalità).

#### Categorie per tipologia

La classificazione per tipologia (la sola ciambella "tipologia") è **euristica,
basata sull'estensione finale** del nome: nessuna ispezione del contenuto. File
senza estensione o con estensioni non mappate finiscono in **"altri"**. Le liste
coprono i formati comuni di un archivio documentale/finanziario (inclusi
`p7m`/`p7s`/`eml`/`msg` per firme e corrispondenza, `xbrl`/`edi` per i dati
strutturati). Resta una vista **indicativa**: non incide su dimensioni, età o
aggregazione per directory, che restano esatte.

#### Note su scelte di tuning

- **`/dev/shm` come `WORK_TMP`**: possibile manualmente
  (`WORK_TMP=/dev/shm ./space_audit.sh …`) e molto veloce, **ma sconsigliato di
  default**: i temporanei e gli spill di `sort` su archivi enormi possono
  saturare la RAM. Usalo solo su host con RAM abbondante e scansioni contenute.
- **UID/GID nel dataset**: mantenuti volutamente. La raccolta è gratuita
  (`%U`/`%G` numerici, nessuna risoluzione LDAP) e sono metadati utili per
  l'audit (proprietà dei file vecchi). Per un dataset più snello li si potrebbe
  omettere, ma il guadagno è marginale e renderebbe fragile l'indicizzazione dei
  campi: non è il default.

## Avanzamento a schermo

L'avanzamento va su **stderr** con `\r` (riga che si riscrive): è visibile a
schermo ma **non sporca il file di log**.

- **Scansione** — contatore live, senza percentuale:

  ```
    scanning... 4000000 files
  ```

  La percentuale non è possibile in questa fase: il totale non è noto finché
  `find` non ha finito di percorrere l'albero.

- **Aggregazione** — **percentuale reale** (file processati / totale rilevato in
  scansione):

  ```
    aggregating... 42.5% (7200000/16900000)
  ```

La granularità si regola con `PROGRESS_EVERY` (più basso = aggiornamenti più
frequenti; `0` = nessun avanzamento). Le fasi successive (sort, HTML, CSV) sono
rapide rispetto a scan+aggregazione e mostrano solo i messaggi di fase nel log.

## Output prodotti

Tutti i file hanno prefisso `<host>_<root_tag>_<timestamp>` in `OUTDIR`
(il log in `LOGDIR`):

| File | Contenuto |
|------|-----------|
| `…​.tsv.gz` | **Dataset** per-file compresso (vedi formato sotto). È la base riusata da tutte le analisi. *Assente in modalità `STREAM`.* |
| `…​.txt` | **Report** testuale (tutte le sezioni; in `FAST` Top Files/Older/Cleanup risultano vuote). |
| `…​.html` | **Dashboard** HTML (sezioni comprimibili). |
| `…​.over10y.gz` | Elenco **completo** dei file > 10 anni, ordinato per dimensione (solo se presenti; **non** generato in `FAST`). Per tool esterni. |
| `…​.over10y.csv` | Elenco file > 10 anni per la **revisione in Excel** (solo se presenti; **non** generato in `FAST`). |
| `…​.summary.json` | **Riepilogo machine-readable** (totali, errori, esito) per integrazione con monitoring/PRTG. Vedi [Exit code e summary JSON](#exit-code-e-summary-json). |
| `log/…​.log` | Log con timestamp di tutte le fasi. |

### Formato dataset (`.tsv.gz`)

Una riga per file, campi separati da TAB:

```
size_bytes <TAB> uid <TAB> gid <TAB> mtime_epoch <TAB> path
```

UID/GID sono **numerici** (nessuna risoluzione LDAP/AD, per velocità e per non
dipendere dal name service). Esempio di consumo:

```bash
# top 20 file per dimensione direttamente dal dataset
zcat host_root_20250101_120000.tsv.gz | sort -t$'\t' -k1,1nr | head -20
```

### Formato `.over10y.gz`

TSV con intestazione, ordinato per dimensione decrescente, elenco completo:

```
size_bytes <TAB> age_days <TAB> mtime_epoch <TAB> path
```

### Formato `.over10y.csv`

Pensato per **apertura diretta in Excel (locale italiana)**:

- separatore `;`, decimale con la virgola, **BOM UTF-8**, righe **CRLF**;
- colonne: `posizione;nome;data;peso_GB`
  - `posizione` = directory del file, `nome` = nome file,
  - `data` = data di modifica (mtime) locale, formato `YYYY-MM-DD` (granularità
    al giorno),
  - `peso_GB` = dimensione in GB (es. `0,0088`);
- nomi/percorsi che contengono `;` o `"` sono correttamente quotati (RFC 4180);
- ordinato per peso decrescente.

> Per elaborazioni programmatiche (join con il gestionale) conviene
> `.over10y.gz`: TSV con byte ed epoch grezzi, più adatto del CSV pensato per
> Excel.

### Exit code e summary JSON

Lo strumento ha un **contratto di exit code** pensato per l'esecuzione
automatica/monitoring:

| Codice | Significato |
| --- | --- |
| `0` | Completato senza problemi. |
| `1` | Errore **fatale** (dataset vuoto, abort `STRICT_SCAN`, spazio insufficiente in `WORK_TMP` con `STRICT_SCAN=1`). Nessun report prodotto. |
| `2` | Completato **con warning** (errori di accesso di `find`, mappa directory limitata da `MAX_DIR_KEYS`, worker in errore, spazio sotto soglia). I report **sono** prodotti, ma i dati potrebbero essere parziali. |

A fine run viene scritto un sidecar `…summary.json` a un solo livello, per
agganciarlo a un sensore PRTG (*EXE/Script Advanced*) o a qualsiasi pipeline:

```json
{
  "host": "psm-nfs-01", "root": "/", "timestamp": "20260622_143252",
  "mode": "normal", "files": 36231, "bytes": 489318670405,
  "bytes_human": "455.71 GB", "directories_with_files": 5210,
  "over10y_count": 550, "over10y_bytes": 21500000,
  "reclaimable_bytes": 7657446, "owners_distinct": 12,
  "find_errors": 0, "workers_failed": 0, "dir_cap_hit": false,
  "max_depth": 11, "duration_s": 1, "exit_status": 0
}
```

> Nota: l'exit code `2` **non** è un fallimento — molti scheduler lo trattano
> come tale, quindi gestiscilo esplicitamente (es. mappa `2` → *Warning* nel
> sensore).

## Top proprietari

Il dataset raccoglie già UID/GID; lo strumento aggrega lo spazio **per
proprietario** e ne mostra i primi `TOPN` (card HTML "Top proprietari per
spazio" + sezione `TOP OWNERS` nel report). Gli UID vengono risolti a nome con
`getent passwd` (lookup mirato, niente enumerazione dell'intera directory AD);
gli UID **orfani** (senza voce in `passwd`, tipici di file migrati da altri
sistemi) sono mostrati come `uid N`. Utile per attribuire la responsabilità dei
dati vecchi/voluminosi in contesto di audit.

## Dashboard HTML

Tema scuro in stile **dashboard esecutiva**, su singolo file autoconsistente e
offline (nessuna libreria/CDN: tutti i grafici sono SVG disegnati in JavaScript
vanilla). In testa cinque KPI: spazio totale scansionato (con byte esatti),
file totali, directory con contenuto, data e durata scansione.

Sotto i KPI, una **panoramica esecutiva** a pannelli:

- **Filtri applicati**: percorso, profondità directory, file system, numero di
  esclusioni attive, attraversamento mount.
- **Distribuzione spazio per età** (grafico **pentagonale**/radar a 5 assi, uno
  per fascia: 0-1 / 1-2 / 2-5 / 5-10 / > 10 anni) con legenda (dimensione e %) e
  callout sulla quota oltre i 10 anni. Ogni vertice è proporzionale alla quota di
  spazio della fascia.
- **Top 10 directory per spazio** (tabella con dimensione e % sul totale, più
  riga "Altre directory").
- **Trend spazio nel tempo**: area cumulativa per età di ultima modifica.
- **Distribuzione per tipologia file** (ciambella per spazio) con categorie
  euristiche da estensione: dati, multimediali, documenti, archivi, database, altri.
- **Distribuzione per dimensione file** (barre orizzontali per numero di file)
  su 5 fasce (< 1 KB, < 1 MB, < 100 MB, < 1 GB, ≥ 1 GB).
- **Statistiche aggiuntive**: dimensione media, file più grande, più recente e
  più vecchio (da min/max mtime), profondità massima.
- **Legenda età file**, **Riepilogo esecutivo** e **Output generati**.

Tutti i grafici hanno **tooltip** al passaggio del mouse.

> **Note di onestà sui dati.** *Hard link* e *symbolic link* sono mostrati come
> `n/d`: la scansione di sola lettura (`-type f`) non raccoglie il conteggio dei
> link né attraversa i symlink, quindi quei numeri richiederebbero dati extra
> (campo `%n` e/o un passaggio `-type l`). La voce "Directory" conta le
> **directory contenenti file** (esatta e a costo zero); il totale assoluto
> richiederebbe un passaggio `-type d`. Le bande d'età usano i confini reali
> dello script.

Sotto la panoramica, una **barra strumenti** con:

- **Ricerca live**: filtra in tempo reale tutte le righe di dettaglio per
  percorso (directory, file, estensione), apre le sezioni con risultati, attenua
  quelle senza e mostra il conteggio. Pulsante per azzerare.
- **Espandi / Comprimi tutto** sulle sezioni di dettaglio.

- **Sezioni di dettaglio comprimibili** (`<details>` chiusi di default, con badge
  conteggi): distribuzione per età estesa, filesystem, top directory per
  dimensione e per numero, top estensioni, top file, candidati cleanup.
- **Sezione dedicata "File oltre i 10 anni"** e **banner** rosso quando presenti.

> La pagina resta leggibile anche senza JavaScript (i `<details>` sono nativi):
> si perdono solo ricerca e grafici.

## Dati oltre i 10 anni (gz + CSV)

La coorte > 10 anni (mtime oltre 3650 giorni) è estratta **riusando lo stream
già ordinato per dimensione** della classifica file (nessuna scansione extra) e
prodotta in tre forme: la sezione HTML, l'elenco completo `.over10y.gz` e il CSV
di revisione. Esempi d'uso del gz:

```bash
# elenco path (salta intestazione), uno per riga
zcat host_root_*.over10y.gz | tail -n +2 | cut -f4

# consumo sicuro con spazi/caratteri speciali nei path (sostituisci l'azione)
zcat host_root_*.over10y.gz | tail -n +2 | cut -f4 \
  | while IFS= read -r p; do printf 'GESTIRE: %s\n' "$p"; done
```

## Come funziona

Pipeline a due fasi, con il dataset `.tsv.gz` come confine:

1. **Scansione** — `find -printf | awk (contatore) | gzip > .tsv.gz`. L'`awk` di
   passaggio fa solo da contatore (progress) e non aggiunge decompressioni.
2. **Aggregazione** (un solo passaggio sul dataset decompresso): calcola
   **tutto** in memoria, senza riletture né sort globale:
   - per ogni file: totali, fasce d'età, estensione, e **accumulo sulla sola
     directory foglia** (il parent del file) — costo **O(1)** per file, niente
     loop sugli antenati;
   - mantiene direttamente i **top-N** in memoria (top file per dimensione, file
     più vecchi della soglia, candidati cleanup per punteggio) con inserimento
     O(1) ammortizzato — **niente `sort` sull'intero dataset**;
   - scrive le righe della coorte **> 10 anni** in un file grezzo (per gli export);
   - in fase finale, **rollup bottom-up**: una sola volta per directory foglia
     si risalgono gli antenati (fino a `AGG_DEPTH` livelli) sommando i totali →
     si ottengono le dimensioni/conteggi **ricorsivi** per directory (ogni
     directory include tutto ciò che sta sotto di essa, come `du`).
3. **Ordinamenti finali** — solo su dati già piccoli: i top-N (≤ `TOPN` righe) e
   le mappe directory/estensioni; più un `sort` del **solo** sottoinsieme > 10
   anni (non dell'intero dataset). Il dataset completo viene quindi letto **una
   sola volta** (in aggregazione), non tre.
4. **Render** — report TXT, dashboard HTML, export gz/CSV.

Output identico alla versione precedente basata sui sort globali (verificato a
parità di sezioni del report e di export): è un'ottimizzazione, non un cambio di
semantica. L'aggregatore leaf + rollup produce a sua volta le stesse mappe
directory del vecchio walk per-file.

## Prestazioni e RAM

- **Analytics a passaggio unico**: top file, file vecchi e candidati cleanup
  sono calcolati in memoria **durante** l'aggregazione (O(N), niente `sort`
  sull'intero dataset). Rispetto allo schema precedente questo elimina due
  riletture complete del dataset e i due grandi `sort`: su un campione realistico
  da 2 milioni di righe la fase analitica oltre l'aggregazione passa da ~7,5s a
  ~1,5s (resta solo l'ordinamento del sottoinsieme > 10 anni). Il risparmio
  cresce linearmente col numero di file ed è maggiore quando il dataset è su
  storage lento (meno letture).
- Il **rollup** sposta la risalita degli antenati da *per-file* a *per-directory
  foglia*: poiché i file sono molti di più delle directory, su filesystem reali
  (molti file per cartella) la fase di aggregazione è **circa la metà** rispetto
  al loop per-file. Su alberi a cardinalità di directory altissima (quasi una
  directory per file) il guadagno è minore, ma non è mai più lento.
- Con questo schema il **costo per-file non dipende più da `AGG_DEPTH`**: la
  profondità incide solo sul rollup (economico), quindi si può tenere
  `AGG_DEPTH=20` senza penalità per-file.
- Il collo di bottiglia complessivo, su volumi grandi e in rete, resta la
  **scansione** (latenza di `find` sullo storage), non l'aggregazione.

**RAM** — dominata dalla mappa directory: cresce col numero di directory
distinte tracciate (≈ `AGG_DEPTH` livelli), non col numero di file. Su alberi
con cardinalità di directory enorme la mappa può crescere: la guardia
`MAX_DIR_KEYS` la limita (se scatta, nel log compare un warning e la sezione
TOP DIRECTORIES può risultare parziale; aumenta `MAX_DIR_KEYS` o abbassa
`AGG_DEPTH`). Il `sort` usa al più `SORT_MEM` di RAM e fa spill su `WORK_TMP`.

## Scalabilità (filesystem molto grandi / NFS / SMB)

### Scansione parallela

Su storage di rete (SMB/NFS) il collo di bottiglia è la **latenza per-file** dei
metadati: un singolo `find` ha una sola richiesta in volo per volta. Impostando
`SCAN_JOBS>1` lo script lancia un `find` per ogni sottocartella di primo livello
di `ROOT`, fino a `SCAN_JOBS` in parallelo (più i file direttamente in `ROOT`),
scrivendo su file temporanei separati (nessun rischio di interleaving), poi
unendo e comprimendo. Le stesse opzioni (`-xdev`, esclusioni) sono applicate a
ogni worker: **il dataset prodotto è identico a quello seriale** (verificato).

```bash
SCAN_JOBS=6 WORK_TMP=/var/tmp ./space_audit.sh /mnt/Antiriciclaggio_WS
```

Note:
- l'efficacia dipende dall'avere **più sottocartelle di primo livello popolate**;
  se quasi tutti i file stanno sotto un'unica cartella di 1° livello, il
  parallelismo a questo livello aiuta poco;
- la modalità parallela scrive i temporanei non compressi in `WORK_TMP`: serve
  spazio locale (mettilo su SSD/NVMe);
- lo split avviene per sottoalbero con `-xdev` per worker: per un `ROOT` che
  attraversa **più mount point** preferire la modalità seriale o `CROSS_MOUNTS`;
- su singolo disco rotante locale la parallelizzazione può *peggiorare* i tempi
  (seek): lasciare `SCAN_JOBS=1`.

### Uso di memoria e cardinalità delle directory

L'aggregatore tiene in RAM una mappa delle **directory foglia** (quelle che
contengono direttamente file): la memoria cresce col numero di *directory*, non
di file. Per i filesystem tipici (anche con milioni di file) è trascurabile.
`MAX_DIR_KEYS` protegge dall'OOM limitando le chiavi della mappa finale: oltre
la soglia il report segnala `directory map capped` e i totali/Top file restano
comunque corretti (si riduce solo il dettaglio per-directory).

A cardinalità **estrema** (ordine di decine di milioni di directory foglia, es.
certi object store) la mappa foglia può diventare grande prima del rollup. In
quello scenario la strada corretta è un'aggregazione *streaming* (scrivere
`dir<TAB>size` su disco e poi `sort | groupby`), che però reintroduce un
ordinamento sull'intero insieme — il contrario dell'attuale passaggio unico
senza sort. Per i volumi previsti qui non serve; è documentato come limite noto.

### Rigenerazione da dataset

Lo `.tsv.gz` prodotto da una scansione è la base di tutte le analisi: si può
**riaggregare senza riscansionare**, riusando il dataset esistente. Su uno share
da milioni di file questo trasforma ore di `find` in **minuti** di sola
rielaborazione, e permette di cambiare i parametri di analisi a costo quasi nullo.

```bash
# riaggrega un dataset esistente con profondità di rollup ridotta
FROM_DATASET=/var/tmp/space_audit/output/host_root_20260622_114930.tsv.gz \
  AGG_DEPTH=6 WORK_TMP=/var/tmp ./space_audit.sh /mnt/Antiriciclaggio_WS
```

- Salta del tutto il `find`: nessuna scansione, nessun nuovo `.tsv.gz`.
- Rigenera report/HTML/CSV/JSON con un **nuovo timestamp** (gli output originali
  restano).
- Il dataset di input **non** viene toccato né rimosso.
- `ROOT` deve essere **lo stesso** della scansione originale (serve a calcolare
  etichette e profondità delle directory; i percorsi nel dataset sono assoluti).
- **Età**: poiché il dataset può essere vecchio, l'età si calcola rispetto al
  momento della scansione (timestamp nel nome del file), non a "adesso";
  sovrascrivibile con `AS_OF`.

### Profondità di rollup (`AGG_DEPTH`) sui grandi alberi

Il rollup finale (somma bottom-up per directory) ha un costo proporzionale al
numero di directory foglia **per** i livelli di antenati aggregati, fino a
`AGG_DEPTH` livelli sotto la radice. Su alberi **molto profondi e con milioni di
directory**, il default `AGG_DEPTH=20` può rendere la fase finale di
aggregazione estremamente lenta (CPU al 100% senza I/O, anche per ore).

In quel caso **abbassa `AGG_DEPTH`** (es. `6`–`8`): il rollup diventa molto più
leggero e la classifica "Top directory" resta significativa (le cartelle più
profonde vengono aggregate al loro antenato a `AGG_DEPTH` livelli). **I totali
globali, le fasce d'età, le tipologie e i Top file restano esatti** a qualunque
`AGG_DEPTH`. Combinato con `FROM_DATASET`, puoi correggere il tiro su una
scansione già fatta senza rieseguirla.

### Altre note

- Metti `WORK_TMP` su **disco locale veloce** (es. `WORK_TMP=/var/tmp`): i
  temporanei e lo spill di `sort` non devono finire su NFS/SMB lento.
- Lancia con `nohup` (run lunghe). La priorità bassa (`ionice`/`nice`) riduce
  l'impatto su sistemi in produzione.
- `SORT_MEM=25%` (o più) su server dedicati accelera i `sort` (riduce gli spill).
- `pigz` (se installato) parallelizza compressione e decompressione del dataset.

## Esclusioni

Di default vengono "prunate" (non scansionate):

```
/proc /sys /dev /run /var/lib/docker /var/lib/containerd /snap /mnt /media
```

più `OUTDIR`, `LOGDIR` e `WORK_TMP`. Aggiunte personalizzate via
`EXTRA_EXCLUDES`.

**Guardia anti-radice:** se un'esclusione coincide con `ROOT` o ne è un antenato
viene saltata (altrimenti `ROOT` verrebbe escluso e il dataset risulterebbe
vuoto). Così, ad esempio, è possibile lanciare l'audit con `ROOT=/mnt/...` anche
se `/mnt` è tra le esclusioni di default.

## Script di monitoraggio

`space_audit_monitor.sh` (v3.1) è un diagnostico **in sola lettura** da lanciare
in un'**altra shell** mentre l'audit gira, per capire a che punto è e cosa sta
facendo. Legge solo `/proc` e `ps`: **non scrive nulla** e non tocca né lo
strumento né il filesystem scansionato.

### Avvio

```bash
./space_audit_monitor.sh        # uno snapshot e termina
./space_audit_monitor.sh 2      # si aggiorna ogni 2 secondi (Ctrl-C per uscire)
```

Si lancia in qualsiasi momento, senza coordinarsi con l'audit: trova da solo il
processo `space_audit.sh` in corso. Conviene eseguirlo **come lo stesso utente**
dell'audit (o root): alcune letture (`/proc/<pid>/io`, strace) altrimenti non
sono accessibili e vengono semplicemente saltate con un messaggio.

### Variabili d'ambiente

| Variabile | Default | Effetto |
| --- | --- | --- |
| `MON_STRACE` | `0` | `1` = aggiunge un campione `strace -c` di 1s sul processo più attivo. **È l'unica parte intrusiva**: l'attach `ptrace` mette in pausa il target a ogni syscall, quindi su una scansione che ne fa milioni al secondo la **rallenta** per quel secondo. Tenerlo spento salvo necessità. |
| `MON_CPU_DT` | `0.3` | Ampiezza (secondi) della finestra per il calcolo della **CPU istantanea**. Più larga = misura più stabile ma snapshot più lento. |

### Consapevolezza delle fasi

Riconosce i processi figli dell'audit per **firma di cmdline** (`find … %T@`,
`awk … maxk=`, `sort … -T`) e li filtra per **discendenza** dal processo
principale, così non li confonde con `find`/`awk`/`sort` estranei in esecuzione
sul sistema. La fase mostrata e i dettagli relativi:

- **SCAN** — elenca i worker `find` attivi (anche in parallelo); per ognuno la
  CPU istantanea e, in modalità parallela, il file `.part.*` che sta scrivendo
  con la dimensione corrente (più il totale dei temporanei). Mostra anche quanto
  è cresciuto finora il dataset `.tsv.gz`. La **% non è disponibile** in questa
  fase: il totale dei file non è noto finché `find` non termina.
- **AGGREGAZIONE** — PID, CPU e RSS dell'`awk` aggregatore, con l'**avanzamento %**
  ricavato dalla posizione di lettura del dataset (`/proc/<pid>/fdinfo`) rapportata
  alla dimensione del `.tsv.gz`.
- **AGGREGAZIONE (rollup / finalizzazione)** — quando il dataset è stato **letto
  per intero** (il decompressore è uscito) ma l'`awk` è ancora attivo: sta
  eseguendo il consolidamento gerarchico finale (rollup). Il monitor lo distingue
  esplicitamente e ricorda che, con CPU ~100% e nessun I/O di lettura, **non è un
  blocco**: il completamento si vede in `[I/O]` quando `wchar` inizia a salire
  (scrittura delle mappe directory). Lo stesso avanzamento è ora stampato anche
  dallo script (`rollup: consolidamento di N directory foglia… / rollup completato`).
- **SCAN+AGGREGAZIONE (streaming)** — in modalità `STREAM=1` le due fasi sono
  **fuse** (il `find` alimenta direttamente l'`awk`, senza dataset): il monitor lo
  rileva e segnala che l'avanzamento % non è disponibile (non c'è dataset da cui
  leggerlo).
- **VISTE** — gli ordinamenti finali (`sort` dei top-N e del sottoinsieme > 10
  anni).

Quando non rileva nessuna fase attiva, lo stato è
`(inattivo / render / completato)`: l'audit non è in corso, oppure è nella breve
fase finale di scrittura di report/HTML/CSV/JSON (che non ha processi
caratteristici da intercettare).

### Lettura dell'output

- **`Audit PID` / `Comando`** — processo principale e riga di comando con cui è
  stato lanciato (utile per ricontrollare ROOT, OUTDIR ed eventuali variabili).
- **CPU%** — è **istantanea** (delta di `utime+stime` da `/proc/<pid>/stat` sulla
  finestra `MON_CPU_DT`), non la media di vita di `ps`. Un `?` indica un processo
  troppo effimero per essere campionato nella finestra (tipico solo su scansioni
  brevissime; su milioni di file i processi sono longevi e mostrano valori pieni).
- **`[RISORSE]`** — tabella compatta con CPU istantanea, RSS ed `elapsed` di tutti
  i processi coinvolti.
- **`[I/O]`** — contatori da `/proc/<pid>/io` del processo più attivo (byte
  letti/scritti): utile per distinguere se è I/O-bound (tipico in SCAN su SMB) o
  CPU-bound (tipico in AGGREGAZIONE).
- **`[STRACE]`** — di default segnala solo che è disattivato; con `MON_STRACE=1`
  mostra il profilo delle syscall dell'ultimo secondo.

### Requisiti e degradazione

Richiede `bash`, `awk`, `ps`, `stat`, `readlink` e l'accesso a `/proc` (standard
su Linux). `strace` e `/proc/<pid>/io` richiedono lo **stesso utente** dell'audit
(o root) e un `ptrace_scope` permissivo; in mancanza, il monitor degrada con
messaggi espliciti **senza fallire**. Il riconoscimento del processo principale
usa il nome `space_audit.sh`: se lo script è stato rinominato, le fasi restano
comunque rilevate per firma, ma senza il filtro per discendenza (potrebbero
comparire `find`/`awk`/`sort` estranei).

### Esempio d'uso tipico

```bash
# Terminale 1: avvia l'audit di un grande share
./space_audit.sh /mnt/Antiriciclaggio_WS

# Terminale 2: osserva l'andamento ogni 3 secondi
./space_audit_monitor.sh 3
```

## Conformità e retention

Importante per gli audit con finalità di retention legale (es. archivi
antiriciclaggio):

- lo strumento usa **`mtime`**, che **non è l'orologio della retention legale**.
  Il termine di conservazione vive nei metadati dell'applicazione gestionale,
  non nell'`mtime` del file; inoltre i software di backup/restore possono
  alterare l'`mtime`;
- la coorte > 10 anni (sezione HTML, `.over10y.gz`, CSV) è quindi una **lista di
  candidati** da incrociare con le date autoritative del gestionale, **non** un
  verdetto di cancellabilità;
- lo strumento è in sola lettura: utile come ricognizione preliminare, sicuro in
  contesti di conformità. Non costituisce parere legale: la decisione spetta a
  compliance/legale.

## Limiti noti

- `mtime` come unica data (no `atime`/`ctime`/date applicative).
- UID/GID numerici (la risoluzione a nome avviene solo per i Top proprietari, via `getent`).
- Estensione = ultima estensione in minuscolo (es. `archivio.tar.gz` → `gz`); i
  file senza estensione o "dotfile" vanno in `none`.
- L'HTML mostra i primi `TOPN` per sezione; gli elenchi completi > 10 anni sono
  nel gz/CSV.
- **`MAX_DIR_KEYS` è ora inerte**: il rollup delle directory usa un *sort esterno*
  (RAM costante, su disco) senza più alcun tetto, quindi le TOP DIRECTORIES sono
  sempre complete. La variabile resta per retrocompatibilità ma non ha effetto.
- **Nomi file "sporchi"**: i file con *newline*, *TAB* o byte di controllo (`0x01`)
  nel nome non sono rappresentabili in modo affidabile nel dataset TSV. Vengono
  **contati e riportati** come `Skipped (malformed)` nel report e `skipped_malformed`
  nel JSON; i loro *byte* non sono conteggiabili (il record è corrotto). Su 17,4M
  file reali erano 8 — impatto trascurabile, ma esposto per trasparenza.
- **Fotografia non atomica (intrinseco)**: la scansione di un filesystem *vivo* non
  è istantanea. Se durante lo scan vengono creati/cancellati/modificati file (utenti,
  backup, job notturni), il totale riflette uno stato "spalmato" sul tempo di
  scansione, non un istante preciso. Non è correggibile in alcuno strumento di
  questo tipo; per massima coerenza scansionare uno snapshot read-only (LVM/ZFS) o
  in finestra di bassa attività.
- **Date a granularità giornaliera e DST**: il CSV > 10 anni usa l'offset di fuso
  corrente calcolato una volta; attorno al cambio ora solare/legale una data potrebbe
  risultare spostata di un'ora, e quindi raramente di un giorno. Impatto pratico
  trascurabile (soglie a 10 anni).

### Portabilità

- Pensato per **GNU coreutils** (Linux). Su `sort` vengono rilevate a runtime le
  estensioni `--parallel`, `-S`, `-T` e usate solo se disponibili: su `sort`
  **BusyBox**/appliance embedded lo strumento funziona comunque (senza parallelismo
  e tuning della RAM di sort).
- Lo **scan parallelo** (`SCAN_JOBS > 1`) richiede `wait -n` (**Bash ≥ 4.3**); su
  versioni più vecchie viene forzato automaticamente lo scan seriale.
- `awk`: compatibile con **mawk 1.3.x** e gawk (nessuna regex con classi di
  caratteri contenenti `/`, nessun escape in bracket-class).

## Troubleshooting

| Sintomo | Causa / Rimedio |
|---------|-----------------|
| `syntax error near unexpected token` all'avvio | Line ending CRLF. Normalizza con `dos2unix`/`perl` (vedi [Installazione](#installazione)). |
| `ERROR: empty dataset` | Nessun file trovato (ROOT vuota o tutto escluso) o scansione fallita. Verifica `ROOT` e le esclusioni; controlla il log. |
| Warning "mappa directory limitata a MAX_DIR_KEYS" | Troppe directory distinte. Aumenta `MAX_DIR_KEYS` o abbassa `AGG_DEPTH`. |
| Warning "find ha riportato N errori di accesso" | Permessi su alcune sottocartelle; la scansione è potenzialmente parziale (esempi nel log). |
| `sort` lento o spazio temporaneo esaurito | Imposta `WORK_TMP` su disco locale capiente e veloce; eventualmente aumenta `SORT_MEM`. |
| `write error: Bad file descriptor` con `WORK_TMP`/`OUTDIR` su mount particolari | Alcuni filesystem speciali non gradiscono temporanei+spill+redirect. Punta `WORK_TMP` (e se serve `OUTDIR`) su disco locale, es. `WORK_TMP=/var/tmp`. |
| Avanzamento non visibile | È su **stderr**: non redirigerlo via `2>/dev/null`. Per output più fitto abbassa `PROGRESS_EVERY`. |
