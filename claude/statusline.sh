#!/bin/bash

input=$(cat)

# Model name
model=$(echo "$input" | jq -r '.model.display_name // "Claude"')

# Context usage with color-coded progress bar
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
ctx=""
if [ -n "$used" ]; then
  used_int=$(printf "%.0f" "$used")
  bar_width=20
  filled=$(( used_int * bar_width / 100 ))
  empty=$(( bar_width - filled ))

  # Color: green < 50%, yellow 50-79%, red 80%+
  if [ "$used_int" -ge 80 ]; then
    color="\033[31m"  # red
  elif [ "$used_int" -ge 50 ]; then
    color="\033[33m"  # yellow
  else
    color="\033[32m"  # green
  fi
  reset="\033[0m"

  bar=""
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=0; i<empty; i++)); do bar+="░"; done

  ctx=" | ${color}${bar}${reset} ${used_int}%"
fi

# Session cost
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
cost_str=""
if [ -n "$cost" ]; then
  cost_str=" | 💰$(printf '$%.2f' "$cost")"
fi

# Lines added/removed
added=$(echo "$input" | jq -r '.cost.total_lines_added // 0')
removed=$(echo "$input" | jq -r '.cost.total_lines_removed // 0')
lines=""
if [ "$added" -gt 0 ] || [ "$removed" -gt 0 ]; then
  lines=" | \033[32m+${added}\033[0m \033[31m-${removed}\033[0m"
fi

# Git branch
branch=""
if git rev-parse --git-dir > /dev/null 2>&1; then
  br=$(git branch --show-current 2>/dev/null)
  if [ -n "$br" ]; then
    branch=" | 🌿 ${br}"
  fi
fi

# Elapsed time
duration=$(echo "$input" | jq -r '.cost.total_duration_ms // empty')
elapsed=""
if [ -n "$duration" ]; then
  mins=$(( ${duration%.*} / 60000 ))
  if [ "$mins" -gt 0 ]; then
    elapsed=" | ⏱️ ${mins}min"
  fi
fi

echo -e "🦀 ${model}${ctx}${cost_str}${lines}${branch}${elapsed}"
