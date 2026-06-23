#!/usr/bin/env bash
#
# space_audit_monitor.sh - v3.2 (read-only)
# Diagnostica una scansione space_audit.sh in corso, consapevole delle fasi:
#   SCAN (find) -> AGGREGAZIONE/lettura dataset (awk maxk=) ->
#   ROLLUP directory (sort esterno + awk rstart=) -> VISTE (sort finali).
# Riconosce anche la modalita' STREAM (scan+aggregazione fusi, nessun dataset).
#
# NON modifica nulla: legge solo /proc e ps. La CPU mostrata e' ISTANTANEA
# (campione delta su /proc/<pid>/stat), non la media di vita di `ps %cpu`.
# Lo strace (l'unica parte intrusiva) e' OPT-IN.
#
# Uso:  ./space_audit_monitor.sh [intervallo_sec]
#   senza argomenti  -> uno snapshot e termina
#   con un numero    -> aggiorna ogni N secondi (Ctrl-C per uscire)
#
# Variabili d'ambiente:
#   MON_STRACE=1     aggiunge un campione `strace -c` 1s sul processo piu' attivo
#                    (richiede ptrace; ATTENZIONE: rallenta brevemente il target).
#   MON_CPU_DT=0.3   ampiezza (secondi) della finestra per la CPU istantanea.
#
set -uo pipefail

SELF=$$
INTERVAL="${1:-0}"
MON_STRACE="${MON_STRACE:-0}"
MON_CPU_DT="${MON_CPU_DT:-0.3}"
DECOMP_COMMS="zcat pigz gzip gunzip"
CLK_TCK="$(getconf CLK_TCK 2>/dev/null || echo 100)"

# ----------------------------------------------------------------------------
# cache processi: un solo scan di /proc per snapshot (perf + coerenza)
# ----------------------------------------------------------------------------
declare -A CMD COMM CPU
PROC_PIDS=()

prime_proc(){
  CMD=(); COMM=(); CPU=(); PROC_PIDS=()
  local p pid c
  for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    [[ "$pid" == "$SELF" ]] && continue
    [[ -r "$p/cmdline" ]] || continue
    c=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
    [[ -z "$c" ]] && continue                 # kernel thread / niente cmdline
    CMD[$pid]="$c"
    COMM[$pid]="$(cat "$p/comm" 2>/dev/null || true)"
    PROC_PIDS+=("$pid")
  done
}

ppid_of(){ awk '/^PPid:/{print $2}' "/proc/$1/status" 2>/dev/null; }

# true se $1 e' (transitivamente) figlio di $MAINPID; sempre true se MAINPID vuoto
MAINPID=""
is_desc(){
  [[ -z "$MAINPID" ]] && return 0
  local p="$1" guard=0
  while [[ -n "$p" && "$p" != 0 && "$p" != 1 && $guard -lt 64 ]]; do
    [[ "$p" == "$MAINPID" ]] && return 0
    p=$(ppid_of "$p"); guard=$((guard+1))
  done
  return 1
}
filter_desc(){ local pid; while read -r pid; do [[ -n "$pid" ]] && is_desc "$pid" && echo "$pid"; done; }

# pid (dalla cache) il cui cmdline contiene la sottostringa $1
match_pids(){
  [[ ${#PROC_PIDS[@]} -eq 0 ]] && return 0
  local pid
  for pid in "${PROC_PIDS[@]}"; do
    [[ "${CMD[$pid]:-}" == *"$1"* ]] && echo "$pid"
  done
}

# CPU istantanea: utime+stime di tutti i pid, attesa MON_CPU_DT, ricampiona.
# /proc/<pid>/stat: si rimuove "<pid> (comm) " (comm puo' contenere spazi/parentesi)
# con espansione greedy fino all'ultimo ") "; poi utime=campo14, stime=campo15.
cpu_sample(){
  local pids=("$@") pid rest j1
  [[ ${#pids[@]} -eq 0 ]] && return 0
  local -A j0
  local -a A
  for pid in "${pids[@]}"; do
    [[ -r "/proc/$pid/stat" ]] || continue
    rest="$(cat "/proc/$pid/stat" 2>/dev/null || true)"; rest=${rest##*) }
    read -ra A <<< "$rest"; [[ ${#A[@]} -ge 13 ]] || continue
    j0[$pid]=$(( ${A[11]:-0} + ${A[12]:-0} ))
  done
  sleep "$MON_CPU_DT" 2>/dev/null || sleep 1
  for pid in "${pids[@]}"; do
    [[ -n "${j0[$pid]:-}" ]] || continue
    [[ -r "/proc/$pid/stat" ]] || continue
    rest="$(cat "/proc/$pid/stat" 2>/dev/null || true)"; rest=${rest##*) }
    read -ra A <<< "$rest"; [[ ${#A[@]} -ge 13 ]] || continue
    j1=$(( ${A[11]:-0} + ${A[12]:-0} ))
    CPU[$pid]="$(awk -v d=$(( j1 - ${j0[$pid]} )) -v hz="$CLK_TCK" -v dt="$MON_CPU_DT" \
                  'BEGIN{printf "%.1f",(dt>0?d/hz/dt*100:0)}')"
  done
}
cpu_of(){ echo "${CPU[$1]:-?}"; }

human(){ # byte -> human
  awk -v b="${1:-0}" 'BEGIN{u="B KB MB GB TB";n=split(u,a," ");s=b;i=1;
    while(s>=1024&&i<n){s/=1024;i++} printf (i==1?"%d %s":"%.1f %s"), s, a[i]}'
}
rss_of(){ awk '/^VmRSS:/{printf "%d", $2*1024}' "/proc/$1/status" 2>/dev/null || echo 0; }
elapsed_of(){ ps -o etime= -p "$1" 2>/dev/null | tr -d ' '; }

# primo fd di $1 che punta a un file che matcha il glob $2 -> "fd<TAB>target"
fd_matching(){
  local pid="$1" glob="$2" fd t base
  [[ -d "/proc/$pid/fd" ]] || return 1
  for fd in "/proc/$pid/fd"/*; do
    [[ -e "$fd" ]] || continue
    t=$(readlink "$fd" 2>/dev/null) || continue
    base=${fd##*/}
    # shellcheck disable=SC2254
    case "$t" in $glob) printf '%s\t%s\n' "$base" "$t"; return 0;; esac
  done
  return 1
}

# ----------------------------------------------------------------------------
# snapshot
# ----------------------------------------------------------------------------
snapshot(){
  prime_proc
  echo "==============================================================="
  echo " SPACE_AUDIT MONITOR v3.2 (read-only)   $(date '+%H:%M:%S')"
  echo "==============================================================="

  # --- processo principale (per nome di default dello script) -------------
  local main_pid="" main_cmd="" pid
  for pid in $(match_pids 'space_audit.sh'); do
    [[ "${CMD[$pid]:-}" == *monitor* ]] && continue
    main_pid="$pid"; main_cmd="${CMD[$pid]:-}"; break
  done

  if [[ -n "$main_pid" ]]; then
    MAINPID="$main_pid"
    echo "Audit PID  : $main_pid   elapsed $(elapsed_of "$main_pid")"
    echo "Comando    : ${main_cmd# }"
  else
    MAINPID=""
    echo "Audit principale (space_audit.sh) non rilevato per nome."
    echo "(Se rinominato: le fasi restano valide, ma senza filtro per discendenza.)"
  fi

  # --- rilevamento processi per fase (firma cmdline + discendenza) --------
  local finds aggs sorts decs rollup_pids draw_sort cm
  finds=$(match_pids '%T@'      | filter_desc)   # worker find (-printf ... %T@ ...)
  aggs=$(match_pids 'maxk='     | filter_desc)   # awk aggregatore per-file (lettura dataset)
  rollup_pids=$(match_pids 'rstart=' | filter_desc)  # awk a stack del rollup esterno
  draw_sort=$(match_pids '.draw'     | filter_desc)  # sort -k2 che ordina T_DRAW (rollup)
  sorts=$(match_pids ' -T '     | filter_desc)   # sort GNU (-T): viste finali e/o sort di rollup
  decs=""
  for pid in $(match_pids '.tsv.gz' | filter_desc); do
    cm="${COMM[$pid]:-}"
    case " $DECOMP_COMMS " in *" $cm "*) decs="$decs $pid";; esac
  done

  # STREAM: find attivo che alimenta direttamente l'awk aggregatore (nessun dataset)
  local stream=0
  [[ -n "$finds" && -n "$aggs" ]] && stream=1
  # ROLLUP esterno: awk a stack (rstart=) e/o il sort che ordina il file 'draw'.
  local rollup=0
  [[ -n "$rollup_pids" || -n "$draw_sort" ]] && rollup=1

  # --- CPU istantanea per tutti i pid coinvolti (un solo campione) --------
  local allpids
  allpids=$(echo "$main_pid $finds $aggs $rollup_pids $draw_sort $decs $sorts" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u)
  # shellcheck disable=SC2086
  cpu_sample $allpids

  # --- fase corrente ------------------------------------------------------
  local phase="(inattivo / render / completato)"
  [[ -n "$sorts" ]] && phase="VISTE / ordinamenti finali"
  [[ -n "$aggs"  ]] && phase="AGGREGAZIONE (lettura dataset)"
  [[ "$rollup" -eq 1 ]] && phase="AGGREGAZIONE (rollup directory, sort esterno)"
  [[ -n "$finds" ]] && phase="SCAN (find)"
  [[ "$stream" -eq 1 ]] && phase="SCAN+AGGREGAZIONE (streaming)"
  echo "---------------------------------------------------------------"
  echo "FASE: $phase"
  echo "---------------------------------------------------------------"

  # --- blocco SCAN --------------------------------------------------------
  if [[ -n "$finds" ]]; then
    local nf=0 part_total=0 data_path="" data_sz=0 t sz
    echo "[SCAN] worker find attivi:"
    for pid in $finds; do
      nf=$((nf+1))
      t=$(readlink "/proc/$pid/fd/1" 2>/dev/null || true)
      if [[ "$t" == *.part.* && -f "$t" ]]; then
        sz=$(stat -c %s "$t" 2>/dev/null || echo 0); part_total=$((part_total+sz))
        printf "   pid %-7s cpu %5s%%  -> %s (%s)\n" "$pid" "$(cpu_of "$pid")" "${t##*/}" "$(human "$sz")"
      else
        printf "   pid %-7s cpu %5s%%  (seriale/streaming, pipe)\n" "$pid" "$(cpu_of "$pid")"
      fi
    done
    [[ "$nf" -gt 1 ]] && echo "   modalita': PARALLELA ($nf find)  temp totali: $(human "$part_total")"
    [[ "$nf" -eq 1 ]] && echo "   modalita': seriale (1 find)"
    if [[ "$stream" -eq 1 ]]; then
      echo "   STREAM: il find alimenta direttamente l'awk (nessun dataset .tsv.gz)"
    else
      for pid in $(match_pids 'gz' | filter_desc); do
        cm="${COMM[$pid]:-}"
        case " $DECOMP_COMMS " in *" $cm "*)
          if r=$(fd_matching "$pid" '*.tsv.gz'); then
            data_path=${r#*$'\t'}; data_sz=$(stat -c %s "$data_path" 2>/dev/null || echo 0)
          fi;;
        esac
      done
      [[ -n "$data_path" ]] && echo "   dataset .tsv.gz finora: $(human "$data_sz")"
    fi
    echo "   nota: la % di avanzamento non e' disponibile in SCAN (totale ignoto)"
    echo
  fi

  # --- blocco AGGREGAZIONE (lettura dataset, passata per-file) ------------
  if [[ -n "$aggs" ]]; then
    local apid r fd gz pos tot done=0
    apid=$(printf '%s\n' $aggs | head -n1)
    echo "[AGGREGAZIONE] awk PID $apid (lettura dataset)  cpu $(cpu_of "$apid")%  rss $(human "$(rss_of "$apid")")"
    if [[ "$stream" -eq 1 ]]; then
      echo "   STREAM: aggregazione in corso sullo stream del find; avanzamento % non disponibile"
    else
      for pid in $decs; do
        if r=$(fd_matching "$pid" '*.tsv.gz'); then
          fd=${r%%$'\t'*}; gz=${r#*$'\t'}
          pos=$(awk '/^pos:/{print $2}' "/proc/$pid/fdinfo/$fd" 2>/dev/null || echo 0)
          tot=$(stat -c %s "$gz" 2>/dev/null || echo 0)
          if [[ "${tot:-0}" -gt 0 ]]; then
            awk -v p="${pos:-0}" -v t="$tot" 'BEGIN{printf "   lettura dataset: %.1f%% (%d/%d byte compressi)\n",(p>t?100:p*100/t),p,t}'
            done=1
          fi
        fi
      done
      [[ "$done" -eq 0 ]] && echo "   avanzamento non disponibile (decompressore non visibile o fdinfo non leggibile)"
    fi
    echo "   nota: contributi per-directory scritti su file 'draw'; il rollup avviene a valle (sort esterno)"
    echo
  fi

  # --- blocco ROLLUP directory (sort esterno) -----------------------------
  if [[ "$rollup" -eq 1 ]]; then
    local rp sp
    echo "[ROLLUP directory] consolidamento gerarchico via sort esterno (RAM costante, nessun cap)"
    for sp in $draw_sort; do
      printf "   sort -k2   pid %-7s cpu %5s%%  rss %s\n" "$sp" "$(cpu_of "$sp")" "$(human "$(rss_of "$sp")")"
    done
    for rp in $rollup_pids; do
      printf "   awk stack  pid %-7s cpu %5s%%  rss %s\n" "$rp" "$(cpu_of "$rp")" "$(human "$(rss_of "$rp")")"
    done
    echo "   avanzamento: lo script stampa 'rollup... N directory' su stderr."
    echo "   non e' un blocco: e' lavoro CPU+disco a RAM costante (non cresce come prima)."
    echo
  fi

  # --- blocco VISTE (solo se NON e' la fase di rollup) --------------------
  if [[ -n "$sorts" && -z "$finds" && -z "$aggs" && "$rollup" -ne 1 ]]; then
    echo "[VISTE] sort attivi (top-N e sottoinsieme >10 anni):"
    for pid in $sorts; do
      printf "   pid %-7s cpu %5s%%  %s\n" "$pid" "$(cpu_of "$pid")" "${COMM[$pid]:-sort}"
    done
    echo
  fi

  # --- RISORSE (CPU istantanea, RSS, elapsed) -----------------------------
  if [[ -n "$allpids" ]]; then
    echo "[RISORSE]  (CPU = istantanea su finestra ${MON_CPU_DT}s)"
    printf "   %-7s %6s   %10s   %8s  %s\n" "PID" "CPU%" "RSS" "ELAPSED" "COMM"
    for pid in $allpids; do
      printf "   %-7s %6s   %10s   %8s  %s\n" \
        "$pid" "$(cpu_of "$pid")" "$(human "$(rss_of "$pid")")" \
        "$(elapsed_of "$pid")" "${COMM[$pid]:-?}"
    done
    echo
  fi

  # --- I/O del processo piu' attivo (stesso utente dell'audit o root) -----
  # priorita': aggregatore (lettura) -> awk rollup -> sort rollup -> find
  local busy=""
  busy=$(printf '%s\n' $aggs | head -n1)
  [[ -z "$busy" ]] && busy=$(printf '%s\n' $rollup_pids | head -n1)
  [[ -z "$busy" ]] && busy=$(printf '%s\n' $draw_sort | head -n1)
  [[ -z "$busy" ]] && busy=$(printf '%s\n' $finds | head -n1)
  if [[ -n "$busy" ]]; then
    echo "[I/O] pid $busy"
    if [[ -r "/proc/$busy/io" ]]; then
      sed 's/^/   /' "/proc/$busy/io"
    else
      echo "   non leggibile (esegui come lo stesso utente dell'audit, o root)"
    fi
    echo
  fi

  # --- STRACE: OPT-IN (intrusivo) -----------------------------------------
  if [[ -n "$busy" ]]; then
    if [[ "$MON_STRACE" = "1" ]]; then
      echo "[STRACE] campione 1s su pid $busy (intrusivo; richiede ptrace)"
      if command -v timeout >/dev/null 2>&1 && command -v strace >/dev/null 2>&1; then
        timeout 1 strace -c -p "$busy" 2>/dev/null | sed 's/^/   /' \
          || echo "   strace non consentito (ptrace_scope/permessi) o processo terminato"
      else
        echo "   strace/timeout non disponibili"
      fi
    else
      echo "[STRACE] disattivato (intrusivo: rallenta il target). Abilita con MON_STRACE=1"
    fi
  fi

  echo "==============================================================="
}

# ----------------------------------------------------------------------------
if [[ "$INTERVAL" =~ ^[0-9]+$ ]] && (( INTERVAL > 0 )); then
  while :; do clear 2>/dev/null || true; snapshot; sleep "$INTERVAL"; done
else
  snapshot
fi
echo "DONE (read-only)"
