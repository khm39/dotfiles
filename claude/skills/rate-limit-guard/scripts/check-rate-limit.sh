#!/usr/bin/env bash
# Claude のサブスク使用量(5時間枠=セッション枠のみが対象)が閾値に近いかを判定し、機械可読なJSONを1つだけstdoutに出す。
# 週次(7日)枠は本スキルの対象外(リセットが数日先で自動待機が非現実的なため)。状態ファイルに seven_day があっても無視する。
#
# 取得元: ~/.claude/rate-limit-guard/state.json
#   既存 statusline に追記したキャプチャ行(setup.sh install で導入)が rate_limits を実値で書き出すファイル。
#   サブスクの真の使用率。vibe-island 等の外部ツールには依存しない。
#   状態ファイルが無い/five_hourデータが無ければ source:none(= action:unknown)を返す。
#
# 状態ファイルが「待機中の無API期間」で古くなることがあるが、used_percentage は最後の既知値、
# resets_at(エポック秒)は将来時刻として有効なので、リセット判定は resets_in_seconds で行う想定。
#
# 環境変数で挙動を変えられる(テスト・移植のため):
#   RL_STATE_FILE     状態ファイルのパス (既定 ~/.claude/rate-limit-guard/state.json)
#   RL_THRESHOLD      閾値% (既定 90)
#   RL_STALE_SECONDS  この秒数より古い状態ファイルは fresh:false 扱い (既定 180)
set -u

STATE_FILE="${RL_STATE_FILE:-$HOME/.claude/rate-limit-guard/state.json}"
THRESHOLD="${RL_THRESHOLD:-90}"
STALE_SECONDS="${RL_STALE_SECONDS:-180}"
NOW="$(date +%s)"

SOURCE="none"
FRESH=false
NOTE=""
FIVE_PCT=null
FIVE_RESET=null

file_mtime() {
  # macOS と GNU の両対応
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}

read_statusline() {
  [ -f "$STATE_FILE" ] || return 1
  local fp
  fp="$(jq -r '.five_hour.used_percentage // empty' "$STATE_FILE" 2>/dev/null)"
  [ -n "$fp" ] || return 1

  SOURCE="statusline"
  FIVE_PCT="$(jq -r '.five_hour.used_percentage // "null"' "$STATE_FILE")"
  FIVE_RESET="$(jq -r '.five_hour.resets_at // "null"' "$STATE_FILE")"

  local mtime age
  mtime="$(file_mtime "$STATE_FILE")"
  if [ -n "$mtime" ]; then
    age=$(( NOW - mtime ))
    if [ "$age" -le "$STALE_SECONDS" ]; then
      FRESH=true
    else
      FRESH=false
      NOTE="状態ファイルは${age}秒前更新(>${STALE_SECONDS}s)。使用率は古い可能性。リセット時刻は有効。"
    fi
  fi
  return 0
}

read_statusline || true

jq -n \
  --arg source "$SOURCE" \
  --argjson fresh "$FRESH" \
  --argjson threshold "$THRESHOLD" \
  --argjson now "$NOW" \
  --argjson five_pct "$FIVE_PCT" \
  --argjson five_reset "$FIVE_RESET" \
  --arg note "$NOTE" \
  '
  def win(pct; reset):
    if pct == null then null
    else { used_percentage: pct,
           resets_at: reset,
           resets_in_seconds: (if reset == null then null else ([(reset - $now), 0] | max) end),
           over: (pct >= $threshold) }
    end;
  (win($five_pct; $five_reset)) as $five
  | (if   ($five != null and $five.over) then "wrap_up_and_wait"
     elif ($five != null)                then "continue"
     else "unknown" end) as $action
  | { source: $source,
      fresh: $fresh,
      threshold: $threshold,
      now: $now,
      windows: { five_hour: $five },
      action: $action,
      note: (if $note == "" then null else $note end) }
  '
