#!/usr/bin/env bash
# Shared helpers: tmux option lookup with defaults, OS detection, tmp dir.
# Mirrors tmux-cpu's helpers.sh get_tmux_option pattern.

export LANG=C
export LC_ALL=C

# get_tmux_option <option> <default> — session value, then global, then default.
# Falls back to <default> if tmux is unreachable (no server, option unset).
get_tmux_option() {
  local option="$1"
  local default_value="$2"
  local option_value
  option_value="$(tmux show-option -qv "$option" 2>/dev/null)"
  if [ -z "$option_value" ]; then
    option_value="$(tmux show-option -gqv "$option" 2>/dev/null)"
  fi
  if [ -z "$option_value" ]; then
    echo "$default_value"
  else
    echo "$option_value"
  fi
}

is_osx() {
  [ "$(uname)" = "Darwin" ]
}

is_linux() {
  [ "$(uname)" = "Linux" ]
}

command_exists() {
  command -v "$1" &>/dev/null
}

# Private per-user scratch dir for history/lock files (net rate, cpu history, codex cache).
vitals_tmp_dir() {
  local dir="${TMPDIR:-/tmp}/tmux-vitals-$USER"
  mkdir -p "$dir" 2>/dev/null
  echo "$dir"
}

# tmux_cpu_script <cpu_percentage.sh|ram_percentage.sh> — prints the absolute path
# to that script inside the tmux-cpu plugin, or nothing if tmux-cpu isn't installed.
# cpu/mem are delegated to tmux-cpu rather than probed natively (required dependency).
tmux_cpu_script() {
  local script="${TMUX_PLUGIN_MANAGER_PATH:-$HOME/.tmux/plugins}/tmux-cpu/scripts/$1"
  [[ -x "$script" ]] && echo "$script"
}

# level_color <percent> <warn> <crit> <color_ok> <color_warn> <color_crit>
# Prints the hex color for the given percent against the warn/crit thresholds.
level_color() {
  local percent="${1%.*}" warn="$2" crit="$3" ok_color="$4" warn_color="$5" crit_color="$6"
  percent="${percent:-0}"
  if ((percent >= crit)); then
    echo "$crit_color"
  elif ((percent >= warn)); then
    echo "$warn_color"
  else
    echo "$ok_color"
  fi
}
