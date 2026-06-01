#!/usr/bin/env bash
# PreToolUse hook: 使用量を自動チェックし、5時間枠が閾値超過なら rate-limit-guard スキルの
# 使用を促すヒントを additionalContext で注入する(非ブロッキング=ツールは止めない)。
#
# ノイズ抑制(セッション単位): 閾値を跨いだ「初回」だけ注入する。フラグは hook 入力の session_id で
# 分離するので、並行セッションが互いの通知を抑制しない(5時間枠の resets_at は全セッション共通のため、
# グローバル1ファイルだと1セッションのヒントが他を黙らせてしまう)。同じセッション・同じウィンドウでは
# 黙る(切り上げ作業中に毎回ナグらない)。閾値未満/取得不可に戻るとそのセッションのフラグを解除。
#
# 安全側: チェックやjqが失敗しても必ず exit 0。ガード機構がツール実行をブロックしないようにする。
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${RL_STATE_DIR:-$HOME/.claude/rate-limit-guard}"
HINT_DIR="$STATE_DIR/hints"

hook_input="$(cat 2>/dev/null)"   # hook入力JSON(session_id を含む)

command -v jq >/dev/null 2>&1 || exit 0

sid="$(printf '%s' "$hook_input" | jq -r '.session_id // empty' 2>/dev/null | tr -cd 'A-Za-z0-9_-')"
[ -n "$sid" ] || sid="default"
FLAG="$HINT_DIR/$sid.flag"

res="$(bash "$SELF_DIR/check-rate-limit.sh" 2>/dev/null)" || exit 0
action="$(printf '%s' "$res" | jq -r '.action // "unknown"' 2>/dev/null)"

if [ "$action" != "wrap_up_and_wait" ]; then
  rm -f "$FLAG" 2>/dev/null   # このセッションの超過解消/不明 → 解除(次の跨ぎで再ヒント)
  exit 0
fi

reset="$(printf '%s' "$res" | jq -r '.windows.five_hour.resets_at // 0' 2>/dev/null)"
prev=""; [ -f "$FLAG" ] && prev="$(cat "$FLAG" 2>/dev/null)"
[ "$prev" = "$reset" ] && exit 0   # 同一セッション・同一ウィンドウで既にヒント済み → 黙る

mkdir -p "$HINT_DIR" 2>/dev/null
find "$HINT_DIR" -name '*.flag' -mtime +1 -delete 2>/dev/null   # 終了済みセッションの古いフラグを掃除
printf '%s' "$reset" > "$FLAG" 2>/dev/null

pct="$(printf '%s' "$res" | jq -r '.windows.five_hour.used_percentage // "?"' 2>/dev/null)"
secs="$(printf '%s' "$res" | jq -r '.windows.five_hour.resets_in_seconds // "?"' 2>/dev/null)"
msg="rate-limit-guard: 5時間枠の使用率が ${pct}% で閾値を超過しています(約 ${secs} 秒でリセット)。新しい着手はせず、今の作業を切りの良い状態に整え(チェックポイント/WIPコミット)、rate-limit-guard スキルの手順に従ってリセットまで待機し自動再開してください。"

jq -n --arg m "$msg" '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $m}}'
exit 0
