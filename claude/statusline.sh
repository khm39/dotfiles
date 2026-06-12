#!/bin/bash

input=$(cat)

# ── Vibe Island: rate_limits bridge (managed, do not remove) ───
_rl=$(echo "$input" | jq -c '.rate_limits // empty' 2>/dev/null)
[ -n "$_rl" ] && mkdir -p "$(dirname "$HOME/.vibe-island/cache/rl.json")" 2>/dev/null && printf '%s\n' "$_rl" > "$HOME/.vibe-island/cache/rl.json"
# ── End Vibe Island bridge ─────────────────────────────

pct_color() {
  if [ "$1" -ge 80 ]; then printf '%s' '\033[31m'
  elif [ "$1" -ge 50 ]; then printf '%s' '\033[33m'
  else printf '%s' '\033[32m'
  fi
}

render_bar() {
  local pct_int="$1"
  local w="$2"
  local f=$(( pct_int * w / 100 ))
  local e=$(( w - f ))
  local color
  color=$(pct_color "$pct_int")
  local b=""
  for ((i=0; i<f; i++)); do b+="█"; done
  for ((i=0; i<e; i++)); do b+="░"; done
  printf "${color}%s\033[0m %d%%" "$b" "$pct_int"
}

model=$(echo "$input" | jq -r '.model.display_name // "Claude"')

used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
ctx=""
if [ -n "$used" ]; then
  ctx=" | $(render_bar "$(printf '%.0f' "$used")" 20)"
fi

# Rate limits: Claude.ai Pro/Max only, absent before first API response
now=$(date +%s)

fmt_reset() {
  local at="${1%.*}"
  case "$at" in ''|*[!0-9]*) return ;; esac
  local secs=$(( at - now ))
  [ "$secs" -le 0 ] && return
  local d=$(( secs / 86400 ))
  local h=$(( (secs % 86400) / 3600 ))
  local m=$(( (secs % 3600) / 60 ))
  if [ "$d" -gt 0 ]; then printf ' ⏳%dd%dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf ' ⏳%dh%02dm' "$h" "$m"
  else printf ' ⏳%dm' "$m"
  fi
}

rate=""
five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
if [ -n "$five_pct" ]; then
  five_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
  rate=" | 5h $(render_bar "$(printf '%.0f' "$five_pct")" 10)$(fmt_reset "$five_reset")"
fi

seven_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
if [ -n "$seven_pct" ]; then
  seven_int=$(printf '%.0f' "$seven_pct")
  seven_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
  rate="${rate} | 7d $(pct_color "$seven_int")${seven_int}%\033[0m$(fmt_reset "$seven_reset")"
fi

cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
cost_str=""
if [ -n "$cost" ]; then
  cost_str=" | 💰$(printf '$%.2f' "$cost")"
fi

added=$(echo "$input" | jq -r '.cost.total_lines_added // 0')
removed=$(echo "$input" | jq -r '.cost.total_lines_removed // 0')
lines=""
if [ "$added" -gt 0 ] || [ "$removed" -gt 0 ]; then
  lines=" | \033[32m+${added}\033[0m \033[31m-${removed}\033[0m"
fi

branch=""
if git rev-parse --git-dir > /dev/null 2>&1; then
  br=$(git branch --show-current 2>/dev/null)
  if [ -n "$br" ]; then
    branch=" | 🌿 ${br}"
  fi
fi

duration=$(echo "$input" | jq -r '.cost.total_duration_ms // empty')
elapsed=""
case "$duration" in
  ''|*[!0-9.]*) duration="" ;;
esac
if [ -n "$duration" ]; then
  mins=$(( ${duration%.*} / 60000 ))
  if [ "$mins" -gt 0 ]; then
    elapsed=" | ⏱️ ${mins}min"
  fi
fi

echo -e "🦀 ${model}${ctx}${rate}${cost_str}${lines}${branch}${elapsed}"
# >>> rate-limit-guard (managed; remove with setup.sh uninstall) >>>
# 既存 statusline が読み込んだ $input(stdinのJSON)から rate_limits を独自stateへ書き出す。
_rlg=$(printf '%s' "$input" | jq -c '.rate_limits // empty' 2>/dev/null)
if [ -n "$_rlg" ]; then
  mkdir -p "$HOME/.claude/rate-limit-guard" 2>/dev/null
  printf '%s' "$input" | jq -c '.rate_limits + {captured_at: (now|floor)}' > "$HOME/.claude/rate-limit-guard/state.json" 2>/dev/null
fi
# <<< rate-limit-guard <<<
