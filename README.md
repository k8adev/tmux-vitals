# tmux-vitals

![screenshot](screenshot.png)
<!-- replace with a real screenshot of the status bar segments -->

System vitals (CPU, memory, network) and LLM usage limits (Claude Code, OpenAI Codex) as tmux
format interpolations, in the style of [tmux-cpu](https://github.com/tmux-plugins/tmux-cpu).
CPU and memory are delegated to [tmux-cpu](https://github.com/tmux-plugins/tmux-cpu) itself
(see Requirements); network and the LLM segments are native.

## Install

Requires [tmux-cpu](https://github.com/tmux-plugins/tmux-cpu) — TPM does not resolve plugin
dependencies, so declare both plugins yourself:

```tmux
set -g @plugin 'tmux-plugins/tmux-cpu'
set -g @plugin 'k8adev/tmux-vitals'
```

Press `prefix + I` to fetch and load them.

## Usage

```tmux
set -g status-right '#{vitals} | %H:%M '
```

Or pick individual segments:

```tmux
set -g status-right '#{vitals_cpu}  #{vitals_mem}  #{vitals_claude} #{vitals_codex}'
```

## Interpolations

| Token | Renders |
|---|---|
| `#{vitals}` | Every segment (system + llm) |
| `#{vitals_system}` | `cpu mem net` |
| `#{vitals_llm}` | `claude codex` |
| `#{vitals_cpu}` | CPU sparkline + percentage |
| `#{vitals_mem}` | Memory bar + percentage |
| `#{vitals_net}` | Download/upload sparklines + rate |
| `#{vitals_claude}` | Claude Code 5h/7d usage limits |
| `#{vitals_codex}` | OpenAI Codex usage limits |

Registered in `status-left`, `status-right`, and every `status-format[N]` entry.

## Options

All options are read via `tmux show -gqv` and fall back to the defaults below if unset.

| Option | Default | Meaning |
|---|---|---|
| `@vitals_warn` | `60` | Percent at which a segment turns warn-colored |
| `@vitals_crit` | `85` | Percent at which a segment turns crit-colored |
| `@vitals_spark_len` | `10` | Sparkline history length (samples) |
| `@vitals_bar_width` | `10` | Memory bar width (characters) |
| `@vitals_net_floor` | `51200` | Minimum adaptive max for net sparklines (bytes/s) |
| `@vitals_spark_chars` | `⣀ ⣀ ⣄ ⣤ ⣦ ⣶ ⣷ ⣿` | Sparkline glyphs, low to high |
| `@vitals_color_ok` | `#89CA78` | Color below warn threshold |
| `@vitals_color_warn` | `#e5c07b` | Color at/above warn threshold |
| `@vitals_color_crit` | `#EF596F` | Color at/above crit threshold |
| `@vitals_color_fg` | `#9da5b4` | Neutral foreground (net, labels) |
| `@vitals_color_dim` | `#5C6370` | Dim/stale color, separators |
| `@vitals_color_claude` | `#D97757` | Claude brand color |
| `@vitals_color_codex` | `#4FA0F0` | Codex brand color |
| `@vitals_icon_cpu` | `󰘚` | CPU icon |
| `@vitals_icon_mem` | `󰍛` | Memory icon |
| `@vitals_icon_down` | `󰇚` | Download icon |
| `@vitals_icon_up` | `󰕒` | Upload icon |
| `@vitals_icon_claude` | `✳` | Claude icon |
| `@vitals_icon_codex` | `` | Codex icon |
| `@vitals_icon_reset` | `󰑐` | Reset-countdown icon |
| `@vitals_separator` | `"  "` | Separator between segments |
| `@vitals_llm_separator` | `" \| "` | Separator between Claude and Codex within `#{vitals_llm}` |
| `@vitals_claude_cache` | `$HOME/.claude/cache/rate-limits.json` | Claude usage cache path |
| `@vitals_codex_cache` | `$TMPDIR/tmux-vitals-$USER/codex.json` | Codex usage cache path |
| `@vitals_stale` | `600` | Seconds before a Claude/Codex segment dims (no live session) |
| `@vitals_codex` | `auto` | `auto` \| `on` \| `off` — `auto` shows Codex only if the `codex` CLI is in PATH |
| `@vitals_codex_ttl` | `300` | Seconds between background Codex refreshes |

## Requirements

- tmux >= 3.0
- bash
- [tmux-cpu](https://github.com/tmux-plugins/tmux-cpu), **required** — the `#{vitals_cpu}` and
  `#{vitals_mem}` segments call its `cpu_percentage.sh` / `ram_percentage.sh` scripts directly.
  Without it installed at `${TMUX_PLUGIN_MANAGER_PATH:-$HOME/.tmux/plugins}/tmux-cpu`, those two
  segments render a dim `tmux-cpu?` hint instead of a value.
- `jq`, for the Claude and Codex segments
- A [Nerd Font](https://www.nerdfonts.com/), for the default icons
- macOS or Linux (macOS is the primary target; Linux support is best-effort)

## Rate-limit hook

Both the `claude` and `codex` segments read a cache file in a common shape, written by
`scripts/rate-limit-hook.sh <provider>`:

```json
{
  "ts": 1234567890,
  "provider": "claude",
  "five_hour": { "used_percentage": 12, "resets_at": 1234571490 },
  "seven_day": { "used_percentage": 40, "resets_at": 1234999999 }
}
```

Either window is `null` when the provider's plan doesn't have one (e.g. Codex prolite plans have
no 5h window). The segment shows only the non-null window(s), and dims after `@vitals_stale`
seconds of no cache update.

The hook always passes stdin through unchanged, so it composes with any pipeline you already
have, and never breaks the pipe it sits in (invalid JSON, an unknown provider, or a missing `jq`
all just skip the cache write).

### Adding a provider

Each provider is one `case` branch in `rate-limit-hook.sh` (look for the `# to add a provider`
comment) mapping the provider's raw payload into the common shape, plus one `@vitals_*_cache`
tmux option for its cache path.

### Claude Code setup

Pipe the statusLine input through the hook, with `claude` as the provider, before your own
statusline command in `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.tmux/plugins/tmux-vitals/scripts/rate-limit-hook.sh claude | ~/.claude/statusline.sh"
  }
}
```

### Codex setup

The `#{vitals_codex}` segment needs the `codex` CLI logged in and reachable in `PATH`. It kicks
off a background refresh under a lock every `@vitals_codex_ttl` seconds (about every 5 minutes by
default) via `codex app-server`, piping the response through `rate-limit-hook.sh codex` — the
status line itself never calls `codex` synchronously, so it never blocks.
