#!/usr/bin/env bash
# Dispatcher: vitals.sh <segment> [<segment> ...]
# Segments: cpu mem net claude codex system(=cpu mem net) llm(=claude codex) all(=system llm)
# Multiple segments are joined by @vitals_separator. Never errors to stderr in normal operation.
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/helpers.sh"

SEPARATOR="$(get_tmux_option "@vitals_separator" "  ")"
WARN="$(get_tmux_option "@vitals_warn" "60")"
CRIT="$(get_tmux_option "@vitals_crit" "85")"
COLOR_OK="$(get_tmux_option "@vitals_color_ok" "#89CA78")"
COLOR_WARN="$(get_tmux_option "@vitals_color_warn" "#e5c07b")"
COLOR_CRIT="$(get_tmux_option "@vitals_color_crit" "#EF596F")"
COLOR_FG="$(get_tmux_option "@vitals_color_fg" "#9da5b4")"
COLOR_DIM="$(get_tmux_option "@vitals_color_dim" "#5C6370")"
COLOR_CLAUDE="$(get_tmux_option "@vitals_color_claude" "#D97757")"
COLOR_CODEX="$(get_tmux_option "@vitals_color_codex" "#4FA0F0")"

ICON_CPU="$(get_tmux_option "@vitals_icon_cpu" "󰘚")"
ICON_MEM="$(get_tmux_option "@vitals_icon_mem" "󰍛")"
ICON_DOWN="$(get_tmux_option "@vitals_icon_down" "󰇚")"
ICON_UP="$(get_tmux_option "@vitals_icon_up" "󰕒")"
ICON_CLAUDE="$(get_tmux_option "@vitals_icon_claude" "✳")"
ICON_CODEX="$(get_tmux_option "@vitals_icon_codex" "")"
ICON_RESET="$(get_tmux_option "@vitals_icon_reset" "󰑐")"

SPARK_LEN="$(get_tmux_option "@vitals_spark_len" "10")"
BAR_WIDTH="$(get_tmux_option "@vitals_bar_width" "10")"
NET_FLOOR="$(get_tmux_option "@vitals_net_floor" "51200")"
# shellcheck disable=SC2207 # word-splitting is intentional: one glyph per array slot
SPARK_CHARS=($(get_tmux_option "@vitals_spark_chars" "⣀ ⣀ ⣄ ⣤ ⣦ ⣶ ⣷ ⣿"))

LLM_SEPARATOR="$(get_tmux_option "@vitals_llm_separator" " | ")"
CLAUDE_CACHE="$(get_tmux_option "@vitals_claude_cache" "$HOME/.claude/cache/rate-limits.json")"
STALE="$(get_tmux_option "@vitals_stale" "600")"
CODEX_MODE="$(get_tmux_option "@vitals_codex" "auto")"
CODEX_TTL="$(get_tmux_option "@vitals_codex_ttl" "300")"

TMP_DIR="$(vitals_tmp_dir)"
CODEX_CACHE="$(get_tmux_option "@vitals_codex_cache" "$TMP_DIR/codex.json")"

# --- rendering helpers ---

fg() { printf "#[fg=%s]" "$1"; }

# spark <history-file> <value> <max> -> appends value, prints an N-char sparkline
spark() {
  local file="$1" value="$2" max="$3" out="" line idx
  echo "$value" >>"$file"
  tail -n "$SPARK_LEN" "$file" >"$file.tmp" 2>/dev/null && mv "$file.tmp" "$file"
  while read -r line; do
    ((max < 1)) && max=1
    idx=$((line * 7 / max))
    ((idx > 7)) && idx=7
    ((idx < 0)) && idx=0
    out+="${SPARK_CHARS[$idx]}"
  done <"$file"
  while ((${#out} < SPARK_LEN)); do out="${SPARK_CHARS[0]}$out"; done
  printf "%s" "$out"
}

# bar <percent> <width> -> filled/empty block bar
bar() {
  local percent="${1%.*}" width="$2" out="" filled i
  percent="${percent:-0}"
  filled=$((percent * width / 100))
  for ((i = 0; i < width; i++)); do
    if ((i < filled)); then out+="━"; else out+="╌"; fi
  done
  printf "%s" "$out"
}

# fmt_rate <bytes/s> -> fixed-width "123 kB/s" style string
fmt_rate() {
  local bytes="$1"
  if ((bytes >= 1048576)); then
    awk -v b="$bytes" 'BEGIN{printf "%5.1f MB/s", b/1048576}'
  elif ((bytes >= 1024)); then
    awk -v b="$bytes" 'BEGIN{printf "%5.0f kB/s", b/1024}'
  else
    printf "%5d  B/s" "$bytes"
  fi
}

# until_epoch <epoch> -> "4d 3h" | "4h26"
until_epoch() {
  local target="$1" now secs
  now=$(date +%s)
  secs=$((target - now))
  ((secs < 0)) && secs=0
  if ((secs >= 86400)); then
    printf "%dd %dh" $((secs / 86400)) $((secs % 86400 / 3600))
  else
    printf "%dh%02d" $((secs / 3600)) $((secs % 3600 / 60))
  fi
}

# --- segments ---

segment_cpu() {
  local cpu script
  script="$(tmux_cpu_script "cpu_percentage.sh")"
  if [[ -z "$script" ]]; then
    printf "%s%s tmux-cpu?" "$(fg "$COLOR_DIM")" "$ICON_CPU"
    return
  fi
  cpu="$("$script" 2>/dev/null | tr -dc '0-9')"
  cpu="${cpu:-0}"
  local color
  color="$(level_color "$cpu" "$WARN" "$CRIT" "$COLOR_OK" "$COLOR_WARN" "$COLOR_CRIT")"
  printf "%s%s %s %3d%%" "$(fg "$color")" "$ICON_CPU" "$(spark "$TMP_DIR/cpu.hist" "$cpu" 100)" "$cpu"
}

segment_mem() {
  local mem script
  script="$(tmux_cpu_script "ram_percentage.sh")"
  if [[ -z "$script" ]]; then
    printf "%s%s tmux-cpu?" "$(fg "$COLOR_DIM")" "$ICON_MEM"
    return
  fi
  mem="$("$script" 2>/dev/null | tr -dc '0-9')"
  mem="${mem:-0}"
  local color
  color="$(level_color "$mem" "$WARN" "$CRIT" "$COLOR_OK" "$COLOR_WARN" "$COLOR_CRIT")"
  printf "%s%s %s %3d%%" "$(fg "$color")" "$ICON_MEM" "$(bar "$mem" "$BAR_WIDTH")" "$mem"
}

segment_net() {
  local now rx tx net_file down up dmax umax
  now="$(date +%s)"
  net_file="$TMP_DIR/net"
  if is_osx; then
    read -r rx tx < <(netstat -ib 2>/dev/null | awk '$1!="lo0" && $1!="Name" && !seen[$1]++ {rx+=$7; tx+=$10} END{print rx, tx}')
  elif is_linux; then
    read -r rx tx < <(awk -F'[: ]+' '$1!="lo" && $1!="Inter-|" && $1!="face" && NF>10 {rx+=$3; tx+=$11} END{print rx, tx}' /proc/net/dev 2>/dev/null)
  fi
  rx="${rx:-0}"
  tx="${tx:-0}"
  local prev_now prev_rx prev_tx dt
  if [[ -f "$net_file" ]]; then
    read -r prev_now prev_rx prev_tx <"$net_file"
  else
    prev_now="$now" prev_rx="$rx" prev_tx="$tx"
  fi
  echo "$now $rx $tx" >"$net_file"
  dt=$((now - prev_now))
  ((dt < 1)) && dt=1
  down=$(((rx - prev_rx) / dt))
  up=$(((tx - prev_tx) / dt))
  ((down < 0)) && down=0
  ((up < 0)) && up=0

  echo "$down" >>"$TMP_DIR/down.raw"
  echo "$up" >>"$TMP_DIR/up.raw"
  tail -n "$SPARK_LEN" "$TMP_DIR/down.raw" >"$TMP_DIR/down.raw.tmp" 2>/dev/null && mv "$TMP_DIR/down.raw.tmp" "$TMP_DIR/down.raw"
  tail -n "$SPARK_LEN" "$TMP_DIR/up.raw" >"$TMP_DIR/up.raw.tmp" 2>/dev/null && mv "$TMP_DIR/up.raw.tmp" "$TMP_DIR/up.raw"
  dmax="$(sort -n "$TMP_DIR/down.raw" 2>/dev/null | tail -1)"
  umax="$(sort -n "$TMP_DIR/up.raw" 2>/dev/null | tail -1)"
  dmax="${dmax:-0}"
  umax="${umax:-0}"
  ((dmax < NET_FLOOR)) && dmax="$NET_FLOOR"
  ((umax < NET_FLOOR)) && umax="$NET_FLOOR"

  printf "%s%s %s %s  %s%s %s %s" \
    "$(fg "$COLOR_FG")" "$ICON_DOWN" "$(spark "$TMP_DIR/down.spark" "$down" "$dmax")" "$(fmt_rate "$down")" \
    "$(fg "$COLOR_FG")" "$ICON_UP" "$(spark "$TMP_DIR/up.spark" "$up" "$umax")" "$(fmt_rate "$up")"
}

# Optional fields come out of jq as "-", never "": bash `read` collapses consecutive
# tabs, so an empty middle column would shift every column after it.
#
# render_provider <label> <icon> <color> <cache_path> <placeholder>
# Renders the common cache shape ({ts, provider, five_hour, seven_day}) written by
# rate-limit-hook.sh — only the non-null window(s) are shown, joined by " · " when both exist.
render_provider() {
  local label="$1" icon="$2" color="$3" cache="$4" placeholder="$5"
  if [[ -s "$cache" ]] && command_exists jq; then
    local ts p5 r5 p7 r7 now stale color5 color7
    read -r ts p5 r5 p7 r7 < <(jq -r '[(.ts//0), (.five_hour.used_percentage//"-"), (.five_hour.resets_at//"-"), (.seven_day.used_percentage//"-"), (.seven_day.resets_at//"-")] | @tsv' "$cache" 2>/dev/null)
    now="$(date +%s)"
    ts="${ts:-0}"
    stale=""
    (((now - ts) > STALE)) && stale=1
    if [[ -n "$stale" ]]; then
      color5="$COLOR_DIM"; color7="$COLOR_DIM"
    else
      local p5_int p7_int
      p5_int="${p5%.*}"; [[ -z "$p5_int" || "$p5_int" == "-" ]] && p5_int=0
      p7_int="${p7%.*}"; [[ -z "$p7_int" || "$p7_int" == "-" ]] && p7_int=0
      color5="$(level_color "$p5_int" "$WARN" "$CRIT" "$COLOR_OK" "$COLOR_WARN" "$COLOR_CRIT")"
      color7="$(level_color "$p7_int" "$WARN" "$CRIT" "$COLOR_OK" "$COLOR_WARN" "$COLOR_CRIT")"
    fi
    printf "%s%s %s" "$(fg "$color")" "$icon" "$label"
    local printed=""
    if [[ -n "$p5" && "$p5" != "-" ]]; then
      printf " %s5h %s%d%%" "$(fg "$COLOR_FG")" "$(fg "$color5")" "${p5%.*}"
      [[ -n "$r5" && "$r5" != "null" && "$r5" != "-" ]] && printf " %s%s %s" "$(fg "$COLOR_FG")" "$ICON_RESET" "$(until_epoch "${r5%.*}")"
      printed=1
    fi
    if [[ -n "$p7" && "$p7" != "-" ]]; then
      if [[ -n "$printed" ]]; then
        printf " %s· %s7d %s%d%%" "$(fg "$COLOR_FG")" "$(fg "$COLOR_FG")" "$(fg "$color7")" "${p7%.*}"
      else
        printf " %s7d %s%d%%" "$(fg "$COLOR_FG")" "$(fg "$color7")" "${p7%.*}"
      fi
      [[ -n "$r7" && "$r7" != "null" && "$r7" != "-" ]] && printf " %s%s %s" "$(fg "$COLOR_FG")" "$ICON_RESET" "$(until_epoch "${r7%.*}")"
    fi
  else
    printf "%s%s %s %s%s" "$(fg "$color")" "$icon" "$label" "$(fg "$COLOR_DIM")" "$placeholder"
  fi
}

segment_claude() {
  render_provider "Claude" "$ICON_CLAUDE" "$COLOR_CLAUDE" "$CLAUDE_CACHE" "—"
}

codex_enabled() {
  case "$CODEX_MODE" in
    on) return 0 ;;
    off) return 1 ;;
    *) command_exists codex ;;
  esac
}

# Kick off a background codex app-server refresh under a lock, gated by TTL.
# Never called synchronously from the status line — only ever primes the cache.
codex_refresh() {
  local lock="$TMP_DIR/codex.lock" now age
  now="$(date +%s)"
  age=$((now - $(stat -f %m "$CODEX_CACHE" 2>/dev/null || stat -c %Y "$CODEX_CACHE" 2>/dev/null || echo 0)))
  if ((age > CODEX_TTL)) && [[ ! -e "$lock" ]]; then
    touch "$lock" 2>/dev/null
    (
      {
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"tmux-vitals","title":"tmux","version":"0.1"},"capabilities":{}}}' \
          '{"jsonrpc":"2.0","method":"initialized"}' \
          '{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}'
        sleep 8
      } | codex app-server --listen stdio:// 2>/dev/null | grep -m1 '"id":2' | "$CURRENT_DIR/rate-limit-hook.sh" codex >/dev/null
      rm -f "$lock"
    ) >/dev/null 2>&1 &
    disown 2>/dev/null
  fi
  # stale lock guard (crashed refresh)
  if [[ -e "$lock" ]]; then
    local lock_age
    lock_age=$((now - $(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo 0)))
    ((lock_age > 60)) && rm -f "$lock"
  fi
}

segment_codex() {
  if ! codex_enabled; then
    return
  fi
  codex_refresh
  render_provider "Codex" "$ICON_CODEX" "$COLOR_CODEX" "$CODEX_CACHE" "…"
}

# --- expansion of grouped segment names ---

expand_segment() {
  case "$1" in
    system) echo "cpu mem net" ;;
    llm) echo "claude codex" ;;
    all) echo "cpu mem net claude codex" ;;
    *) echo "$1" ;;
  esac
}

render_segment() {
  case "$1" in
    cpu) segment_cpu ;;
    mem) segment_mem ;;
    net) segment_net ;;
    claude) segment_claude ;;
    codex) segment_codex ;;
    *) : ;; # unknown segment: render nothing rather than error
  esac
}

main() {
  local requested=("$@")
  [[ ${#requested[@]} -eq 0 ]] && requested=("all")

  local segments=()
  local name
  for name in "${requested[@]}"; do
    # shellcheck disable=SC2206 # word-splitting is intentional: expand_segment returns space-separated names
    segments+=($(expand_segment "$name"))
  done

  local out="" piece first=1 prev_name=""
  for name in "${segments[@]}"; do
    piece="$(render_segment "$name")"
    [[ -z "$piece" ]] && continue
    if ((first)); then
      out="$piece"
      first=0
    else
      # claude/codex are one llm group: joined with @vitals_llm_separator, not @vitals_separator
      if [[ "$prev_name" == "claude" && "$name" == "codex" ]]; then
        out+="$(fg "$COLOR_DIM")${LLM_SEPARATOR}${piece}"
      else
        out+="$(fg "$COLOR_DIM")${SEPARATOR}${piece}"
      fi
    fi
    prev_name="$name"
  done
  printf "%s" "$out"
}

main "$@"
