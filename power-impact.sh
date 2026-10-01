#!/usr/bin/env bash

set -u

sample_seconds=${POWER_IMPACT_SAMPLE_SECONDS:-1}
clock_ticks=$(getconf CLK_TCK 2>/dev/null || printf '100')

declare -A before_ticks
declare -A process_names
declare -A grouped_ticks

read_process() {
  local process_dir=$1 stat_line rest name
  local -a fields

  [[ -O $process_dir && -r $process_dir/stat && -r $process_dir/comm ]] || return 1
  IFS= read -r stat_line <"$process_dir/stat" || return 1
  IFS= read -r name <"$process_dir/comm" || return 1
  rest=${stat_line#*) }
  read -r -a fields <<<"$rest"
  (( ${#fields[@]} >= 13 )) || return 1

  REPLY=$((fields[11] + fields[12]))
  PROCESS_NAME=$name
}

display_name() {
  local name=$1
  case $name in
    chromium*) printf 'Chromium' ;;
    codex*) printf 'Codex' ;;
    foot) printf 'Terminal' ;;
    mpv) printf 'mpv' ;;
    omarchy-shell|quickshell) printf 'Omarchy Shell' ;;
    Xwayland) printf 'XWayland' ;;
    *)
      name=${name//_/ }
      name=${name//-/ }
      printf '%s' "${name^}"
      ;;
  esac
}

start_ns=$(date +%s%N)
for process_dir in /proc/[0-9]*; do
  if read_process "$process_dir"; then
    pid=${process_dir##*/}
    before_ticks[$pid]=$REPLY
    process_names[$pid]=$PROCESS_NAME
  fi
done

sleep "$sample_seconds"
end_ns=$(date +%s%N)

for process_dir in /proc/[0-9]*; do
  pid=${process_dir##*/}
  [[ -v before_ticks[$pid] ]] || continue
  if read_process "$process_dir"; then
    delta=$((REPLY - before_ticks[$pid]))
    (( delta > 0 )) || continue
    name=${process_names[$pid]}
    case $name in
      bash|sh|sleep|sort|head|awk|power-impact.sh) continue ;;
    esac
    grouped_ticks[$name]=$(( ${grouped_ticks[$name]:-0} + delta ))
  fi
done

elapsed_ns=$((end_ns - start_ns))
for name in "${!grouped_ticks[@]}"; do
  cpu=$(awk -v ticks="${grouped_ticks[$name]}" -v hz="$clock_ticks" -v ns="$elapsed_ns" \
    'BEGIN { printf "%.1f", ticks * 100000000000 / (hz * ns) }')
  impact=$(awk -v cpu="$cpu" 'BEGIN {
    if (cpu >= 50) print "High"
    else if (cpu >= 10) print "Medium"
    else print "Low"
  }')
  printf '%s\t%s\t%s\n' "$(display_name "$name")" "$cpu" "$impact"
done | sort -t $'\t' -k2,2nr | head -n 3
