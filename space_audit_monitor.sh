#!/usr/bin/env bash
#
# space_audit_monitor.sh - v3.0 (read-only)
# Diagnostica una scansione space_audit.sh in corso, consapevole delle fasi:
#   SCAN (find, anche parallelo) -> AGGREGAZIONE (awk maxk=) -> VISTE (sort).
# NON modifica nulla: legge solo /proc, ps e, se permesso, un campione strace 1s.
#
# Uso:  ./space_audit_monitor.sh [intervallo_sec]
#   senza argomenti  -> uno snapshot e termina
#   con un numero    -> aggiorna ogni N secondi (Ctrl-C per uscire)
#
set -uo pipefail

SELF=$$
INTERVAL="${1:-0}"
DECOMP_COMMS="zcat pigz gzip gunzip"

# ----------------------------------------------------------------------------
# helper read-only su /proc
# ----------------------------------------------------------------------------
cmd_of(){ tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null; }
comm_of(){ cat "/proc/$1/comm" 2>/dev/null; }
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
# filtra una lista di pid (stdin) tenendo solo i discendenti dell'audit
filter_desc(){ local pid; while read -r pid; do is_desc "$pid" && echo "$pid"; done; }

# pids il cui cmdline contiene il pattern $1 (esclude se stesso)
pids_matching(){
  local p pid c
  for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    [[ "$pid" == "$SELF" ]] && continue
    [[ -r "$p/cmdline" ]] || continue
    c=$(cmd_of "$pid") || continue
    [[ -n "$c" && "$c" == *"$1"* ]] && echo "$pid"
  done
}

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

human(){ # byte -> human
  awk -v b="${1:-0}" 'BEGIN{u="B KB MB GB TB";n=split(u,a," ");s=b;i=1;
    while(s>=1024&&i<n){s/=1024;i++} printf (i==1?"%d %s":"%.1f %s"), s, a[i]}'
}

elapsed_of(){ ps -o etime= -p "$1" 2>/dev/null | tr -d ' '; }

# ----------------------------------------------------------------------------
# snapshot
# ----------------------------------------------------------------------------
snapshot(){
  echo "==============================================================="
  echo " SPACE_AUDIT MONITOR v3.0 (read-only)   $(date '+%H:%M:%S')"
  echo "==============================================================="

  # --- processo principale (best-effort: dipende dal nome script di default)
  local main_pids main_pid="" main_cmd=""
  main_pids=$(pids_matching 'space_audit.sh')
  for pid in $main_pids; do
    local c; c=$(cmd_of "$pid")
    [[ "$c" == *monitor* ]] && continue        # esclude questo monitor
    main_pid="$pid"; main_cmd="$c"; break
  done

  if [[ -n "$main_pid" ]]; then
    MAINPID="$main_pid"
    echo "Audit PID  : $main_pid   elapsed $(elapsed_of "$main_pid")"
    echo "Comando    : ${main_cmd# }"
  else
    MAINPID=""
    echo "Audit principale (space_audit.sh) non rilevato per nome."
    echo "(Se lo script e' stato rinominato, le fasi sotto restano valide.)"
  fi

  # --- rilevamento processi per fase (firma cmdline + discendenza dall'audit) ---
  local finds aggs decs sorts
  finds=$(pids_matching '%T@' | filter_desc)     # worker find (-printf ... %T@ ...)
  aggs=$(pids_matching 'maxk=' | filter_desc)    # awk aggregatore (single-pass)
  sorts=$(pids_matching ' -T ' | filter_desc)    # sort dello strumento (-T WORK_TMP)

  # decompressori che leggono il dataset (.tsv.gz): solo comm di (de)compressione
  decs=""
  local pid c cm
  for pid in $(pids_matching '.tsv.gz' | filter_desc); do
    cm=$(comm_of "$pid")
    case " $DECOMP_COMMS " in *" $cm "*) decs="$decs $pid";; esac
  done

  # --- fase corrente -------------------------------------------------------
  local phase="(inattivo / render / completato)"
  [[ -n "$sorts" ]] && phase="VISTE / ordinamenti finali"
  [[ -n "$aggs"  ]] && phase="AGGREGAZIONE (single-pass)"
  [[ -n "$finds" ]] && phase="SCAN (find)"
  echo "---------------------------------------------------------------"
  echo "FASE: $phase"
  echo "---------------------------------------------------------------"

  # --- blocco SCAN ---------------------------------------------------------
  if [[ -n "$finds" ]]; then
    local nf=0 part_total=0 data_path="" data_sz=0 fd t base sz
    echo "[SCAN] worker find attivi:"
    for pid in $finds; do
      nf=$((nf+1))
      # fd1 del find: file .part.* (parallelo) o pipe (seriale)
      t=$(readlink "/proc/$pid/fd/1" 2>/dev/null || true)
      if [[ "$t" == *.part.* && -f "$t" ]]; then
        sz=$(stat -c %s "$t" 2>/dev/null || echo 0); part_total=$((part_total+sz))
        printf "   pid %-7s cpu %4s%%  -> %s (%s)\n" "$pid" \
          "$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ')" "${t##*/}" "$(human "$sz")"
      else
        printf "   pid %-7s cpu %4s%%  (seriale, pipe)\n" "$pid" \
          "$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ')"
      fi
    done
    [[ "$nf" -gt 1 ]] && echo "   modalita': PARALLELA ($nf find)  temp totali: $(human "$part_total")"
    [[ "$nf" -eq 1 ]] && echo "   modalita': seriale (1 find)"
    # dataset finora (dal compressore che scrive il .tsv.gz)
    for pid in $(pids_matching 'gz' | filter_desc); do
      cm=$(comm_of "$pid")
      case " $DECOMP_COMMS " in *" $cm "*)
        if r=$(fd_matching "$pid" '*.tsv.gz'); then
          data_path=${r#*$'\t'}; data_sz=$(stat -c %s "$data_path" 2>/dev/null || echo 0)
        fi;;
      esac
    done
    [[ -n "$data_path" ]] && echo "   dataset .tsv.gz finora: $(human "$data_sz")"
    echo "   nota: la % non e' disponibile in SCAN (totale ignoto finche' find non finisce)"
    echo
  fi

  # --- blocco AGGREGAZIONE -------------------------------------------------
  if [[ -n "$aggs" ]]; then
    local apid r fd gz pos tot
    apid=$(echo "$aggs" | awk '{print $1}')
    echo "[AGGREGAZIONE] awk PID $apid"
    ps -o pid,%cpu,%mem,rss,etime -p "$apid" 2>/dev/null | sed 's/^/   /' || true
    # avanzamento = posizione di lettura del dataset da parte del decompressore
    local done=0
    for pid in $decs; do
      if r=$(fd_matching "$pid" '*.tsv.gz'); then
        fd=${r%%$'\t'*}; gz=${r#*$'\t'}
        pos=$(awk '/^pos:/{print $2}' "/proc/$pid/fdinfo/$fd" 2>/dev/null || echo 0)
        tot=$(stat -c %s "$gz" 2>/dev/null || echo 0)
        if [[ "${tot:-0}" -gt 0 ]]; then
          awk -v p="${pos:-0}" -v t="$tot" 'BEGIN{printf "   avanzamento: %.1f%% (%d/%d byte compressi del dataset)\n", (p>t?100:p*100/t), p, t}'
          done=1
        fi
      fi
    done
    [[ "$done" -eq 0 ]] && echo "   avanzamento non disponibile (decompressore non visibile o fdinfo non leggibile)"
    echo "   nota: l'aggregatore tiene top-N in memoria; non c'e' piu' un sort globale sul dataset"
    echo
  fi

  # --- blocco VISTE --------------------------------------------------------
  if [[ -n "$sorts" && -z "$finds" && -z "$aggs" ]]; then
    echo "[VISTE] sort attivi (top-N e sottoinsieme >10 anni):"
    for pid in $sorts; do
      printf "   pid %-7s cpu %4s%%  %s\n" "$pid" \
        "$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ')" "$(comm_of "$pid")"
    done
    echo
  fi

  # --- RISORSE (tutti i PID coinvolti) ------------------------------------
  local all
  all=$(echo "$main_pid $finds $aggs $decs $sorts" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u | tr '\n' ',' | sed 's/,$//')
  if [[ -n "$all" ]]; then
    echo "[RISORSE]"
    ps -o pid,ppid,%cpu,%mem,rss,etime,comm -p "$all" 2>/dev/null | sed 's/^/   /' || true
    echo
  fi

  # --- I/O + STRACE (richiedono stesso utente dell'audit o root) ----------
  local busy=""
  busy=$(echo "$aggs" | awk '{print $1}')
  [[ -z "$busy" ]] && busy=$(echo "$finds" | awk '{print $1}')
  if [[ -n "$busy" ]]; then
    echo "[I/O] pid $busy"
    if [[ -r "/proc/$busy/io" ]]; then
      sed 's/^/   /' "/proc/$busy/io"
    else
      echo "   non leggibile (esegui come lo stesso utente dell'audit, o root)"
    fi
    echo
    echo "[STRACE] campione 1s su pid $busy (richiede ptrace permesso)"
    if command -v timeout >/dev/null 2>&1 && command -v strace >/dev/null 2>&1; then
      timeout 1 strace -c -p "$busy" 2>/dev/null | sed 's/^/   /' \
        || echo "   strace non consentito (ptrace_scope/permessi) o processo terminato"
    else
      echo "   strace/timeout non disponibili"
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
