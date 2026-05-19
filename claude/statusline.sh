#!/bin/bash

input=$(cat)

render_bar() {
  local pct_int="$1"
  local w="$2"
  local f=$(( pct_int * w / 100 ))
  local e=$(( w - f ))
  local color
  if [ "$pct_int" -ge 80 ]; then color="\033[31m"
  elif [ "$pct_int" -ge 50 ]; then color="\033[33m"
  else color="\033[32m"
  fi
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
five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
rate=""
if [ -n "$five_pct" ]; then
  rate=" | 5h $(render_bar "$(printf '%.0f' "$five_pct")" 10)"
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
if [ -n "$duration" ]; then
  mins=$(( ${duration%.*} / 60000 ))
  if [ "$mins" -gt 0 ]; then
    elapsed=" | ⏱️ ${mins}min"
  fi
fi

echo -e "🦀 ${model}${ctx}${rate}${cost_str}${lines}${branch}${elapsed}"
