#!/usr/bin/env bash
# TPM entry point: registers #{vitals*} interpolations in status-left, status-right,
# and every status-format[N] array entry. Follows tmux-cpu's cpu.tmux find-and-replace pattern.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$CURRENT_DIR/scripts/helpers.sh"

vitals_interpolation=(
  "\#{vitals}"
  "\#{vitals_system}"
  "\#{vitals_llm}"
  "\#{vitals_cpu}"
  "\#{vitals_mem}"
  "\#{vitals_net}"
  "\#{vitals_claude}"
  "\#{vitals_codex}"
)
vitals_commands=(
  "#($CURRENT_DIR/scripts/vitals.sh all)"
  "#($CURRENT_DIR/scripts/vitals.sh system)"
  "#($CURRENT_DIR/scripts/vitals.sh llm)"
  "#($CURRENT_DIR/scripts/vitals.sh cpu)"
  "#($CURRENT_DIR/scripts/vitals.sh mem)"
  "#($CURRENT_DIR/scripts/vitals.sh net)"
  "#($CURRENT_DIR/scripts/vitals.sh claude)"
  "#($CURRENT_DIR/scripts/vitals.sh codex)"
)

set_tmux_option() {
  local option="$1"
  local value="$2"
  tmux set-option -gq "$option" "$value"
}

do_interpolation() {
  local all_interpolated="$1"
  for ((i = 0; i < ${#vitals_commands[@]}; i++)); do
    all_interpolated=${all_interpolated//${vitals_interpolation[$i]}/${vitals_commands[$i]}}
  done
  echo "$all_interpolated"
}

update_tmux_option() {
  local option
  local option_value
  local new_option_value
  option="$1"
  option_value="$(get_tmux_option "$option" "")"
  new_option_value="$(do_interpolation "$option_value")"
  set_tmux_option "$option" "$new_option_value"
}

# status-format is a numbered array option; iterate every index tmux currently has set.
update_status_format() {
  local index option_value new_option_value
  index=0
  while option_value="$(tmux show-option -gqv "status-format[$index]" 2>/dev/null)" && [ -n "$option_value" ]; do
    new_option_value="$(do_interpolation "$option_value")"
    tmux set-option -gq "status-format[$index]" "$new_option_value"
    index=$((index + 1))
  done
}

main() {
  update_tmux_option "status-right"
  update_tmux_option "status-left"
  update_status_format
}
main
