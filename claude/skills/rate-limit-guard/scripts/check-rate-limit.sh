#!/usr/bin/env bash
# Claude のサブスク使用量(5時間枠・週次=7日枠)が閾値に近いかを判定し、機械可読なJSONを1つだけstdoutに出す。
# 契約: どんな失敗時(状態ファイル無し/破損/型不一致/jq不在)でも必ず action:unknown のJSONを出して exit 0。
#
# 取得元: ~/.claude/rate-limit-guard/state.json
#   既存 statusline に追記したキャプチャ行(setup.sh install で導入)が rate_limits を実値で書き出すファイル。
#   サブスクの真の使用率。vibe-island 等の外部ツールには依存しない。
#
# リセット到達の扱い: 状態ファイルは待機中の無API期間に更新されない。used_percentage は最後の既知値だが、
# 現在時刻が resets_at を超えていれば枠は既にロールしており、古い使用率は前の枠のもの。
# その場合は window_elapsed:true として over/approaching とは判定しない(=待機明けに古い92%を見て
# 再待機し続ける誤判定をスクリプト側で防ぐ)。
#
# action の決め方:
#   wrap_up_and_stop  週次枠が閾値超過かつリセットが RL_MAX_WAIT_SECONDS より先 → 自動待機は非現実的。
#                     チェックポイントを残してユーザーに報告し停止する。
#   wrap_up_and_wait  5時間枠が超過、または週次枠が超過でリセットが RL_MAX_WAIT_SECONDS 以内。
#                     wait_until(エポック秒)まで待って再開する。両枠該当なら遅い方に合わせる。
#   approaching       いずれかの枠が RL_WARN_THRESHOLD 以上・閾値未満。続行してよいが毎節目でチェック。
#   continue          すべて余裕あり。
#   unknown           使用量データが取得できない。または超過しているのに resets_at が取れず
#                     待機目標を計算できない(note に理由)。いずれもユーザーに確認するのが正しい対処。
#
# 環境変数で挙動を変えられる(テスト・移植のため):
#   RL_STATE_FILE        状態ファイルのパス (既定 ~/.claude/rate-limit-guard/state.json)
#   RL_THRESHOLD         発動閾値% (既定 90)
#   RL_WARN_THRESHOLD    approaching 閾値% (既定 80)
#   RL_MAX_WAIT_SECONDS  自動待機する最大秒数 (既定 21600 = 6時間)。週次枠の待つ/止まる分岐に使う
#   RL_STALE_SECONDS     この秒数より古い状態ファイルは fresh:false 扱い (既定 180)
set -u

STATE_FILE="${RL_STATE_FILE:-$HOME/.claude/rate-limit-guard/state.json}"
THRESHOLD="${RL_THRESHOLD:-90}"
WARN_THRESHOLD="${RL_WARN_THRESHOLD:-80}"
MAX_WAIT="${RL_MAX_WAIT_SECONDS:-21600}"
STALE_SECONDS="${RL_STALE_SECONDS:-180}"
NOW="$(date +%s)"

emit_unknown() {
  printf '{"source":"none","fresh":false,"now":%s,"windows":{"five_hour":null,"seven_day":null},"action":"unknown","limiting_window":null,"wait_until":null,"note":"%s"}\n' "$NOW" "$1"
  exit 0
}

command -v jq >/dev/null 2>&1 || emit_unknown "jq が見つからないため使用量を判定できない"

SOURCE="none"
FRESH=false
NOTE=""
FIVE_PCT=null
FIVE_RESET=null
SEVEN_PCT=null
SEVEN_RESET=null

file_mtime() {
  # macOS と GNU の両対応
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}

# 数値(整数/小数)以外は null に落とす。rate_limits のスキーマが変わって文字列が来ても
# --argjson を壊して無出力で死ぬのではなく、unknown 側に倒すため。
num_or_null() {
  case "$1" in
    ''|null) printf 'null' ;;
    *[!0-9.]*) printf 'null' ;;
    *) printf '%s' "$1" ;;
  esac
}

read_statusline() {
  [ -f "$STATE_FILE" ] || return 1
  local fp fr sp sr
  fp="$(jq -r '.five_hour.used_percentage // empty' "$STATE_FILE" 2>/dev/null)" || return 1
  fr="$(jq -r '.five_hour.resets_at // empty' "$STATE_FILE" 2>/dev/null)"
  sp="$(jq -r '.seven_day.used_percentage // empty' "$STATE_FILE" 2>/dev/null)"
  sr="$(jq -r '.seven_day.resets_at // empty' "$STATE_FILE" 2>/dev/null)"

  FIVE_PCT="$(num_or_null "$fp")"
  FIVE_RESET="$(num_or_null "$fr")"
  SEVEN_PCT="$(num_or_null "$sp")"
  SEVEN_RESET="$(num_or_null "$sr")"
  { [ "$FIVE_PCT" != null ] || [ "$SEVEN_PCT" != null ]; } || return 1

  SOURCE="statusline"
  if { [ -n "$fp" ] && [ "$FIVE_PCT" = null ]; } || { [ -n "$sp" ] && [ "$SEVEN_PCT" = null ]; }; then
    NOTE="状態ファイルに数値でない使用率があり一部を無視した。"
  fi

  local mtime age
  mtime="$(file_mtime "$STATE_FILE")"
  if [ -n "$mtime" ]; then
    age=$(( NOW - mtime ))
    if [ "$age" -le "$STALE_SECONDS" ]; then
      FRESH=true
    else
      FRESH=false
      NOTE="${NOTE}状態ファイルは${age}秒前更新(>${STALE_SECONDS}s)。使用率は古い可能性。リセット時刻は有効。"
    fi
  fi
  return 0
}

read_statusline || true

OUT="$(jq -n \
  --arg source "$SOURCE" \
  --argjson fresh "$FRESH" \
  --argjson threshold "$THRESHOLD" \
  --argjson warn_threshold "$WARN_THRESHOLD" \
  --argjson max_wait "$MAX_WAIT" \
  --argjson now "$NOW" \
  --argjson five_pct "$FIVE_PCT" \
  --argjson five_reset "$FIVE_RESET" \
  --argjson seven_pct "$SEVEN_PCT" \
  --argjson seven_reset "$SEVEN_RESET" \
  --arg note "$NOTE" \
  '
  def eval_window($pct; $reset):
    if $pct == null then null
    else
      (($reset != null) and ($now >= $reset)) as $elapsed
      | { used_percentage: $pct,
          resets_at: $reset,
          resets_in_seconds: (if $reset == null then null else ([($reset - $now), 0] | max) end),
          window_elapsed: $elapsed,
          over: (($elapsed | not) and ($pct >= $threshold)),
          approaching: (($elapsed | not) and ($pct >= $warn_threshold) and ($pct < $threshold)) }
    end;

  eval_window($five_pct; $five_reset) as $five
  | eval_window($seven_pct; $seven_reset) as $seven

  # 週次枠の超過: リセットが max_wait 以内なら待てる、それより先なら停止
  | (($seven != null) and $seven.over and ($seven.resets_in_seconds != null) and ($seven.resets_in_seconds > $max_wait)) as $seven_stop
  | (($seven != null) and $seven.over and ($seven.resets_in_seconds != null) and ($seven_stop | not)) as $seven_wait
  | (($five != null) and $five.over and ($five.resets_at != null)) as $five_wait
  # 超過しているのに resets_at が無い → 待機目標を計算できない。unknown に倒してユーザー確認へ
  | ((($five != null) and $five.over and ($five.resets_at == null)) or
     (($seven != null) and $seven.over and ($seven.resets_at == null))) as $over_no_reset

  | (if $seven_stop then "wrap_up_and_stop"
     elif ($five_wait or $seven_wait) then "wrap_up_and_wait"
     elif $over_no_reset then "unknown"
     elif (($five != null and $five.approaching) or ($seven != null and $seven.approaching)) then "approaching"
     elif ($five != null or $seven != null) then "continue"
     else "unknown" end) as $action

  # 待機の目標時刻: 超過していて待てる枠のうち遅い方(両枠超過なら遅い方まで待たないと再開できない)
  | (if $action == "wrap_up_and_wait" then
       ([ (if $five_wait then $five.resets_at else empty end),
          (if $seven_wait then $seven.resets_at else empty end) ] | max)
     else null end) as $wait_until

  | (if $seven_stop then "seven_day"
     elif $action == "wrap_up_and_wait" then
       (if $seven_wait and (($five_wait | not) or ($seven.resets_at >= $five.resets_at)) then "seven_day" else "five_hour" end)
     elif $action == "approaching" then
       (if ($five != null and $five.approaching) then "five_hour" else "seven_day" end)
     else null end) as $limiting

  | ([ $note,
       (if $over_no_reset then "使用率は閾値超過だが resets_at が取得できず待機目標を計算できない。ユーザーに確認すること。" else empty end),
       (if ($five != null and $five.window_elapsed) then "5時間枠は resets_at を経過済み。使用率は前の枠の値なので超過扱いしない。" else empty end),
       (if ($seven != null and $seven.window_elapsed) then "週次枠は resets_at を経過済み。使用率は前の枠の値なので超過扱いしない。" else empty end)
     ] | map(select(. != "")) | join(" ")) as $notes

  | { source: $source,
      fresh: $fresh,
      threshold: $threshold,
      warn_threshold: $warn_threshold,
      max_wait_seconds: $max_wait,
      now: $now,
      windows: { five_hour: $five, seven_day: $seven },
      action: $action,
      limiting_window: $limiting,
      wait_until: $wait_until,
      note: (if $notes == "" then null else $notes end) }
  ' 2>/dev/null)" || emit_unknown "判定処理が失敗した(状態ファイル破損の可能性)"

[ -n "$OUT" ] || emit_unknown "判定処理が失敗した(状態ファイル破損の可能性)"
printf '%s\n' "$OUT"
