#!/usr/bin/env bash
#
# space_audit.sh - READ-ONLY storage audit.
# Non distruttivo: legge il filesystem (find -printf), non cancella ne' modifica
# nulla. Scrive solo in OUTDIR/LOGDIR (accanto allo script). Rimuove solo i
# propri file temporanei (mktemp).
#
set -euo pipefail
export LC_ALL=C

###############################################################################
# CONFIG
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

ROOT="${1:-/}"
OUTDIR="${2:-$SCRIPT_DIR/output}"
TOPN="${3:-30}"
OLD_DAYS="${4:-3650}"
YEARS_VIEW="${5:-10}"

LOGDIR="$SCRIPT_DIR/log"

CROSS_MOUNTS="${CROSS_MOUNTS:-0}"        # 1 = attraversa i mount point
AGG_DEPTH="${AGG_DEPTH:-20}"             # livelli max tracciati sotto ROOT
CLEANUP_SKIP="${CLEANUP_SKIP:-}"        # regex: path da NON suggerire in cleanup
EXTRA_EXCLUDES="${EXTRA_EXCLUDES:-}"    # glob extra da pruneare (whitespace-sep)
PROGRESS_EVERY="${PROGRESS_EVERY:-1000000}"  # progress ogni N file (0 = off)
SCAN_JOBS="${SCAN_JOBS:-1}"              # 1 = scan seriale; >1 = find paralleli per sottocartella
SORT_MEM="${SORT_MEM:-10%}"            # buffer RAM per sort (es. 25% su server dedicati)
MAX_DIR_KEYS="${MAX_DIR_KEYS:-5000000}"  # cap chiavi mappa directory (0 = illimitato): guardia OOM
WORK_TMP="${WORK_TMP:-}"               # dir per temporanei e spill sort (default: OUTDIR)
STRICT_SCAN="${STRICT_SCAN:-0}"          # 1 = abortisce se errori find > FIND_ERR_MAX o spazio insufficiente
FIND_ERR_MAX="${FIND_ERR_MAX:-10000}"    # soglia errori find tollerati (solo con STRICT_SCAN)
FAST="${FAST:-0}"                        # 1 = salta Top Files / Cleanup / Over-10y (meno CPU per-file)
STREAM="${STREAM:-0}"                    # 1 = find->awk diretto, nessun dataset .tsv.gz (no artefatto, no %)
MIN_FREE_MB="${MIN_FREE_MB:-512}"        # spazio minimo (MB) in WORK_TMP: sotto -> warning (abort se STRICT_SCAN)
WARN=0                                    # diventa 1 se il run completa con warning (exit 2)

HOST="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo host)"
TS="$(date +%Y%m%d_%H%M%S)"
GB=$((1024**3))
YEARS_VIEW_DAYS=$((YEARS_VIEW * 365))

###############################################################################
# SAFE ROOT
###############################################################################

if command -v realpath >/dev/null 2>&1; then
    ROOT="$(realpath -m "$ROOT")"
else
    ROOT="$(cd "$ROOT" 2>/dev/null && pwd -P || echo "$ROOT")"
fi
ROOT="${ROOT%/}"
[[ -z "$ROOT" ]] && ROOT="/"
[[ -e "$ROOT" ]] || { echo "ERROR: ROOT not found" >&2; exit 1; }

###############################################################################
# OUTPUT / LOG DIRS (accanto allo script)
###############################################################################

mkdir -p "$OUTDIR" "$LOGDIR" \
    || { echo "ERROR: cannot create output/log dirs in $SCRIPT_DIR" >&2; exit 1; }
OUTDIR="$(cd "$OUTDIR" && pwd -P)"
LOGDIR="$(cd "$LOGDIR" && pwd -P)"

[[ -z "$WORK_TMP" ]] && WORK_TMP="$OUTDIR"
mkdir -p "$WORK_TMP" || { echo "ERROR: cannot create WORK_TMP $WORK_TMP" >&2; exit 1; }
WORK_TMP="$(cd "$WORK_TMP" && pwd -P)"

ROOT_TAG="$(printf '%s' "$ROOT" | sed 's#^/##; s#/#_#g')"
[[ -z "$ROOT_TAG" ]] && ROOT_TAG="root"

BASE="${OUTDIR}/${HOST}_${ROOT_TAG}_${TS}"
DATA="${BASE}.tsv.gz"
REPORT="${BASE}.txt"
HTML="${BASE}.html"
OVER10="${BASE}.over10y.gz"
CSV10="${BASE}.over10y.csv"
LOGFILE="${LOGDIR}/${HOST}_${ROOT_TAG}_${TS}.log"

NOW="$(date +%s)"
# offset locale (secondi) per la data nel CSV (granularita giorno; DST corrente)
TZOFF="$(date +%z | awk '{s=substr($0,1,1);h=substr($0,2,2)+0;m=substr($0,4,2)+0;v=h*3600+m*60;print (s=="-")?-v:v}')"
[[ "$TZOFF" =~ ^-?[0-9]+$ ]] || TZOFF=0
START="$NOW"
PARALLEL="$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)"

GZIP_LEVEL="${GZIP_LEVEL:-$([[ "$FAST" = "1" ]] && echo 1 || echo 6)}"   # 1=veloce/CPU bassa, 6=bilanciato (dataset piu piccolo); FAST -> 1 di default
GZIP_CMD=(gzip -"$GZIP_LEVEL")
DECOMP=(zcat)
if command -v pigz >/dev/null 2>&1; then
    GZIP_CMD=(pigz -"$GZIP_LEVEL" -p "$PARALLEL")
    DECOMP=(pigz -dc -p "$PARALLEL")
fi

SORT_OPTS=(-T "$WORK_TMP" --parallel="$PARALLEL" -S "$SORT_MEM" -t $'\t')

run_lowprio() {
    if command -v ionice >/dev/null 2>&1; then
        ionice -c3 nice -n19 "$@"
    else
        nice -n19 "$@"
    fi
}

log() { printf '%s  %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOGFILE"; }

esc_html() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

fmt_int() { printf '%s' "$1" | rev | sed 's/[0-9]\{3\}/&./g' | rev | sed 's/^\.//'; }

###############################################################################
# WORK FILES (piccoli; rimossi all'uscita - path esatti)
###############################################################################

STATF=""; DIRMAP=""; EXTMAP=""; AGEF=""; FINDERR=""; SCANCNT=""
T_TOPF=""; T_OLDER=""; T_CLEAN=""; T_DIRSZ=""; T_DIRCNT=""; T_EXT=""; T_OVER=""; OVER_RAW=""
T_SZB=""; T_CAT=""; T_OWN=""

cleanup() {
    for x in "$STATF" "$DIRMAP" "$EXTMAP" "$AGEF" "$FINDERR" "$SCANCNT" \
             "$T_TOPF" "$T_OLDER" "$T_CLEAN" "$T_DIRSZ" "$T_DIRCNT" "$T_EXT" "$T_OVER" "$OVER_RAW" \
             "$T_SZB" "$T_CAT" "$T_OWN"; do
        if [[ -n "$x" ]]; then rm -f "$x"; fi
    done
    rm -f "${WORK_TMP}/.part.${TS}."* 2>/dev/null || true
}
trap cleanup EXIT
trap 'rc=$?; log "ERROR rc=$rc at line $LINENO"' ERR

STATF="$(mktemp "${WORK_TMP}/.stat.XXXXXX")"
DIRMAP="$(mktemp "${WORK_TMP}/.dirs.XXXXXX")"
EXTMAP="$(mktemp "${WORK_TMP}/.exts.XXXXXX")"
AGEF="$(mktemp "${WORK_TMP}/.age.XXXXXX")"
T_TOPF="$(mktemp "${WORK_TMP}/.topf.XXXXXX")"
T_OLDER="$(mktemp "${WORK_TMP}/.oldf.XXXXXX")"
T_CLEAN="$(mktemp "${WORK_TMP}/.clean.XXXXXX")"
T_DIRSZ="$(mktemp "${WORK_TMP}/.dsz.XXXXXX")"
T_DIRCNT="$(mktemp "${WORK_TMP}/.dcn.XXXXXX")"
T_EXT="$(mktemp "${WORK_TMP}/.ext.XXXXXX")"
T_OVER="$(mktemp "${WORK_TMP}/.over.XXXXXX")"
OVER_RAW="$(mktemp "${WORK_TMP}/.ovraw.XXXXXX")"
T_SZB="$(mktemp "${WORK_TMP}/.szb.XXXXXX")"
T_CAT="$(mktemp "${WORK_TMP}/.cat.XXXXXX")"
T_OWN="$(mktemp "${WORK_TMP}/.own.XXXXXX")"
FINDERR="$(mktemp "${WORK_TMP}/.ferr.XXXXXX")"
SCANCNT="$(mktemp "${WORK_TMP}/.cnt.XXXXXX")"

log "START host=$HOST root=$ROOT outdir=$OUTDIR"
log "params TOPN=$TOPN OLD_DAYS=$OLD_DAYS YEARS_VIEW=$YEARS_VIEW AGG_DEPTH=$AGG_DEPTH CROSS_MOUNTS=$CROSS_MOUNTS MAX_DIR_KEYS=$MAX_DIR_KEYS WORK_TMP=$WORK_TMP SCAN_JOBS=$SCAN_JOBS FAST=$FAST STREAM=$STREAM STRICT_SCAN=$STRICT_SCAN"

# STREAM e' incompatibile con lo scan parallelo (richiederebbe merge via process-subst):
# in streaming l'aggregazione avviene durante un singolo find -> forziamo seriale.
if [[ "$STREAM" = "1" && "$SCAN_JOBS" -gt 1 ]]; then
    log "NOTE: STREAM=1 -> scan forzato seriale (SCAN_JOBS ignorato)"
    SCAN_JOBS=1
fi

# pre-check: spazio disponibile in WORK_TMP (temporanei, sort, dataset)
_free_mb="$(df -Pm "$WORK_TMP" 2>/dev/null | awk 'NR==2{print $4}' || true)"
if [[ "$_free_mb" =~ ^[0-9]+$ ]]; then
    log "WORK_TMP free space: ${_free_mb} MB"
    if (( _free_mb < MIN_FREE_MB )); then
        WARN=1
        log "WARNING: spazio in WORK_TMP ($WORK_TMP) sotto la soglia: ${_free_mb} MB < ${MIN_FREE_MB} MB"
        if [[ "$STRICT_SCAN" = "1" ]]; then
            log "ERROR: spazio insufficiente in WORK_TMP (STRICT_SCAN attivo) -> abort"
            echo "ERROR: spazio insufficiente in WORK_TMP: ${_free_mb} MB < ${MIN_FREE_MB} MB" >&2
            exit 1
        fi
    fi
else
    log "WARNING: impossibile determinare lo spazio libero in WORK_TMP"
fi

###############################################################################
# EXCLUDES
###############################################################################

EXCLUDE_PATHS=(
    /proc /sys /dev /run
    /var/lib/docker /var/lib/containerd
    /snap /mnt /media
    "$OUTDIR" "$LOGDIR" "$WORK_TMP"
)
if [[ -n "$EXTRA_EXCLUDES" ]]; then
    read -ra _xe <<< "$EXTRA_EXCLUDES"
    for g in "${_xe[@]}"; do EXCLUDE_PATHS+=("$g"); done
fi

PRUNE_EXPR=()
for p in "${EXCLUDE_PATHS[@]}"; do
    # salta esclusioni uguali a ROOT o suoi antenati: pruneerebbero la radice
    # (dataset vuoto) o sono no-op. I discendenti di ROOT restano.
    if [[ "$ROOT" == "$p" || "$ROOT" == "$p"/* ]]; then continue; fi
    PRUNE_EXPR+=( -path "$p" -prune -o )
done

XDEV=(-xdev)
[[ "$CROSS_MOUNTS" = "1" ]] && XDEV=()

###############################################################################
# SCAN  ->  DATA (compresso, unica materializzazione)
#   fields: 1=size 2=uid 3=gid 4=mtime 5=path   (UID/GID numerici: no LDAP)
#   SCAN_JOBS=1: find seriale (pipe diretta in gzip).
#   SCAN_JOBS>1: un find per sottocartella di primo livello, in parallelo, su
#                file temporanei separati (nessun rischio di interleaving su pipe),
#                poi merge -> conteggio -> gzip. Stesse opzioni (prune/-xdev) per
#                worker: dataset identico al seriale. Downstream invariato.
#   Guard: se le sottocartelle di 1° livello non escluse sono < 2 il parallelismo
#          non porta concorrenza utile -> fallback al ramo seriale.
###############################################################################

PRINTF_FMT='%s\t%U\t%G\t%T@\t%p\n'

# find seriale riutilizzabile (usato dallo scan normale e dalla modalita' streaming)
scan_find_serial() {
    run_lowprio find "$ROOT" "${XDEV[@]}" "${PRUNE_EXPR[@]}" -type f -printf "$PRINTF_FMT" 2>"$FINDERR" || true
}

# verifica errori find (+ abort opzionale con STRICT_SCAN); chiamata dopo lo scan
# (normale) oppure dopo l'aggregazione (streaming, quando il find e' completato)
check_find_errors() {
    FERR=$(wc -l < "$FINDERR" 2>/dev/null || echo 0)
    if [[ "${FERR:-0}" -gt 0 ]]; then
        WARN=1
        log "WARNING: find ha riportato $FERR errori di accesso (scan potenzialmente parziale); esempi:"
        head -5 "$FINDERR" | sed 's/^/  /' | tee -a "$LOGFILE"
        if [[ "$STRICT_SCAN" = "1" ]] && (( FERR > FIND_ERR_MAX )); then
            log "ERROR: errori find ($FERR) oltre FIND_ERR_MAX=$FIND_ERR_MAX (STRICT_SCAN) -> abort"
            echo "ERROR: troppi errori find ($FERR > $FIND_ERR_MAX) con STRICT_SCAN attivo" >&2
            exit 1
        fi
    fi
}

if [[ "$STREAM" = "1" ]]; then
    HAVE_DATASET=0
    log "Scan+aggregazione in STREAMING (nessun dataset .tsv.gz intermedio; progress senza %)"
else
    HAVE_DATASET=1
    # enumera le unita' di scan parallele (sottocartelle di 1° livello non escluse).
    # COERENZA -xdev: con -xdev attivo (CROSS_MOUNTS=0) il find SERIALE non scende
    # nei mount diversi da ROOT. Nel parallelo ogni worker usa la SUA sottocartella
    # come riferimento -xdev: una sottocartella che e' essa stessa un mount separato
    # verrebbe quindi inclusa (incoerente col seriale). Per allineare i due percorsi
    # si escludono dalle unita' le sottocartelle su device != ROOT (gestiti i mount
    # piu' profondi gia' identicamente dal -xdev dei worker). Con CROSS_MOUNTS=1 non
    # si filtra nulla (entrambi attraversano tutto).
    SCAN_UNITS=()
    if (( SCAN_JOBS > 1 )); then
        _root_dev=""; _mnt_excl=0
        if [[ "$CROSS_MOUNTS" != "1" ]] && command -v stat >/dev/null 2>&1; then
            _root_dev="$(stat -c %d "$ROOT" 2>/dev/null || true)"
        fi
        while IFS= read -r _d; do
            _skip=0; for _e in "${EXCLUDE_PATHS[@]}"; do [[ "$_d" == "$_e" ]] && { _skip=1; break; }; done
            (( _skip )) && continue
            if [[ -n "$_root_dev" ]]; then
                _dd="$(stat -c %d "$_d" 2>/dev/null || echo "$_root_dev")"
                if [[ "$_dd" != "$_root_dev" ]]; then _mnt_excl=$((_mnt_excl+1)); continue; fi
            fi
            SCAN_UNITS+=("$_d")
        done < <(find "$ROOT" -mindepth 1 -maxdepth 1 "${XDEV[@]}" -type d 2>/dev/null)
        (( _mnt_excl > 0 )) && log "NOTE: $_mnt_excl sottocartelle di 1° livello su mount separati escluse dal parallelo (coerenza con -xdev seriale; usa CROSS_MOUNTS=1 per includerle)"
    fi

    if (( SCAN_JOBS > 1 && ${#SCAN_UNITS[@]} >= 2 )); then
        log "Scan start (parallelo: SCAN_JOBS=$SCAN_JOBS, ${#SCAN_UNITS[@]} sottocartelle)"
        SCAN_PARTS=(); _running=0

        # nomi .part univoci (mktemp + TS): nessuna collisione tra run concorrenti.
        # Ogni worker scrive il proprio exit code in <part>.rc per la verifica.
        _part="$(mktemp "${WORK_TMP}/.part.${TS}.XXXXXX")"; SCAN_PARTS+=("$_part")
        ( run_lowprio find "$ROOT" -maxdepth 1 "${XDEV[@]}" "${PRUNE_EXPR[@]}" -type f -printf "$PRINTF_FMT" 2>>"$FINDERR"; echo $? > "${_part}.rc" ) > "$_part" &
        _running=$((_running+1))

        for _d in "${SCAN_UNITS[@]}"; do
            _part="$(mktemp "${WORK_TMP}/.part.${TS}.XXXXXX")"; SCAN_PARTS+=("$_part")
            ( run_lowprio find "$_d" "${XDEV[@]}" "${PRUNE_EXPR[@]}" -type f -printf "$PRINTF_FMT" 2>>"$FINDERR"; echo $? > "${_part}.rc" ) > "$_part" &
            _running=$((_running+1))
            if (( _running >= SCAN_JOBS )); then wait -n 2>/dev/null || wait; _running=$((_running-1)); fi
        done
        wait

        # exit code dei worker: find=1 di norma e' "permessi negati" (gia' in FINDERR),
        # quindi e' un WARNING, non un errore fatale. rc mancante = terminazione anomala.
        _werr=0
        for _p in "${SCAN_PARTS[@]}"; do
            if [[ -f "${_p}.rc" ]]; then
                _rc="$(cat "${_p}.rc" 2>/dev/null || echo 0)"; [[ "$_rc" =~ ^[0-9]+$ ]] || _rc=0
                (( _rc != 0 )) && _werr=$((_werr+1))
                rm -f "${_p}.rc"
            else
                _werr=$((_werr+1))
            fi
        done
        (( _werr > 0 )) && { WARN=1; log "WARNING: $_werr worker di scan con exit code != 0 (probabili errori di accesso; vedi dettagli find sotto)"; }

        cat "${SCAN_PARTS[@]}" |
        awk -v step="$PROGRESS_EVERY" -v cntf="$SCANCNT" '
        { c++; if (step>0 && c%step==0) printf "  merge... %d files\r", c > "/dev/stderr"; print }
        END{ printf "  scanned %d files          \n", c > "/dev/stderr"; if (cntf!="") printf "%d\n", c > cntf }' |
        run_lowprio "${GZIP_CMD[@]}" > "$DATA"
        rm -f "${SCAN_PARTS[@]}"
    else
        if (( SCAN_JOBS > 1 )); then
            log "Scan start (seriale: SCAN_JOBS=$SCAN_JOBS ma <2 sottocartelle utili, parallelismo non vantaggioso)"
        else
            log "Scan start"
        fi
        scan_find_serial |
        awk -v step="$PROGRESS_EVERY" -v cntf="$SCANCNT" '
        { c++; if (step>0 && c%step==0) printf "  scanning... %d files\r", c > "/dev/stderr"; print }
        END{ printf "  scanned %d files          \n", c > "/dev/stderr"; if (cntf!="") printf "%d\n", c > cntf }' |
        run_lowprio "${GZIP_CMD[@]}" > "$DATA"
    fi

    if [[ "$(run_lowprio "${DECOMP[@]}" "$DATA" 2>/dev/null | head -c1 | wc -c || true)" -eq 0 ]]; then
        log "ERROR: empty dataset (no files or scan failed)"
        echo "ERROR: empty dataset (no files or scan failed)" >&2
        exit 1
    fi

    log "Scan complete: dataset $(du -h "$DATA" 2>/dev/null | cut -f1)"
    check_find_errors
fi

###############################################################################
# SINGLE-PASS AGGREGATOR
#   - per-file: accumulo O(1) sulla sola directory foglia (no loop antenati)
#   - END: rollup bottom-up per-directory (non per-file) -> dimensioni ricorsive
#   - limitato a AGG_DEPTH livelli sotto ROOT; ROOT tracciato, padre di ROOT mai
#   stdout -> AGEF (age table); writes STATF, DIRMAP, EXTMAP
###############################################################################

log "Aggregation start"

TOTAL_SCANNED="$(cat "$SCANCNT" 2>/dev/null || echo 0)"
[[ "$TOTAL_SCANNED" =~ ^[0-9]+$ ]] || TOTAL_SCANNED=0

{ if [[ "$STREAM" = "1" ]]; then scan_find_serial; else run_lowprio "${DECOMP[@]}" "$DATA"; fi; } |
awk -F'\t' -v now="$NOW" -v gb="$GB" -v old="$OLD_DAYS" \
    -v root="$ROOT" -v agg="$AGG_DEPTH" -v maxk="$MAX_DIR_KEYS" \
    -v statf="$STATF" -v dirmap="$DIRMAP" -v extmap="$EXTMAP" \
    -v total="$TOTAL_SCANNED" -v step="$PROGRESS_EVERY" -v fast="$FAST" \
    -v n="$TOPN" -v thr="$YEARS_VIEW_DAYS" -v skip="$CLEANUP_SKIP" \
    -v tf="$T_TOPF" -v ot="$T_OLDER" -v cl="$T_CLEAN" -v ovr="$OVER_RAW" \
    -v szbf="$T_SZB" -v catf="$T_CAT" -v ownf="$T_OWN" '
BEGIN{
    if (root=="/") { rstart=2; rootlabel="/"; rbase="" }
    else { rc=split(root, ra, "/"); rstart=rc+1; rootlabel=root; rbase=root }
    capn=rstart-1+agg
    _rb=rbase; rootslash=gsub(/\//,"/",_rb)   # n. slash nella radice: base per profondita relativa
}
{
    # robustezza nomi "sporchi":
    #  - TAB nel nome: il path viene spezzato su molti campi -> lo ricompongo da $5..$NF
    #  - NEWLINE nel nome: la coda arriva come record separato (NF<5 oppure $1 non numerico)
    #    -> lo scarto, per non gonfiare i conteggi ne falsare le fasce di anzianita
    if (NF<5 || $1 !~ /^[0-9]+$/) { bad++; next }
    p=$5; for (i=6;i<=NF;i++) p=p "\t" $i
    f++; t+=$1
    own_s[$2]+=$1; own_n[$2]++          # accumulo per proprietario (UID numerico, campo 2)
    if (step>0 && f%step==0) {
        if (total>0) printf "  aggregating... %.1f%% (%d/%d)\r", (f>total?100:f*100/total), f, total > "/dev/stderr"
        else          printf "  aggregating... %d files\r", f > "/dev/stderr"
    }
    a=(now-$4)/86400; if (a<0) a=0; ai=int(a)
    if (a>old) r+=$1

    if      (a<=30)   {c1++;s1+=$1}
    else if (a<=90)   {c2++;s2+=$1}
    else if (a<=180)  {c3++;s3+=$1}
    else if (a<=365)  {c4++;s4+=$1}
    else if (a<=730)  {c5++;s5+=$1}
    else if (a<=1825) {c6++;s6+=$1}
    else if (a<=3650) {c7++;s7+=$1}
    else              {c8++;s8+=$1}

    fn=p; sub(".*/","",fn)
    ext="none"
    if (fn ~ /\.[^.]+$/ && fn !~ /^\./) { e=fn; sub(/^.*\./,"",e); ext=tolower(e) }
    es[ext]+=$1; ec[ext]++

    # directory foglia (parent del file) ricavata dal basename calcolato sopra:
    # nessuna seconda regex, solo substr. Accumulo O(1); rollup ricorsivo in END.
    ld=substr(p,1,length(p)-length(fn)-1); if (ld=="") ld="/"
    # cap sulla mappa foglia: MAX_DIR_KEYS limita la RAM ANCHE durante la passata,
    # non solo il rollup in END. Oltre il cap i totali globali (byte, eta, ext,
    # tipologia, dimensioni) restano esatti: si perde solo il dettaglio per-directory
    # delle cartelle eccedenti (capped=1, warning a fine run).
    if (ld in leaf_s) { leaf_s[ld]+=$1; leaf_n[ld]++ }
    else if (maxk<=0 || lk<maxk) { leaf_s[ld]=$1; leaf_n[ld]=1; lk++ }
    else capped=1

    # categoria per tipologia (per spazio) - euristica su estensione
    cat="altri"
    if      (ext ~ /^(pdf|docx?|xlsx?|pptx?|txt|rtf|odt|ods|odp|md|tex|p7m|p7s|eml|msg|epub)$/)                          cat="documenti"
    else if (ext ~ /^(jpe?g|png|gif|bmp|tiff?|svg|webp|heic|raw|psd|mp4|m4v|avi|mov|mkv|wmv|flv|mpe?g|webm|mp3|wav|flac|aac|ogg|m4a)$/) cat="media"
    else if (ext ~ /^(zip|rar|7z|tar|gz|tgz|bz2|xz|zst|iso|cab|arj|lz|lzma|z|lzo|tbz2|txz)$/)                           cat="archivi"
    else if (ext ~ /^(db|sql|sqlite|sqlite3|db3|mdb|accdb|dbf|bak|mdf|ndf|ldf|frm|ibd|dmp|myd|myi|bson)$/)              cat="database"
    else if (ext ~ /^(dat|bin|log|json|xml|ya?ml|parquet|avro|idx|out|dump|csv|tsv|ndjson|jsonl|xbrl|edi|pcap)$/)       cat="dati"
    catb[cat]+=$1

    # distribuzione per dimensione file (per numero di file)
    if      ($1<1024)       z1++
    else if ($1<1048576)    z2++
    else if ($1<104857600)  z3++
    else if ($1<1073741824) z4++
    else                    z5++

    # scalari: mtime min/max, profondita max in livelli, file piu grande
    if (minm==0 || $4<minm) minm=$4
    if ($4>maxm) maxm=$4
    _t=p; nd=gsub(/\//,"/",_t)-rootslash; if (nd<0) nd=0; if (nd>maxdepth) maxdepth=nd
    if ($1>maxsize) maxsize=$1

    # TOP-N in memoria: niente sort globale, niente rilettura del dataset.
    # Inserimento O(1) ammortizzato (confronto col minimo del top-N corrente).
    # FAST salta questo blocco (Top Files / Older / Cleanup) e il log() per-file.
    if (n>0 && !fast) {
        v=$1                                                    # top file per dimensione
        if (tfN<n) { tfN++; TFk[tfN]=v; TFr[tfN]=v"\t"ai"\t"p; if(tfN==1||v<tfmv){tfmv=v;tfmi=tfN} }
        else if (v>tfmv) { TFk[tfmi]=v; TFr[tfmi]=v"\t"ai"\t"p; tfmv=TFk[1];tfmi=1; for(j=2;j<=n;j++) if(TFk[j]<tfmv){tfmv=TFk[j];tfmi=j} }

        if (a>thr) {                                            # file piu vecchi della soglia, per dimensione
            v=$1
            if (olN<n) { olN++; OLk[olN]=v; OLr[olN]=v"\t"int(a/365)"\t"p; if(olN==1||v<olmv){olmv=v;olmi=olN} }
            else if (v>olmv) { OLk[olmi]=v; OLr[olmi]=v"\t"int(a/365)"\t"p; olmv=OLk[1];olmi=1; for(j=2;j<=n;j++) if(OLk[j]<olmv){olmv=OLk[j];olmi=j} }
        }

        if (a>old && $1>0 && (skip=="" || p !~ skip)) {        # cleanup per punteggio = size * ln(eta+1)^2
            l=log(a+1); sc=$1*l*l
            if (clN<n) { clN++; CLk[clN]=sc; CLr[clN]=sprintf("%.6f",sc)"\t"$1"\t"ai"\t"p; if(clN==1||sc<clmv){clmv=sc;clmi=clN} }
            else if (sc>clmv) { CLk[clmi]=sc; CLr[clmi]=sprintf("%.6f",sc)"\t"$1"\t"ai"\t"p; clmv=CLk[1];clmi=1; for(j=2;j<=n;j++) if(CLk[j]<clmv){clmv=CLk[j];clmi=j} }
        }
    }

    # coorte > 10 anni: righe grezze (non ordinate) per export gz/CSV/sezione HTML
    if (a>3650 && !fast) printf "%d\t%d\t%s\t%s\n", $1, ai, $4, p > ovr
}
END{
    if (step>0) printf "  aggregated %d files            \n", f > "/dev/stderr"
    if (bad>0) printf "  WARNING: %d record ignorati (newline nei nomi file?)\n", bad > "/dev/stderr"
    printf "0-30d     %10d %10.2f GB %.0f\n",c1,s1/gb,s1
    printf "31-90d    %10d %10.2f GB %.0f\n",c2,s2/gb,s2
    printf "91-180d   %10d %10.2f GB %.0f\n",c3,s3/gb,s3
    printf "181-365d  %10d %10.2f GB %.0f\n",c4,s4/gb,s4
    printf "1-2y      %10d %10.2f GB %.0f\n",c5,s5/gb,s5
    printf "2-5y      %10d %10.2f GB %.0f\n",c6,s6/gb,s6
    printf "5-10y     %10d %10.2f GB %.0f\n",c7,s7/gb,s7
    printf ">10y      %10d %10.2f GB %.0f\n",c8,s8/gb,s8

    # rollup bottom-up: una sola volta per directory foglia (non per file),
    # ricostruisce le dimensioni/conteggi RICORSIVI per ogni directory antenata
    # (fino a capn livelli sotto ROOT). Output identico al vecchio walk per-file.
    for (L in leaf_s) {
        ndirs++
        sv=leaf_s[L]; nv=leaf_n[L]
        if (rootlabel in ds) { ds[rootlabel]+=sv; dn[rootlabel]+=nv }
        else { ds[rootlabel]=sv; dn[rootlabel]=nv; nk++ }
        if (L != rootlabel) {
            nc=split(L, pp, "/")
            lim=nc; if (lim>capn) lim=capn
            dpath=rbase
            for (i=rstart; i<=lim; i++) {
                dpath=dpath "/" pp[i]
                if (dpath in ds) { ds[dpath]+=sv; dn[dpath]+=nv }
                else if (maxk<=0 || nk<maxk) { ds[dpath]=sv; dn[dpath]=nv; nk++ }
                else { capped=1; break }
            }
        }
        delete leaf_s[L]; delete leaf_n[L]
    }

    printf "%d %.0f %.0f %d %.0f %d %.0f %.0f %d %d %.0f\n", \
        f+0, t+0, r+0, c8+0, s8+0, capped+0, minm+0, maxm+0, maxdepth+0, ndirs+0, maxsize+0 > statf
    printf "%d %d %d %d %d\n", z1+0,z2+0,z3+0,z4+0,z5+0 > szbf
    printf "dati\t%.0f\nmedia\t%.0f\ndocumenti\t%.0f\narchivi\t%.0f\ndatabase\t%.0f\naltri\t%.0f\n", \
        catb["dati"]+0,catb["media"]+0,catb["documenti"]+0,catb["archivi"]+0,catb["database"]+0,catb["altri"]+0 > catf
    for (k in ds) printf "%d\t%d\t%s\n", ds[k], dn[k], k > dirmap
    for (k in es) printf "%d\t%d\t%s\n", es[k], ec[k], k > extmap
    for (k in own_s) printf "%s\t%d\t%d\n", k, own_s[k], own_n[k] > ownf
    for (i=1;i<=tfN;i++) print TFr[i] > tf
    for (i=1;i<=olN;i++) print OLr[i] > ot
    for (i=1;i<=clN;i++) print CLr[i] > cl
}' > "$AGEF"

read -r TOTAL_FILES TOTAL_BYTES RECOVERABLE_BYTES OLD10_CNT OLD10_BYTES DIRCAP \
        MIN_MTIME MAX_MTIME MAX_DEPTH DIR_COUNT MAX_FSIZE < "$STATF"

# in streaming il find termina insieme all'aggregazione: ora si possono valutare
# gli errori (+ eventuale STRICT_SCAN) e l'eventuale risultato vuoto
if [[ "$STREAM" = "1" ]]; then
    check_find_errors
    if [[ "${TOTAL_FILES:-0}" -eq 0 ]]; then
        log "ERROR: nessun file rilevato (streaming): scan vuoto o fallito"
        echo "ERROR: nessun file rilevato (STREAM)" >&2
        exit 1
    fi
fi

log "Aggregation complete: files=$TOTAL_FILES size_bytes=$TOTAL_BYTES reclaimable_bytes=$RECOVERABLE_BYTES"
[[ "${DIRCAP:-0}" = "1" ]] && { WARN=1; log "WARNING: mappa directory limitata a MAX_DIR_KEYS=$MAX_DIR_KEYS chiavi; TOP DIRECTORIES puo' essere incompleto (aumenta MAX_DIR_KEYS o abbassa AGG_DEPTH)"; }

ATIME_MODE="$(findmnt -no OPTIONS --target "$ROOT" 2>/dev/null |
    grep -oE 'noatime|relatime|strictatime' | head -1 || true)"
[[ -z "$ATIME_MODE" ]] && ATIME_MODE="unknown"

###############################################################################
# COMPUTE VIEWS ONCE (piccoli output, riusati da TXT e HTML)
###############################################################################

log "Computing views"

# TOP FILES / OLDER / CLEANUP sono gia' calcolati in memoria durante l'aggregazione
# (nessun sort globale, nessuna rilettura del dataset). Qui si ordinano i file gia'
# ridotti a <=TOPN righe: sort istantaneo. In FAST questi temp sono vuoti -> si saltano.
if [[ "$FAST" != "1" ]]; then
    run_lowprio sort "${SORT_OPTS[@]}" -k1,1nr "$T_TOPF"  -o "$T_TOPF"
    run_lowprio sort "${SORT_OPTS[@]}" -k1,1nr "$T_OLDER" -o "$T_OLDER"
    run_lowprio sort "${SORT_OPTS[@]}" -k1,1nr "$T_CLEAN" -o "$T_CLEAN"
fi

# coorte > 10 anni: l'aggregazione ha scritto le righe grezze in OVER_RAW; qui si
# ordina per dimensione SOLO questo sottoinsieme (non l'intero dataset). Saltato in FAST.
if (( OLD10_CNT > 0 )) && [[ "$FAST" != "1" ]]; then
    run_lowprio sort "${SORT_OPTS[@]}" -k1,1nr "$OVER_RAW" > "$T_OVER"
fi

# dir/ext (size count label) - sort su mappe piccole
run_lowprio sort "${SORT_OPTS[@]}" -k1,1nr "$DIRMAP" | awk -F'\t' -v n="$TOPN" 'NR<=n' > "$T_DIRSZ"
run_lowprio sort "${SORT_OPTS[@]}" -k2,2nr "$DIRMAP" | awk -F'\t' -v n="$TOPN" 'NR<=n' > "$T_DIRCNT"
run_lowprio sort "${SORT_OPTS[@]}" -k1,1nr "$EXTMAP" | awk -F'\t' 'NR<=25' > "$T_EXT"

ELAPSED=$(( $(date +%s) - START ))
human() { awk -v b="${1:-0}" 'BEGIN{u="B KB MB GB TB PB";n=split(u,a," ");s=b+0;i=1;while(s>=1024&&i<n){s/=1024;i++}printf (i<=1?"%d %s":"%.2f %s"),s,a[i]}'; }

# Top proprietari per spazio: UID accumulati in T_OWN (uid\tbyte\tcount); risolvo
# i soli Top-N a nome via getent (lookup mirato, niente enumerazione di tutto AD).
OWNER_ROWS=""; N_OWN=0
if [[ -s "$T_OWN" ]]; then
    N_OWN="$(wc -l < "$T_OWN" 2>/dev/null | tr -d ' ' || echo 0)"
    _have_getent=0; command -v getent >/dev/null 2>&1 && _have_getent=1
    _otop="$(run_lowprio sort "${SORT_OPTS[@]}" -k2,2nr "$T_OWN" 2>/dev/null | head -n "$TOPN" || true)"
    _omax="$(printf '%s\n' "$_otop" | awk -F'\t' 'NR==1{print $2; exit}')"
    while IFS=$'\t' read -r _uid _ob _on; do
        [[ -z "$_uid" ]] && continue
        _nm=""; if (( _have_getent )); then _nm="$(getent passwd "$_uid" 2>/dev/null | cut -d: -f1 || true)"; fi
        [[ -z "$_nm" ]] && _nm="uid ${_uid}"
        _h="$(human "$_ob")"
        _w="$(awk -v v="$_ob" -v m="${_omax:-0}" 'BEGIN{printf "%.1f",(m>0?v/m*100:0)}')"
        _nme="$(printf '%s' "$_nm" | esc_html)"
        OWNER_ROWS="${OWNER_ROWS}<div class=\"row\"><div class=\"v\">${_h}</div><div class=\"bar\"><i style=\"width:${_w}%\"></i></div><div class=\"p\">${_nme} <span class=\"age\">$(fmt_int "$_on") file</span></div></div>"
    done <<< "$_otop"
fi

SIZE_GB="$(awk -v v="$TOTAL_BYTES" -v g="$GB" 'BEGIN{printf "%.2f",v/g}')"
REC_GB="$(awk -v v="$RECOVERABLE_BYTES" -v g="$GB" 'BEGIN{printf "%.2f",v/g}')"
FILES_FMT="$(fmt_int "$TOTAL_FILES")"

USED_PCT="$(df -P "$ROOT" 2>/dev/null | awk 'NR==2{for(i=1;i<=NF;i++) if($i ~ /%$/){print $i; exit}}' || true)"
[[ -z "$USED_PCT" ]] && USED_PCT="n/a"
USED_NUM="${USED_PCT%\%}"
UCLASS="accent"
[[ "$USED_NUM" =~ ^[0-9]+$ ]] && (( USED_NUM >= 85 )) && UCLASS="warn"

ROOT_H="$(printf '%s' "$ROOT" | esc_html)"

# coorte > 10 anni (fascia ">10y" = mtime > 3650 giorni); valori da STATF (machine-readable)
OLD10_CNT="${OLD10_CNT:-0}"; OLD10_BYTES="${OLD10_BYTES:-0}"
OLD10_GB="$(awk -v v="$OLD10_BYTES" -v g="$GB" 'BEGIN{printf "%.2f",v/g}')"
OLD10_BANNER=""
if (( OLD10_CNT > 0 )); then
  OLD10_BANNER="<div class=\"flag\"><div class=\"h\">Dati oltre i 10 anni</div><div class=\"b\"><span class=\"big\">$(human "$OLD10_BYTES")</span> in <b>$(fmt_int "$OLD10_CNT")</b> file con mtime oltre i 10 anni &mdash; candidati a rimozione o archiviazione con strumenti dedicati, nel rispetto della retention.</div></div>"
fi

###############################################################################
# VALORI DERIVATI per la dashboard esecutiva (stile mockup)
###############################################################################
fmt_date(){ local e="${1%.*}"; [[ "$e" =~ ^[0-9]+$ && "$e" -gt 0 ]] && date -d "@$e" '+%d/%m/%Y' 2>/dev/null || echo "n/d"; }

SIZE_H="$(human "$TOTAL_BYTES")"
BYTES_FMT="$(fmt_int "$TOTAL_BYTES")"
DIRS_FMT="$(fmt_int "${DIR_COUNT:-0}")"
DUR_HMS="$(printf '%02d:%02d:%02d' $((ELAPSED/3600)) $(((ELAPSED%3600)/60)) $((ELAPSED%60)))"
DATE_SCAN_D="$(date -d "@$START" '+%d/%m/%Y' 2>/dev/null || date '+%d/%m/%Y')"
DATE_SCAN_T="$(date -d "@$START" '+%H:%M:%S' 2>/dev/null || date '+%H:%M:%S')"
AVG_B="$(awk -v t="$TOTAL_BYTES" -v f="$TOTAL_FILES" 'BEGIN{printf "%.0f",(f>0?t/f:0)}')"
AVG_H="$(human "$AVG_B")"
MAXF_H="$(human "${MAX_FSIZE:-0}")"
NEWEST_D="$(fmt_date "${MAX_MTIME:-0}")"
OLDEST_D="$(fmt_date "${MIN_MTIME:-0}")"
NEXCL="${#EXCLUDE_PATHS[@]}"
FSTYPE="$(df -PT "$ROOT" 2>/dev/null | awk 'NR==2{print $2}' || true)"; [[ -z "$FSTYPE" ]] && FSTYPE="n/d"
OLD10_PCT="$(awk -v o="$OLD10_BYTES" -v t="$TOTAL_BYTES" 'BEGIN{printf "%.1f",(t>0?o/t*100:0)}')"

# array dati per i grafici (JS), costruiti dai file gia' prodotti
SA_BANDS="$(awk '{c[NR]=$2;g[NR]=$3;b[NR]=$5} END{
  printf "[{l:\"0-1 anno\",c:%d,g:%.2f,b:%.0f,col:\"#3fcf8e\"},", c[1]+c[2]+c[3]+c[4], g[1]+g[2]+g[3]+g[4], b[1]+b[2]+b[3]+b[4]
  printf "{l:\"1-2 anni\",c:%d,g:%.2f,b:%.0f,col:\"#f3b04e\"},", c[5], g[5], b[5]
  printf "{l:\"2-5 anni\",c:%d,g:%.2f,b:%.0f,col:\"#e8833a\"},", c[6], g[6], b[6]
  printf "{l:\"5-10 anni\",c:%d,g:%.2f,b:%.0f,col:\"#f0556b\"},", c[7], g[7], b[7]
  printf "{l:\">10 anni\",c:%d,g:%.2f,b:%.0f,col:\"#a880ff\"}]", c[8], g[8], b[8] }' "$AGEF")"

SA_TYPES="[$(awk -F'\t' -v g="$GB" '
  BEGIN{col["dati"]="#5b9dff";col["media"]="#3fcf8e";col["documenti"]="#56c5d0";col["archivi"]="#e8833a";col["database"]="#a880ff";col["altri"]="#8a96a6";
        lab["dati"]="File di dati";lab["media"]="File multimediali";lab["documenti"]="Documenti";lab["archivi"]="Archivi e compressi";lab["database"]="Database";lab["altri"]="Altri"}
  {printf "%s{l:\"%s\",g:%.2f,b:%.0f,col:\"%s\"}", (NR>1?",":""), lab[$1], $2/g, $2, col[$1]}' "$T_CAT")]"

read -r Z1 Z2 Z3 Z4 Z5 < "$T_SZB" 2>/dev/null || true
SA_SIZES="[{l:\"0 B - 1 KB\",c:${Z1:-0}},{l:\"1 KB - 1 MB\",c:${Z2:-0}},{l:\"1 MB - 100 MB\",c:${Z3:-0}},{l:\"100 MB - 1 GB\",c:${Z4:-0}},{l:\"> 1 GB\",c:${Z5:-0}}]"

TOP10_ROWS="$(awk -F'\t' -v g="$GB" -v tot="$TOTAL_BYTES" '
  function esc(s){gsub(/&/,"\\&amp;",s);gsub(/</,"\\&lt;",s);gsub(/>/,"\\&gt;",s);return s}
  function hum(b){ if(b>=1099511627776)return sprintf("%.2f TB",b/1099511627776); if(b>=1073741824)return sprintf("%.2f GB",b/1073741824); if(b>=1048576)return sprintf("%.1f MB",b/1048576); if(b>=1024)return sprintf("%.1f KB",b/1024); return sprintf("%d B",b) }
  NR<=10{sum+=$1; pct=(tot>0)?$1/tot*100:0;
    printf "<tr><td class=\"rk\">%d</td><td class=\"dir\">%s</td><td class=\"sz\">%s</td><td class=\"pc\">%.1f%%</td></tr>", NR, esc($3), hum($1), pct}
  END{other=tot-sum; if(other<0)other=0; opct=(tot>0)?other/tot*100:0;
    printf "<tr class=\"other\"><td></td><td class=\"dir\">Altre directory</td><td class=\"sz\">%s</td><td class=\"pc\">%.1f%%</td></tr>", hum(other), opct}' "$T_DIRSZ")"


# sezione HTML dedicata > 10 anni (per dimensione), da T_OVER gia' ordinato per peso
OLD10_SECTION=""
if (( OLD10_CNT > 0 )) && [[ "$FAST" != "1" ]]; then
  _old10_rows="$(awk -F'\t' -v gb="$GB" -v n="$TOPN" '
    function esc(s){gsub(/&/,"\\&amp;",s);gsub(/</,"\\&lt;",s);gsub(/>/,"\\&gt;",s);return s}
    function hum(b){ if(b>=1099511627776)return sprintf("%.2f TB",b/1099511627776); if(b>=1073741824)return sprintf("%.2f GB",b/1073741824); if(b>=1048576)return sprintf("%.1f MB",b/1048576); if(b>=1024)return sprintf("%.1f KB",b/1024); return sprintf("%d B",b) }
    NR<=n{v[NR]=$1;ag[NR]=$2;p[NR]=$4;m=NR; if($1>mx)mx=$1}
    END{for(i=1;i<=m;i++){w=(mx>0)?v[i]/mx*100:0;
      printf "<div class=\"row old10\"><div class=\"v\">%s</div><div class=\"bar\"><i style=\"width:%.1f%%\"></i></div><div class=\"p\">%s <span class=\"age\">%dd</span></div></div>\n",hum(v[i]),w,esc(p[i]),ag[i]}}' "$T_OVER")"
  OLD10_SECTION="<details class=\"card o10\"><summary>File oltre i 10 anni (per dimensione)<span class=\"badge\">$(fmt_int "$OLD10_CNT")</span></summary><div class=\"bars\"><div class=\"o10cap\">Primi $(fmt_int "$TOPN") per dimensione &middot; elenco completo nel CSV <code>$(basename "$CSV10")</code></div>${_old10_rows}</div></details>"
fi

###############################################################################
# REPORT (TXT)
###############################################################################

{
echo "# SPACE AUDIT"
echo "# Root      : $ROOT"
echo "# Date      : $(date)"
echo "# Atime     : $ATIME_MODE"
echo "# Agg depth : $AGG_DEPTH levels below ROOT"
echo "# NOTE      : CLEANUP / RECLAIMABLE are mtime heuristics - review before"
echo "#             acting. Backup software (Veeam/Commvault/...) may keep mtime"
echo "#             old on live files. Exclude active DB/backup/cache. Tool only reads."

echo
echo "FILESYSTEM"
df -hT "$ROOT" 2>/dev/null | sed 's/^/  /' || echo "  (df non disponibile per $ROOT)"

echo
echo "AGE DISTRIBUTION"
awk '{printf "%-10s %10s %8s %s\n",$1,$2,$3,$4}' "$AGEF"

echo
echo "POTENTIALLY RECLAIMABLE"
echo "  $REC_GB GB"

echo
echo "TOP DIRECTORIES (by size)"
awk -F'\t' -v gb="$GB" '{printf "  %10.2f GB %s\n",$1/gb,$3}' "$T_DIRSZ"

echo
echo "TOP DIRECTORIES (by file count)"
awk -F'\t' '{printf "  %12d files  %s\n",$2,$3}' "$T_DIRCNT"

echo
echo "TOP EXTENSIONS"
awk -F'\t' -v gb="$GB" '{printf "  %10.2f GB %10d .%s\n",$1/gb,$2,$3}' "$T_EXT"

echo
echo "TOP OWNERS (by size)"
if [[ -s "$T_OWN" ]]; then
  _have_getent=0; command -v getent >/dev/null 2>&1 && _have_getent=1
  run_lowprio sort "${SORT_OPTS[@]}" -k2,2nr "$T_OWN" 2>/dev/null | head -n "$TOPN" | while IFS=$'\t' read -r _uid _ob _on; do
    _nm=""; if (( _have_getent )); then _nm="$(getent passwd "$_uid" 2>/dev/null | cut -d: -f1 || true)"; fi
    [[ -z "$_nm" ]] && _nm="uid ${_uid}"
    awk -v g="$GB" -v b="$_ob" -v c="$_on" -v u="$_nm" 'BEGIN{printf "  %10.2f GB %10d  %s\n",b/g,c,u}'
  done
else
  echo "  (nessun dato proprietari)"
fi

echo
echo "TOP FILES"
awk -F'\t' -v gb="$GB" '{printf "  %10.2f GB %6d d %s\n",$1/gb,$2,$3}' "$T_TOPF"

echo
echo "TOP FILES OLDER THAN ${YEARS_VIEW} YEARS"
awk -F'\t' -v gb="$GB" '{printf "  %10.2f GB %4d y %s\n",$1/gb,$2,$3}' "$T_OLDER"

echo
echo "CLEANUP"
awk -F'\t' -v gb="$GB" '{printf "  %10.2f GB score:%14.2f %s\n",$2/gb,$1,$4}' "$T_CLEAN"

echo
echo "SUMMARY"
echo "Files       : $TOTAL_FILES"
echo "Size        : $SIZE_GB GB"
echo "Used        : $USED_PCT"
echo "Reclaimable : $REC_GB GB"
echo "Over 10y    : $OLD10_CNT file, $OLD10_GB GB"
echo "Time        : ${ELAPSED}s"
} > "$REPORT"

log "TXT report written"

###############################################################################
# HTML DASHBOARD
###############################################################################

# conteggi per i badge delle sezioni (numero di voci elencate)
N_DIRSZ=$(awk 'END{print NR+0}' "$T_DIRSZ")
N_DIRCNT=$(awk 'END{print NR+0}' "$T_DIRCNT")
N_EXT=$(awk 'END{print NR+0}' "$T_EXT")
N_TOPF=$(awk 'END{print NR+0}' "$T_TOPF")
N_OLDER=$(awk 'END{print NR+0}' "$T_OLDER")
N_CLEAN=$(awk 'END{print NR+0}' "$T_CLEAN")

{
cat <<HTMLHEAD
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Space Audit - ${HOST} ${ROOT_H}</title>
<style>
:root{
  color-scheme: dark;
  --bg:#0a0c10; --panel:#11151d; --panel-2:#0d1119; --inset:#0c1017;
  --line:#1b2330; --line-2:#28323f;
  --ink:#e9edf3; --ink-dim:#98a3b2; --ink-faint:#5d6a7a;
  --primary:#5b9dff; --primary-2:#356fe0;
  --amber:#f3b04e; --amber-2:#d8842a;
  --green:#3fcf8e; --green-2:#1fa874;
  --red:#f0556b; --red-2:#c2384c;
  --sans:system-ui,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
  --mono:ui-monospace,"SF Mono","JetBrains Mono",Menlo,Consolas,monospace;
}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;font-family:var(--sans);color:var(--ink);line-height:1.5;
  background:
    radial-gradient(1100px 560px at 82% -12%, rgba(91,157,255,.06), transparent 60%),
    radial-gradient(900px 480px at -8% -4%, rgba(63,207,142,.035), transparent 55%),
    var(--bg);
  -webkit-font-smoothing:antialiased;font-feature-settings:"tnum" 1}

.header{position:sticky;top:0;z-index:10;
  background:linear-gradient(180deg,rgba(10,12,16,.96),rgba(10,12,16,.80));
  backdrop-filter:blur(10px);border-bottom:1px solid var(--line);padding:14px 24px}
.header .bar{max-width:1200px;margin:0 auto;display:flex;align-items:baseline;gap:14px;flex-wrap:wrap}
.header .title{font-size:14px;font-weight:600;letter-spacing:.18em;text-transform:uppercase;color:var(--ink-dim)}
.header .title b{color:var(--primary);font-weight:700}
.header .meta{font-size:12px;color:var(--ink-dim);font-family:var(--mono);margin-left:auto}

.container{max-width:1200px;margin:0 auto;padding:22px 24px 72px}

.kpis{display:grid;grid-template-columns:repeat(5,1fr);gap:12px;margin-bottom:16px}
.kpi{position:relative;background:linear-gradient(180deg,var(--panel),var(--panel-2));
  border:1px solid var(--line);border-radius:14px;padding:15px 16px;overflow:hidden}
.kpi::before{content:"";position:absolute;left:0;top:0;height:2px;width:100%;
  background:linear-gradient(90deg,var(--primary),transparent 72%);opacity:.7}
.kpi .k{font-size:10.5px;color:var(--ink-dim);text-transform:uppercase;letter-spacing:.12em}
.kpi .val{font-family:var(--mono);font-size:23px;font-weight:600;margin-top:9px;
  font-variant-numeric:tabular-nums;letter-spacing:-.01em}
.kpi .val.accent{color:var(--primary)} .kpi .val.warn{color:var(--amber)}

.note{display:flex;gap:10px;align-items:flex-start;background:rgba(243,176,78,.07);
  border:1px solid rgba(243,176,78,.28);border-radius:12px;
  padding:11px 14px;font-size:12px;color:var(--amber);margin-bottom:14px;line-height:1.5}
.note::before{content:"!";flex:0 0 auto;width:18px;height:18px;border-radius:50%;
  background:rgba(243,176,78,.18);font-weight:700;display:grid;place-items:center;font-size:11px;margin-top:1px}
.flag{background:linear-gradient(180deg,rgba(240,85,107,.13),rgba(240,85,107,.05));
  border:1px solid rgba(240,85,107,.45);border-left:3px solid var(--red);
  border-radius:12px;padding:14px 16px;margin-bottom:14px}
.flag .h{font-size:12px;font-weight:700;color:var(--red);text-transform:uppercase;letter-spacing:.1em;margin-bottom:6px}
.flag .b{font-size:13px;color:var(--ink);line-height:1.55}
.flag .big{font-family:var(--mono);font-size:19px;font-weight:700;color:var(--red)}

.toolbar{display:flex;justify-content:flex-end;gap:8px;margin:2px 0 12px}
.tbtn{font-family:var(--sans);font-size:11.5px;letter-spacing:.03em;color:var(--ink-dim);
  background:var(--panel);border:1px solid var(--line);border-radius:8px;
  padding:6px 11px;cursor:pointer;transition:border-color .15s,color .15s}
.tbtn:hover{color:var(--ink);border-color:var(--line-2)}

details.card{background:linear-gradient(180deg,var(--panel),var(--panel-2));
  border:1px solid var(--line);border-radius:14px;margin-bottom:12px;overflow:hidden}
details.card[open]{border-color:var(--line-2)}
details.card>summary{list-style:none;cursor:pointer;user-select:none;
  display:flex;align-items:center;gap:11px;padding:13px 16px;
  font-size:12px;font-weight:600;color:var(--ink-dim);text-transform:uppercase;letter-spacing:.09em}
details.card>summary::-webkit-details-marker{display:none}
details.card>summary:hover{color:var(--ink)}
details.card>summary::before{content:"";flex:0 0 auto;width:6px;height:6px;
  border-right:2px solid var(--primary);border-bottom:2px solid var(--primary);
  transform:rotate(-45deg);transition:transform .2s ease}
details.card[open]>summary::before{transform:rotate(45deg)}
details.card[open]>summary{color:var(--ink);border-bottom:1px solid var(--line)}
.badge{margin-left:auto;font-family:var(--mono);font-size:11px;font-weight:600;letter-spacing:0;
  color:var(--ink-dim);background:var(--inset);border:1px solid var(--line);
  border-radius:999px;padding:2px 9px;text-transform:none}
details.card[open]>summary .badge{color:var(--primary);border-color:var(--line-2)}

.grid2{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}
details.card>.bars{padding:6px 14px 14px}
details.card>pre{margin:0 14px 14px}

.bars .row{display:grid;grid-template-columns:104px 1fr 1.4fr;gap:12px;align-items:center;
  padding:5px 8px;border-radius:8px;font-size:12.5px;transition:background .12s}
.bars .row:hover{background:var(--inset)}
.bars .v{text-align:right;font-family:var(--mono);color:var(--primary);
  font-variant-numeric:tabular-nums;white-space:nowrap}
.bars .bar{height:6px;background:var(--inset);border-radius:999px;overflow:hidden}
.bars .bar i{display:block;height:100%;border-radius:999px;
  background:linear-gradient(90deg,var(--primary-2),var(--primary))}
.bars .p{font-family:var(--mono);color:var(--ink);white-space:nowrap;overflow:hidden;
  text-overflow:ellipsis;direction:rtl;text-align:left}
.bars .p .age{color:var(--ink-faint)}
.bars.count .v{color:var(--green)}
.bars.count .bar i{background:linear-gradient(90deg,var(--green-2),var(--green))}
.bars.warn .v{color:var(--amber)}
.bars.warn .bar i{background:linear-gradient(90deg,var(--amber-2),var(--amber))}
.bars .row.old10 .v{color:var(--red);font-weight:700}
.bars .row.old10 .bar i{background:linear-gradient(90deg,var(--red-2),var(--red))}
.bars .row.old10 .p{color:var(--red)}
details.card.o10[open]{border-color:rgba(240,85,107,.45)}
details.card.o10>summary .badge{color:var(--red);border-color:rgba(240,85,107,.45)}
.o10cap{font-family:var(--mono);font-size:11px;color:var(--ink-faint);padding:0 8px 8px}
.o10cap code{color:var(--ink-dim)}

pre{background:var(--inset);border:1px solid var(--line);border-radius:10px;
  padding:12px;overflow:auto;font-family:var(--mono);font-size:12px;line-height:1.5;margin:0;color:var(--ink-dim)}
.footer{color:var(--ink-faint);font-size:11.5px;margin-top:20px;text-align:center;
  font-family:var(--mono);letter-spacing:.03em}

@media(max-width:860px){
  .kpis{grid-template-columns:repeat(2,1fr)}
  .grid2{grid-template-columns:1fr}
  .header .meta{margin-left:0;width:100%}
  .bars .row{grid-template-columns:84px 84px 1fr}
}
@media(prefers-reduced-motion:reduce){*{transition:none!important}}
/* --- search box --- */
.toolbar{align-items:center}
.search{flex:1 1 auto;min-width:160px;margin-right:auto;position:relative}
.search input{width:100%;background:var(--inset);border:1px solid var(--line);color:var(--ink);
  border-radius:9px;padding:8px 32px 8px 12px;font-family:var(--mono);font-size:13px}
.search input::placeholder{color:var(--ink-faint)}
.search input:focus{outline:none;border-color:var(--primary)}
.search .clr{position:absolute;right:8px;top:50%;transform:translateY(-50%);cursor:pointer;
  color:var(--ink-faint);font-size:15px;line-height:1;border:0;background:none;padding:0;display:none}
.search .clr:hover{color:var(--ink)}
.scount{font-size:11.5px;color:var(--ink-dim);font-family:var(--mono);white-space:nowrap;align-self:center}
.bars .row.sa-hide{display:none}
details.card.sa-dim{opacity:.35}
.sa-empty{padding:10px 14px;color:var(--ink-faint);font-family:var(--mono);font-size:12.5px;display:none}
mark{background:rgba(243,176,78,.32);color:inherit;border-radius:3px;padding:0 1px}

/* --- charts --- */
.chartcard .cwrap{display:grid;grid-template-columns:1fr 1fr;gap:10px;padding:8px 14px 16px}
@media(max-width:780px){.chartcard .cwrap{grid-template-columns:1fr}}
.chart{min-width:0}
.chart .ct{font-size:11px;color:var(--ink-dim);text-transform:uppercase;letter-spacing:.1em;margin:4px 2px 8px}
.chart svg{width:100%;height:auto;display:block;overflow:visible}
.cbtns{display:flex;gap:6px;margin:0 0 4px}
.cbtn{font-family:var(--sans);font-size:11px;color:var(--ink-dim);background:var(--panel);
  border:1px solid var(--line);border-radius:7px;padding:4px 10px;cursor:pointer}
.cbtn.on{color:var(--ink);border-color:var(--primary);background:rgba(91,157,255,.12)}
.g-grid{stroke:var(--line);stroke-width:1}
.g-axis{fill:var(--ink-faint);font-family:var(--mono);font-size:10px}
.g-bar{fill:var(--primary);transition:opacity .12s}
.g-bar.o10{fill:var(--red)}
.g-bar:hover{opacity:.8;cursor:pointer}
.g-area{fill:rgba(91,157,255,.12)}
.g-line{fill:none;stroke:var(--primary);stroke-width:2}
.g-dot{fill:var(--bg);stroke:var(--primary);stroke-width:2}
.g-dot:hover{fill:var(--primary);cursor:pointer}
.tip{position:fixed;z-index:50;pointer-events:none;display:none;background:var(--panel);
  border:1px solid var(--line-2);border-radius:8px;padding:6px 9px;font-family:var(--mono);
  font-size:11.5px;color:var(--ink);box-shadow:0 6px 20px rgba(0,0,0,.5);white-space:nowrap}
.tip b{color:var(--primary)}

/* --- executive dashboard (mockup) --- */
.kpi .sub{font-size:11px;color:var(--ink-faint);font-family:var(--mono);margin-top:3px}
.exec{display:grid;grid-template-columns:350px 1fr;gap:14px;margin:4px 0 14px}
@media(max-width:1000px){.exec{grid-template-columns:1fr}}
.panel{background:linear-gradient(180deg,var(--panel),var(--panel-2));border:1px solid var(--line);
  border-radius:14px;padding:14px 16px}
.panel h3{margin:0 0 11px;font-size:11px;color:var(--primary);text-transform:uppercase;letter-spacing:.13em;font-weight:700}
.exec-left,.exec-right{display:flex;flex-direction:column;gap:14px}
.kv{display:flex;justify-content:space-between;gap:10px;padding:5px 0;border-bottom:1px solid var(--line);font-size:12.5px}
.kv:last-child{border-bottom:0}
.kv .key{color:var(--ink-dim)} .kv .v{font-family:var(--mono);color:var(--ink);text-align:right;max-width:60%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.row2{display:grid;grid-template-columns:1fr 1fr;gap:14px}
.row3{display:grid;grid-template-columns:1.05fr 1fr;gap:14px}
@media(max-width:900px){.row2,.row3{grid-template-columns:1fr}}
.donutwrap{display:flex;align-items:center;gap:16px}
.donutwrap svg{flex:0 0 auto;width:150px;height:150px}
.legend{display:flex;flex-direction:column;gap:7px;font-size:12px;min-width:0;flex:1 1 auto}
.legend .li{display:flex;align-items:center;gap:8px}
.legend .dot{width:10px;height:10px;border-radius:3px;flex:0 0 auto}
.legend .ll{color:var(--ink-dim);flex:1 1 auto;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.legend .lv{font-family:var(--mono);color:var(--ink);white-space:nowrap}
.legend .ld{color:var(--ink-faint);font-size:11px;display:block;margin-left:18px;margin-top:-3px}
.callout{margin-top:12px;font-size:12.5px;color:var(--ink-dim);line-height:1.5}
.callout b{color:var(--red)}
table.top10{width:100%;border-collapse:collapse;font-size:12.5px}
table.top10 td{padding:5px 4px;border-bottom:1px solid var(--line)}
table.top10 .rk{color:var(--ink-faint);width:20px;font-family:var(--mono)}
table.top10 .dir{font-family:var(--mono);color:var(--ink);max-width:0;width:100%;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
table.top10 .sz{font-family:var(--mono);color:var(--primary);text-align:right;white-space:nowrap}
table.top10 .pc{font-family:var(--mono);color:var(--ink-dim);text-align:right;width:46px}
table.top10 tr.other td{color:var(--ink-faint);border-bottom:0}
.stat-list .kv .v{color:var(--primary)}
.exec-bottom{display:grid;grid-template-columns:1.7fr 1fr;gap:14px;margin-bottom:16px}
@media(max-width:900px){.exec-bottom{grid-template-columns:1fr}}
.summary-txt{font-size:13px;color:var(--ink-dim);line-height:1.75}
.summary-txt b{color:var(--ink)} .summary-txt .hl{color:var(--primary)} .summary-txt .hlr{color:var(--red)}
.outs{display:flex;flex-direction:column;gap:11px}
.out{display:flex;align-items:center;gap:11px;font-size:12.5px}
.out .ic{width:34px;height:34px;border-radius:8px;display:flex;align-items:center;justify-content:center;
  font-size:10px;font-weight:800;color:#0a0c10;flex:0 0 auto;letter-spacing:.02em}
.out .ic.csv{background:var(--green)} .out .ic.html{background:var(--primary)} .out .ic.gz{background:var(--amber)}
.out .nm{font-family:var(--mono);color:var(--ink)} .out .ds{color:var(--ink-faint);font-size:11px}
.g-slice{transition:opacity .12s} .g-slice:hover{opacity:.82;cursor:pointer}
.donut-c1{fill:var(--ink);font-family:var(--mono);font-weight:700;font-size:9px;text-anchor:middle}
.pg-grid{fill:none;stroke:var(--line);stroke-width:.5}
.pg-axis-l{stroke:var(--line);stroke-width:.5}
.pg-area{fill:rgba(91,157,255,.16);stroke:var(--primary);stroke-width:1.4;stroke-linejoin:round}
.pg-dot{stroke:var(--bg);stroke-width:.8;transition:r .12s}
.pg-dot:hover{cursor:pointer}
.pg-lab{fill:var(--ink-faint);font-family:var(--mono);font-size:5px;font-weight:600}
.donut-c2{fill:var(--ink-dim);font-family:var(--mono);font-size:7px;text-anchor:middle}
.g-hbar{fill:var(--primary);transition:opacity .12s} .g-hbar:hover{opacity:.82;cursor:pointer}
.g-hval{fill:var(--ink-dim);font-family:var(--mono);font-size:11px}
.g-hlab{fill:var(--ink-dim);font-family:var(--mono);font-size:11px;text-anchor:end}

</style>
</head>
<body>
<div class="header"><div class="bar">
  <div class="title">Space <b>Audit</b></div>
  <div class="meta">${HOST} &middot; ${ROOT_H} &middot; $(date '+%Y-%m-%d %H:%M:%S') &middot; atime ${ATIME_MODE} &middot; ${ELAPSED}s</div>
</div></div>
<div class="container">

  <div class="kpis">
    <div class="kpi"><div class="k">Spazio totale scansionato</div><div class="val accent">${SIZE_H}</div><div class="sub">${BYTES_FMT} byte</div></div>
    <div class="kpi"><div class="k">File totali</div><div class="val">${FILES_FMT}</div><div class="sub">file</div></div>
    <div class="kpi"><div class="k">Directory con file</div><div class="val">${DIRS_FMT}</div><div class="sub">directory</div></div>
    <div class="kpi"><div class="k">Data scansione</div><div class="val" style="font-size:18px">${DATE_SCAN_D}</div><div class="sub">${DATE_SCAN_T}</div></div>
    <div class="kpi"><div class="k">Durata scansione</div><div class="val" style="font-size:18px">${DUR_HMS}</div><div class="sub">hh:mm:ss &middot; uso disco ${USED_PCT}</div></div>
  </div>

  <div class="note">
    CLEANUP e RECUPERABILE sono euristiche basate su <b>mtime</b> &mdash; verificare prima di agire.
    I software di backup (Veeam, Commvault, Netbackup&hellip;) possono mantenere mtime vecchio su file vivi.
    Escludere percorsi di DB / backup / cache attivi. Strumento di sola lettura: nessun file modificato.
  </div>

  ${OLD10_BANNER}

  <div class="exec">
    <div class="exec-left">
      <div class="panel">
        <h3>Filtri applicati</h3>
        <div class="kv"><span class="key">Percorso scansionato</span><span class="v" title="${ROOT_H}">${ROOT_H}</span></div>
        <div class="kv"><span class="key">Profondit&agrave; directory</span><span class="v">${AGG_DEPTH} livelli</span></div>
        <div class="kv"><span class="key">File system</span><span class="v">${FSTYPE}</span></div>
        <div class="kv"><span class="key">Esclusioni</span><span class="v">attive (${NEXCL})</span></div>
        <div class="kv"><span class="key">Attraversa mount</span><span class="v">$([[ "$CROSS_MOUNTS" = "1" ]] && echo "s&igrave;" || echo "no (-xdev)")</span></div>
      </div>
      <div class="panel">
        <h3>Distribuzione spazio per et&agrave; file</h3>
        <div class="donutwrap">
          <svg id="sa-donut-age" viewBox="0 0 100 100" role="img" aria-label="Grafico pentagonale: quota di spazio per fascia di eta"></svg>
          <div class="legend" id="sa-leg-age"></div>
        </div>
        <div class="callout">I dati con et&agrave; <b>&gt; 10 anni</b> rappresentano il <b>${OLD10_PCT}%</b> dello spazio totale scansionato.</div>
      </div>
      <div class="panel">
        <h3>Top 10 directory per spazio</h3>
        <table class="top10">${TOP10_ROWS}</table>
      </div>
    </div>

    <div class="exec-right">
      <div class="panel">
        <h3>Trend spazio nel tempo (cumulato per et&agrave; di ultima modifica)</h3>
        <svg id="sa-trend" viewBox="0 0 760 300" preserveAspectRatio="xMidYMid meet" role="img" aria-label="Trend cumulativo per eta"></svg>
      </div>
      <div class="row3">
        <div class="panel">
          <h3>Distribuzione per tipologia file (per spazio)</h3>
          <div class="donutwrap">
            <svg id="sa-donut-type" viewBox="0 0 100 100" role="img" aria-label="Distribuzione per tipologia"></svg>
            <div class="legend" id="sa-leg-type"></div>
          </div>
        </div>
        <div class="panel">
          <h3>Distribuzione per dimensione file (per numero)</h3>
          <svg id="sa-size" viewBox="0 0 430 230" preserveAspectRatio="xMidYMid meet" role="img" aria-label="Distribuzione per dimensione file"></svg>
        </div>
      </div>
      <div class="row2">
        <div class="panel stat-list">
          <h3>Statistiche aggiuntive</h3>
          <div class="kv"><span class="key">Dimensione media file</span><span class="v">${AVG_H}</span></div>
          <div class="kv"><span class="key">File pi&ugrave; grande</span><span class="v">${MAXF_H}</span></div>
          <div class="kv"><span class="key">File pi&ugrave; recente</span><span class="v">${NEWEST_D}</span></div>
          <div class="kv"><span class="key">File pi&ugrave; vecchio</span><span class="v">${OLDEST_D}</span></div>
          <div class="kv"><span class="key">Profondit&agrave; max path</span><span class="v">${MAX_DEPTH} liv.</span></div>
          <div class="kv"><span class="key">Hard / symbolic link</span><span class="v">n/d</span></div>
        </div>
        <div class="panel">
          <h3>Legenda et&agrave; file</h3>
          <div class="legend" id="sa-leg-age2"></div>
        </div>
      </div>
    </div>
  </div>

  <div class="exec-bottom">
    <div class="panel">
      <h3>Riepilogo esecutivo</h3>
      <div class="summary-txt">La scansione ha analizzato <span class="hl">${SIZE_H}</span> di dati distribuiti su <b>${FILES_FMT}</b> file e <b>${DIRS_FMT}</b> directory con contenuto. Il <span class="hlr">${OLD10_PCT}%</span> dello spazio &egrave; costituito da file con et&agrave; superiore a <b>10 anni</b> ($(human "$OLD10_BYTES") in $(fmt_int "$OLD10_CNT") file), potenzialmente candidati ad archiviazione o revisione secondo le policy di retention vigenti. Spazio potenzialmente recuperabile stimato: <b>$(human "$RECOVERABLE_BYTES")</b>. Strumento di sola lettura: nessun file &egrave; stato modificato.</div>
    </div>
    <div class="panel">
      <h3>Output generati</h3>
      <div class="outs">
        <div class="out"><span class="ic html">HTML</span><span><span class="nm">$(basename "$HTML")</span><br><span class="ds">Dashboard HTML</span></span></div>
        $({ [[ "${HAVE_DATASET:-1}" = "1" ]] && echo "<div class=\"out\"><span class=\"ic gz\">GZ</span><span><span class=\"nm\">$(basename "$DATA")</span><br><span class=\"ds\">Dataset compresso</span></span></div>"; } || true)
        $({ (( OLD10_CNT > 0 )) && [[ "$FAST" != "1" ]] && echo "<div class=\"out\"><span class=\"ic csv\">CSV</span><span><span class=\"nm\">$(basename "$CSV10")</span><br><span class=\"ds\">Report &gt;10 anni (Excel)</span></span></div>"; } || true)
      </div>
    </div>
  </div>

  <div class="toolbar">
    <div class="search">
      <input id="sa-search" type="text" placeholder="Cerca per percorso (directory, file, estensione)..." autocomplete="off" spellcheck="false">
      <button type="button" class="clr" id="sa-clr" title="Pulisci ricerca">&times;</button>
    </div>
    <span class="scount" id="sa-count"></span>
    <button type="button" class="tbtn" data-act="open">Espandi tutto</button>
    <button type="button" class="tbtn" data-act="close">Comprimi tutto</button>
  </div>

  ${OLD10_SECTION}

  <details class="card">
    <summary>Filesystem<span class="badge">${USED_PCT}</span></summary>
    <pre>$(df -hT "$ROOT" 2>/dev/null | esc_html || echo "(df non disponibile)")</pre>
  </details>

  <details class="card sa-noscan">
    <summary>Age distribution<span class="badge">${FILES_FMT} file</span></summary>
    <div class="bars">
HTMLHEAD

awk '
function hum(b){ if(b>=1099511627776)return sprintf("%.2f TB",b/1099511627776); if(b>=1073741824)return sprintf("%.2f GB",b/1073741824); if(b>=1048576)return sprintf("%.1f MB",b/1048576); if(b>=1024)return sprintf("%.1f KB",b/1024); return sprintf("%d B",b) }
{lb[NR]=$1;ct[NR]=$2;by[NR]=$5;n=NR; if($5>mx)mx=$5}
END{for(i=1;i<=n;i++){w=(mx>0)?by[i]/mx*100:0;
  cls=(lb[i]==">10y" && ct[i]+0>0)?" old10":"";
  printf "<div class=\"row%s\"><div class=\"v\">%s</div><div class=\"bar\"><i style=\"width:%.1f%%\"></i></div><div class=\"p\">%s &middot; %d files</div></div>\n",cls,hum(by[i]),w,lb[i],ct[i]}}' "$AGEF"

cat <<HTMLMID
    </div>
  </details>

  <div class="grid2">
    <details class="card">
      <summary>Top directories (by size)<span class="badge">${N_DIRSZ}</span></summary>
      <div class="bars">
HTMLMID

awk -F'\t' -v gb="$GB" '
function esc(s){gsub(/&/,"\\&amp;",s);gsub(/</,"\\&lt;",s);gsub(/>/,"\\&gt;",s);return s}
function hum(b){ if(b>=1099511627776)return sprintf("%.2f TB",b/1099511627776); if(b>=1073741824)return sprintf("%.2f GB",b/1073741824); if(b>=1048576)return sprintf("%.1f MB",b/1048576); if(b>=1024)return sprintf("%.1f KB",b/1024); return sprintf("%d B",b) }
{v[NR]=$1;p[NR]=$3;n=NR; if($1>mx)mx=$1}
END{for(i=1;i<=n;i++){w=(mx>0)?v[i]/mx*100:0;
  printf "<div class=\"row\"><div class=\"v\">%s</div><div class=\"bar\"><i style=\"width:%.1f%%\"></i></div><div class=\"p\">%s</div></div>\n",hum(v[i]),w,esc(p[i])}}' "$T_DIRSZ"

cat <<HTMLMID
      </div>
    </details>
    <details class="card">
      <summary>Top directories (by file count)<span class="badge">${N_DIRCNT}</span></summary>
      <div class="bars count">
HTMLMID

awk -F'\t' '
function esc(s){gsub(/&/,"\\&amp;",s);gsub(/</,"\\&lt;",s);gsub(/>/,"\\&gt;",s);return s}
{v[NR]=$2;p[NR]=$3;n=NR; if($2>mx)mx=$2}
END{for(i=1;i<=n;i++){w=(mx>0)?v[i]/mx*100:0;
  printf "<div class=\"row\"><div class=\"v\">%d</div><div class=\"bar\"><i style=\"width:%.1f%%\"></i></div><div class=\"p\">%s</div></div>\n",v[i],w,esc(p[i])}}' "$T_DIRCNT"

cat <<HTMLMID
      </div>
    </details>
  </div>

  <details class="card">
    <summary>Top extensions<span class="badge">${N_EXT}</span></summary>
    <div class="bars">
HTMLMID

awk -F'\t' -v gb="$GB" '
function esc(s){gsub(/&/,"\\&amp;",s);gsub(/</,"\\&lt;",s);gsub(/>/,"\\&gt;",s);return s}
function hum(b){ if(b>=1099511627776)return sprintf("%.2f TB",b/1099511627776); if(b>=1073741824)return sprintf("%.2f GB",b/1073741824); if(b>=1048576)return sprintf("%.1f MB",b/1048576); if(b>=1024)return sprintf("%.1f KB",b/1024); return sprintf("%d B",b) }
{v[NR]=$1;e[NR]=$3;n=NR; if($1>mx)mx=$1}
END{for(i=1;i<=n;i++){w=(mx>0)?v[i]/mx*100:0;
  printf "<div class=\"row\"><div class=\"v\">%s</div><div class=\"bar\"><i style=\"width:%.1f%%\"></i></div><div class=\"p\">.%s</div></div>\n",hum(v[i]),w,esc(e[i])}}' "$T_EXT"

cat <<HTMLMID
    </div>
  </details>

  <details class="card">
    <summary>Top proprietari per spazio<span class="badge">${N_OWN}</span></summary>
    <div class="bars">${OWNER_ROWS}</div>
  </details>
HTMLMID
if [[ "$FAST" != "1" ]]; then
cat <<HTMLMID
  <details class="card">
    <summary>Top files<span class="badge">${N_TOPF}</span></summary>
    <div class="bars">
HTMLMID

awk -F'\t' -v gb="$GB" '
function esc(s){gsub(/&/,"\\&amp;",s);gsub(/</,"\\&lt;",s);gsub(/>/,"\\&gt;",s);return s}
function hum(b){ if(b>=1099511627776)return sprintf("%.2f TB",b/1099511627776); if(b>=1073741824)return sprintf("%.2f GB",b/1073741824); if(b>=1048576)return sprintf("%.1f MB",b/1048576); if(b>=1024)return sprintf("%.1f KB",b/1024); return sprintf("%d B",b) }
{v[NR]=$1;ag[NR]=$2;p[NR]=$3;n=NR; if($1>mx)mx=$1}
END{for(i=1;i<=n;i++){w=(mx>0)?v[i]/mx*100:0;
  printf "<div class=\"row\"><div class=\"v\">%s</div><div class=\"bar\"><i style=\"width:%.1f%%\"></i></div><div class=\"p\">%s <span class=\"age\">%dd</span></div></div>\n",hum(v[i]),w,esc(p[i]),ag[i]}}' "$T_TOPF"

cat <<HTMLMID
    </div>
  </details>

  <details class="card">
    <summary>Top files older than threshold<span class="badge">${N_OLDER}</span></summary>
    <div class="bars">
HTMLMID

awk -F'\t' -v gb="$GB" '
function esc(s){gsub(/&/,"\\&amp;",s);gsub(/</,"\\&lt;",s);gsub(/>/,"\\&gt;",s);return s}
function hum(b){ if(b>=1099511627776)return sprintf("%.2f TB",b/1099511627776); if(b>=1073741824)return sprintf("%.2f GB",b/1073741824); if(b>=1048576)return sprintf("%.1f MB",b/1048576); if(b>=1024)return sprintf("%.1f KB",b/1024); return sprintf("%d B",b) }
{v[NR]=$1;yy[NR]=$2;p[NR]=$3;n=NR; if($1>mx)mx=$1}
END{for(i=1;i<=n;i++){w=(mx>0)?v[i]/mx*100:0;
  printf "<div class=\"row\"><div class=\"v\">%s</div><div class=\"bar\"><i style=\"width:%.1f%%\"></i></div><div class=\"p\">%s <span class=\"age\">%dy</span></div></div>\n",hum(v[i]),w,esc(p[i]),yy[i]}}' "$T_OLDER"

cat <<HTMLMID
    </div>
  </details>

  <details class="card">
    <summary>Cleanup candidates (size &times; log age&sup2;)<span class="badge">${N_CLEAN}</span></summary>
    <div class="bars warn">
HTMLMID

awk -F'\t' -v gb="$GB" '
function esc(s){gsub(/&/,"\\&amp;",s);gsub(/</,"\\&lt;",s);gsub(/>/,"\\&gt;",s);return s}
function hum(b){ if(b>=1099511627776)return sprintf("%.2f TB",b/1099511627776); if(b>=1073741824)return sprintf("%.2f GB",b/1073741824); if(b>=1048576)return sprintf("%.1f MB",b/1048576); if(b>=1024)return sprintf("%.1f KB",b/1024); return sprintf("%d B",b) }
{sc[NR]=$1;v[NR]=$2;ag[NR]=$3;p[NR]=$4;n=NR; if($1>mx)mx=$1}
END{for(i=1;i<=n;i++){w=(mx>0)?sc[i]/mx*100:0;
  printf "<div class=\"row\"><div class=\"v\">%s</div><div class=\"bar\"><i style=\"width:%.1f%%\"></i></div><div class=\"p\">%s <span class=\"age\">%dd</span></div></div>\n",hum(v[i]),w,esc(p[i]),ag[i]}}' "$T_CLEAN"

cat <<HTMLMID
    </div>
  </details>
HTMLMID
fi

cat <<HTMLFOOT

  <div class="footer">Generated by Space Audit &middot; read-only scan &middot; no modifications performed &middot; ${HOST} ${TS}</div>
</div>
HTMLFOOT

# dati dei grafici (array JS) costruiti lato shell dai file gia' prodotti
printf '<script>\n'
printf 'window.SA_BANDS=%s;\n' "$SA_BANDS"
printf 'window.SA_TYPES=%s;\n' "$SA_TYPES"
printf 'window.SA_SIZES=%s;\n' "$SA_SIZES"
printf 'window.SA_TOTAL_H="%s";\n' "$SIZE_H"
printf '</script>\n'

cat <<'HTMLJS'
<script>
(function(){
  "use strict";
  var SVGNS="http://www.w3.org/2000/svg";
  function el(t,a){var e=document.createElementNS(SVGNS,t);if(a)for(var k in a)e.setAttribute(k,a[k]);return e;}
  function clr(s){while(s&&s.firstChild)s.removeChild(s.firstChild);}
  function fmtInt(n){return String(Math.round(n)).replace(/\B(?=(\d{3})+(?!\d))/g,".");}
  function fmtSize(b){b=+b;if(!isFinite(b)||b<=0)return "0 B";var T=1099511627776,G=1073741824,M=1048576,K=1024;
    if(b>=T)return (b/T).toFixed(2)+" TB";if(b>=G)return (b/G).toFixed(2)+" GB";if(b>=M)return (b/M).toFixed(1)+" MB";if(b>=K)return (b/K).toFixed(1)+" KB";return Math.round(b)+" B";}
  function niceMax(m){if(m<=0)return 1;var p=Math.pow(10,Math.floor(Math.log(m)/Math.LN10));var f=m/p;var n=f<=1?1:f<=2?2:f<=5?5:10;return n*p;}

  // tooltip
  var tip=document.createElement('div');tip.className='tip';document.body.appendChild(tip);
  function showTip(h,x,y){tip.innerHTML=h;tip.style.display='block';
    tip.style.left=Math.min(x+14,window.innerWidth-tip.offsetWidth-8)+'px';tip.style.top=(y+14)+'px';}
  function hideTip(){tip.style.display='none';}

  // expand / collapse
  var tb=document.querySelectorAll('.tbtn');
  for(var i=0;i<tb.length;i++){tb[i].addEventListener('click',function(){
    var op=this.getAttribute('data-act')==='open';var ds=document.querySelectorAll('details.card');
    for(var j=0;j<ds.length;j++)ds[j].open=op;});}

  // dati normalizzati {l,v,col}
  function norm(a){return (a||[]).map(function(d){return {l:d.l,v:(d.b!=null?+d.b:(+d.g)*1073741824),col:d.col};});}
  var BANDS=norm(window.SA_BANDS), TYPES=norm(window.SA_TYPES), TOTAL_H=window.SA_TOTAL_H||"";
  var AGE_DESC={'0-1 anno':'Modificati negli ultimi 12 mesi','1-2 anni':'Modificati tra 1 e 2 anni fa','2-5 anni':'Modificati tra 2 e 5 anni fa','5-10 anni':'Modificati tra 5 e 10 anni fa','>10 anni':'Modificati piu di 10 anni fa'};

  // --- donut ---
  function donut(id,data,center){
    var svg=document.getElementById(id);if(!svg)return;clr(svg);
    var total=0,k;for(k=0;k<data.length;k++)total+=data[k].v;
    var cx=50,cy=50,r=42,ir=26,a0=0;
    if(total<=0) svg.appendChild(el('circle',{cx:cx,cy:cy,r:(r+ir)/2,fill:'none',stroke:'#28323f','stroke-width':r-ir}));
    for(k=0;k<data.length;k++){
      var frac=data[k].v/(total||1);if(frac<=0)continue;
      var a1=a0+frac*2*Math.PI,large=(a1-a0)>Math.PI?1:0;
      var x0=cx+r*Math.sin(a0),y0=cy-r*Math.cos(a0),x1=cx+r*Math.sin(a1),y1=cy-r*Math.cos(a1);
      var xi1=cx+ir*Math.sin(a1),yi1=cy-ir*Math.cos(a1),xi0=cx+ir*Math.sin(a0),yi0=cy-ir*Math.cos(a0);
      var d='M'+x0+','+y0+' A'+r+','+r+' 0 '+large+' 1 '+x1+','+y1+' L'+xi1+','+yi1+' A'+ir+','+ir+' 0 '+large+' 0 '+xi0+','+yi0+' Z';
      var path=el('path',{class:'g-slice',d:d,fill:data[k].col});
      (function(dd,fr){var pc=(fr*100).toFixed(1);
        path.addEventListener('mousemove',function(e){showTip('<b>'+dd.l+'</b> &middot; '+fmtSize(dd.v)+' ('+pc+'%)',e.clientX,e.clientY);});
        path.addEventListener('mouseleave',hideTip);})(data[k],frac);
      svg.appendChild(path);a0=a1;
    }
    if(center){var t=el('text',{class:'donut-c1',x:cx,y:cy+3});t.textContent=center;svg.appendChild(t);}
  }

  // --- grafico pentagonale (radar a 5 assi): quota di spazio per fascia d'eta' ---
  var PG_SHORT={"0-1 anno":"0-1a","1-2 anni":"1-2a","2-5 anni":"2-5a","5-10 anni":"5-10a",">10 anni":">10a"};
  function pentagon(id,data){
    var svg=document.getElementById(id);if(!svg)return;clr(svg);
    var n=data.length;if(!n)return;
    var cx=50,cy=52,R=29,k;
    var tot=0;for(k=0;k<n;k++)tot+=data[k].v;
    var sh=[],mxs=0;for(k=0;k<n;k++){var s=tot>0?data[k].v/tot:0;sh.push(s);if(s>mxs)mxs=s;}
    if(mxs<=0)mxs=1;
    function pt(i,rad){var a=-Math.PI/2+i*2*Math.PI/n;return [cx+rad*Math.cos(a),cy+rad*Math.sin(a)];}
    // griglia: pentagoni concentrici
    var lv=[0.25,0.5,0.75,1],g,p,d;
    for(g=0;g<lv.length;g++){d="";for(k=0;k<n;k++){p=pt(k,R*lv[g]);d+=(k?" L":"M")+p[0].toFixed(2)+","+p[1].toFixed(2);}d+=" Z";
      svg.appendChild(el('path',{class:'pg-grid',d:d}));}
    // assi radiali
    for(k=0;k<n;k++){p=pt(k,R);svg.appendChild(el('line',{class:'pg-axis-l',x1:cx,y1:cy,x2:p[0].toFixed(2),y2:p[1].toFixed(2)}));}
    // poligono dei valori (raggio = quota / quota_max)
    d="";for(k=0;k<n;k++){p=pt(k,R*(sh[k]/mxs));d+=(k?" L":"M")+p[0].toFixed(2)+","+p[1].toFixed(2);}d+=" Z";
    svg.appendChild(el('path',{class:'pg-area',d:d}));
    // vertici (colore per fascia) + etichetta compatta + tooltip
    for(k=0;k<n;k++){
      p=pt(k,R*(sh[k]/mxs));
      var c=el('circle',{class:'pg-dot',cx:p[0].toFixed(2),cy:p[1].toFixed(2),r:2.4,fill:data[k].col});
      (function(dd,frac){var pc=(frac*100).toFixed(1);
        c.addEventListener('mousemove',function(e){showTip('<b>'+dd.l+'</b> &middot; '+fmtSize(dd.v)+' ('+pc+'%)',e.clientX,e.clientY);});
        c.addEventListener('mouseleave',hideTip);})(data[k],sh[k]);
      svg.appendChild(c);
      var lp=pt(k,R+8),an='middle';
      if(lp[0]>cx+1.5)an='start';else if(lp[0]<cx-1.5)an='end';
      var tx=el('text',{class:'pg-lab',x:lp[0].toFixed(2),y:(lp[1]+1.6).toFixed(2),'text-anchor':an});
      tx.textContent=PG_SHORT[data[k].l]||data[k].l;svg.appendChild(tx);
    }
  }

  // --- legend ---
  function legend(id,data,withDesc){
    var box=document.getElementById(id);if(!box)return;box.innerHTML='';
    var total=0,k;for(k=0;k<data.length;k++)total+=data[k].v;
    for(k=0;k<data.length;k++){
      var pc=total>0?(data[k].v/total*100).toFixed(1):'0.0';
      var li=document.createElement('div');li.className='li';
      var dot=document.createElement('span');dot.className='dot';dot.style.background=data[k].col;li.appendChild(dot);
      var ll=document.createElement('span');ll.className='ll';ll.textContent=data[k].l;li.appendChild(ll);
      var lv=document.createElement('span');lv.className='lv';lv.textContent=fmtSize(data[k].v)+' ('+pc+'%)';li.appendChild(lv);
      box.appendChild(li);
      if(withDesc&&AGE_DESC[data[k].l]){var dd=document.createElement('span');dd.className='ld';dd.textContent=AGE_DESC[data[k].l];box.appendChild(dd);}
    }
  }

  // --- area trend (cumulato per eta') ---
  function areaTrend(){
    var svg=document.getElementById('sa-trend');if(!svg)return;clr(svg);
    var b=window.SA_BANDS||[];if(!b.length)return;
    var W=760,H=300,pL=58,pR=20,pT=16,pB=46,pw=W-pL-pR,ph=H-pT-pB;
    var cum=[],run=0,k;for(k=0;k<b.length;k++){run+=(b[k].b!=null?+b[k].b:(+b[k].g)*1073741824);cum.push(run);}
    var mx=niceMax(run);
    for(var s=0;s<=4;s++){var yv=mx*s/4,y=pT+ph-(yv/mx)*ph;
      svg.appendChild(el('line',{class:'g-grid',x1:pL,y1:y,x2:W-pR,y2:y}));
      var t=el('text',{class:'g-axis',x:pL-8,y:y+3,'text-anchor':'end'});t.textContent=fmtSize(yv);svg.appendChild(t);}
    var n=b.length,stepX=pw/(n>1?n-1:1),pts=[];
    for(k=0;k<n;k++){var x=pL+k*stepX,y=pT+ph-(mx>0?cum[k]/mx*ph:0);pts.push([x,y]);}
    var dA='M'+pL+','+(pT+ph);for(k=0;k<n;k++)dA+=' L'+pts[k][0]+','+pts[k][1];dA+=' L'+pts[n-1][0]+','+(pT+ph)+' Z';
    svg.appendChild(el('path',{class:'g-area',d:dA}));
    var dL='M'+pts[0][0]+','+pts[0][1];for(k=1;k<n;k++)dL+=' L'+pts[k][0]+','+pts[k][1];
    svg.appendChild(el('path',{class:'g-line',d:dL}));
    for(k=0;k<n;k++){var c=el('circle',{class:'g-dot',cx:pts[k][0],cy:pts[k][1],r:4.5});
      (function(bb,cv){c.addEventListener('mousemove',function(e){showTip('fino a <b>'+bb.l+'</b> &middot; cumulato '+fmtSize(cv),e.clientX,e.clientY);});c.addEventListener('mouseleave',hideTip);})(b[k],cum[k]);
      svg.appendChild(c);
      var tx=el('text',{class:'g-axis',x:pts[k][0],y:H-pB+17,'text-anchor':'middle'});tx.textContent=b[k].l;svg.appendChild(tx);}
  }

  // --- horizontal bars (per dimensione, per numero) ---
  function hbar(){
    var svg=document.getElementById('sa-size');if(!svg)return;clr(svg);
    var data=window.SA_SIZES||[];if(!data.length)return;
    var W=430,H=230,pL=92,pR=64,pT=10,pB=8,bh=24;
    var gap=((H-pT-pB)-data.length*bh)/(data.length-1>0?data.length-1:1);
    var mx=0,k;for(k=0;k<data.length;k++)if((+data[k].c)>mx)mx=+data[k].c;mx=niceMax(mx);
    for(k=0;k<data.length;k++){
      var y=pT+k*(bh+gap),v=+data[k].c,w=mx>0?(v/mx)*(W-pL-pR):0;
      var lb=el('text',{class:'g-hlab',x:pL-8,y:y+bh/2+4});lb.textContent=data[k].l;svg.appendChild(lb);
      var r=el('rect',{class:'g-hbar',x:pL,y:y,width:Math.max(w,0),height:bh,rx:3});
      (function(d){r.addEventListener('mousemove',function(e){showTip('<b>'+d.l+'</b> &middot; '+fmtInt(d.c)+' file',e.clientX,e.clientY);});r.addEventListener('mouseleave',hideTip);})(data[k]);
      svg.appendChild(r);
      var vt=el('text',{class:'g-hval',x:pL+Math.max(w,0)+6,y:y+bh/2+4});vt.textContent=fmtInt(v);svg.appendChild(vt);
    }
  }

  pentagon('sa-donut-age',BANDS); legend('sa-leg-age',BANDS,false);
  donut('sa-donut-type',TYPES,TOTAL_H); legend('sa-leg-type',TYPES,false);
  legend('sa-leg-age2',BANDS,true);
  areaTrend(); hbar();

  // --- search ---
  var input=document.getElementById('sa-search'),clrb=document.getElementById('sa-clr'),cnt=document.getElementById('sa-count');
  var cards=document.querySelectorAll('details.card'),idx=[];
  for(var c=0;c<cards.length;c++){
    if(cards[c].classList.contains('sa-noscan'))continue;
    var rows=cards[c].querySelectorAll('.bars .row');if(!rows.length)continue;
    var emp=document.createElement('div');emp.className='sa-empty';emp.textContent='Nessun risultato in questa sezione';
    var bars=cards[c].querySelector('.bars');if(bars)bars.appendChild(emp);
    idx.push({card:cards[c],rows:rows,empty:emp});
  }
  function search(q){
    q=(q||'').trim().toLowerCase();clrb.style.display=q?'block':'none';var tot=0;
    for(var r=0;r<idx.length;r++){var b=idx[r],sh=0;
      for(var i2=0;i2<b.rows.length;i2++){var row=b.rows[i2],p=row.querySelector('.p'),txt=p?(p.textContent||''):'';
        if(!q||txt.toLowerCase().indexOf(q)!==-1){row.classList.remove('sa-hide');sh++;}else row.classList.add('sa-hide');}
      tot+=sh;b.empty.style.display=(q&&sh===0)?'block':'none';
      if(q){b.card.open=sh>0;b.card.classList.toggle('sa-dim',sh===0);}else b.card.classList.remove('sa-dim');}
    cnt.textContent=q?(fmtInt(tot)+' risultati'):'';
    if(!q){for(var d=0;d<cards.length;d++)cards[d].open=false;}
  }
  if(input){input.addEventListener('input',function(){search(this.value);});
    clrb.addEventListener('click',function(){input.value='';search('');input.focus();});}
})();
</script>
</body>
</html>
HTMLJS
} > "$HTML"

log "HTML dashboard written"

###############################################################################
# OVER-10Y LIST (export read-only: elenco COMPLETO file > 10 anni, per tool esterni)
###############################################################################

if (( OLD10_CNT > 0 )) && [[ "$FAST" != "1" ]]; then
# T_OVER (size \t age_days \t epoch \t path) e' gia' ordinato per dimensione: lo riuso
# per il gz completo (tool esterni) e per il CSV (revisione Excel).

# elenco completo gz: header + dati
{ printf 'size_bytes\tage_days\tmtime_epoch\tpath\n'; cat "$T_OVER"; } \
  | run_lowprio "${GZIP_CMD[@]}" > "$OVER10"
log "Over-10y list written: $OLD10_CNT files -> $OVER10"

# CSV per revisione (Excel-IT): separatore ';', decimale ',', UTF-8 BOM
# colonne: posizione;nome;data;peso_GB  (data = mtime locale, granularita giorno)
{
  printf '\357\273\277'                       # BOM UTF-8
  printf 'posizione;nome;data;peso_GB\r\n'
  awk -F'\t' -v gb="$GB" -v tzoff="$TZOFF" '
    function csv(s){ if (index(s,";")||index(s,"\"")||index(s,"\r")||index(s,"\n")){ gsub("\"","\"\"",s); return "\"" s "\"" } return s }
    function d2(ts,   z,era,doe,yoe,y,doy,mp,dd,mm){
      z=int((ts+tzoff)/86400)+719468
      era=int((z>=0?z:z-146096)/146097)
      doe=z-era*146097
      yoe=int((doe-int(doe/1460)+int(doe/36524)-int(doe/146096))/365)
      y=yoe+era*400
      doy=doe-(365*yoe+int(yoe/4)-int(yoe/100))
      mp=int((5*doy+2)/153)
      dd=doy-int((153*mp+2)/5)+1
      mm=mp+(mp<10?3:-9)
      y=y+(mm<=2?1:0)
      return sprintf("%04d-%02d-%02d",y,mm,dd)
    }
    {
      path=$4
      name=path; sub(".*/","",name)
      dir=substr(path,1,length(path)-length(name)-1); if(dir=="")dir="/"
      g=sprintf("%.4f",$1/gb); sub(/\./,",",g)
      printf "%s;%s;%s;%s\r\n", csv(dir), csv(name), d2($3), g
    }' "$T_OVER"
} > "$CSV10"
log "Over-10y CSV written: $CSV10"
fi

log "DONE elapsed=$(( $(date +%s) - START ))s files=$TOTAL_FILES size=${SIZE_GB}GB reclaimable=${REC_GB}GB"

# ---- summary machine-readable + contratto exit code (0=ok, 1=fatale, 2=warning) ----
SUMMARY="${BASE}.summary.json"
EXIT_CODE=0; [[ "${WARN:-0}" = "1" ]] && EXIT_CODE=2
_mode="normal"; [[ "$STREAM" = "1" ]] && _mode="stream"; [[ "$FAST" = "1" ]] && _mode="fast"; [[ "$FAST" = "1" && "$STREAM" = "1" ]] && _mode="fast+stream"
_jesc(){ printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
{
  printf '{\n'
  printf '  "host": "%s",\n'                    "$(_jesc "$HOST")"
  printf '  "root": "%s",\n'                    "$(_jesc "$ROOT")"
  printf '  "timestamp": "%s",\n'               "$TS"
  printf '  "mode": "%s",\n'                     "$_mode"
  printf '  "files": %s,\n'                      "${TOTAL_FILES:-0}"
  printf '  "bytes": %s,\n'                      "${TOTAL_BYTES:-0}"
  printf '  "bytes_human": "%s",\n'              "$(human "${TOTAL_BYTES:-0}")"
  printf '  "directories_with_files": %s,\n'     "${DIR_COUNT:-0}"
  printf '  "over10y_count": %s,\n'              "${OLD10_CNT:-0}"
  printf '  "over10y_bytes": %s,\n'              "${OLD10_BYTES:-0}"
  printf '  "reclaimable_bytes": %s,\n'          "${RECOVERABLE_BYTES:-0}"
  printf '  "owners_distinct": %s,\n'            "${N_OWN:-0}"
  printf '  "find_errors": %s,\n'                "${FERR:-0}"
  printf '  "workers_failed": %s,\n'             "${_werr:-0}"
  printf '  "dir_cap_hit": %s,\n'                "$([[ "${DIRCAP:-0}" = "1" ]] && echo true || echo false)"
  printf '  "max_depth": %s,\n'                  "${MAX_DEPTH:-0}"
  printf '  "duration_s": %s,\n'                 "$(( $(date +%s) - START ))"
  printf '  "exit_status": %s\n'                 "$EXIT_CODE"
  printf '}\n'
} > "$SUMMARY"
log "Summary JSON written: $SUMMARY (exit_status=$EXIT_CODE)"

echo "DONE (read-only, no files modified)"
if [[ "${HAVE_DATASET:-1}" = "1" ]]; then echo "Dataset : $DATA"; else echo "Dataset : (streaming: nessun dataset intermedio)"; fi
echo "Report  : $REPORT"
echo "HTML    : $HTML"
[[ -f "$OVER10" ]] && echo "Over10y : $OVER10"
[[ -f "$CSV10" ]] && echo "CSV10y  : $CSV10"
echo "Summary : $SUMMARY"
echo "Log     : $LOGFILE"
[[ "$EXIT_CODE" = "2" ]] && echo "NOTE    : completato con warning (exit 2)"
exit "$EXIT_CODE"
