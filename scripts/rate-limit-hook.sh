#!/usr/bin/env bash
# Usage: rate-limit-hook.sh <provider>   (provider: claude | codex, default claude)
#
# Piped in front of a provider's own status/statusLine command. Reads the provider's raw
# rate-limit JSON on stdin, writes the common-shape cache tmux-vitals' segments read, then
# echoes stdin unchanged so it can be piped onward. Must never break the pipe it sits in:
# always reads all of stdin, always echoes it back byte-exact, always exits 0 — regardless
# of invalid JSON, an unknown provider, or a missing jq.
input="$(cat)"

provider="${1:-claude}"

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./helpers.sh
source "$CURRENT_DIR/helpers.sh"

cache="" filter=""

# to add a provider: one case + one option
case "$provider" in
  claude)
    cache="$(get_tmux_option "@vitals_claude_cache" "$HOME/.claude/cache/rate-limits.json")"
    filter='{five_hour: (.rate_limits.five_hour // null), seven_day: (.rate_limits.seven_day // null)}'
    ;;
  codex)
    cache="$(get_tmux_option "@vitals_codex_cache" "$(vitals_tmp_dir)/codex.json")"
    # standard plans: primary is the 5h window, secondary the 7d window.
    # prolite plans (secondary absent/null): primary is the 7d window, no 5h.
    filter='
      .result.rateLimits as $r |
      if ($r.secondary // null) != null then
        {
          five_hour: {used_percentage: $r.primary.usedPercent, resets_at: $r.primary.resetsAt},
          seven_day: {used_percentage: $r.secondary.usedPercent, resets_at: $r.secondary.resetsAt}
        }
      else
        {
          five_hour: null,
          seven_day: (if $r.primary then {used_percentage: $r.primary.usedPercent, resets_at: $r.primary.resetsAt} else null end)
        }
      end
    '
    ;;
  *)
    echo "rate-limit-hook.sh: unknown provider '$provider'" >&2
    cache=""
    ;;
esac

if [[ -n "$cache" ]] && command_exists jq; then
  if printf '%s' "$input" | jq -e . >/dev/null 2>&1; then
    mapped="$(printf '%s' "$input" | jq -c --argjson ts "$(date +%s)" --arg provider "$provider" \
      "$filter | {ts: \$ts, provider: \$provider, five_hour: .five_hour, seven_day: .seven_day}" 2>/dev/null)"
    # Never clobber a good cache with an empty one: both windows null means nothing to write.
    if [[ -n "$mapped" ]] && printf '%s' "$mapped" | jq -e '(.five_hour != null) or (.seven_day != null)' >/dev/null 2>&1; then
      mkdir -p "$(dirname "$cache")" 2>/dev/null
      printf '%s' "$mapped" >"$cache.tmp" 2>/dev/null && mv "$cache.tmp" "$cache"
    fi
  else
    echo "rate-limit-hook.sh: invalid JSON on stdin" >&2
  fi
fi

printf '%s' "$input"
