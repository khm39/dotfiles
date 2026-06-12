#!/usr/bin/env bash
# PreToolUse hook: 使用量を自動チェックし、閾値超過(5時間枠/週次枠)や接近(approaching)のときに
# rate-limit-guard スキルの使用を促すヒントを additionalContext で注入する(非ブロッキング=ツールは止めない)。
#
# ノイズ抑制(セッション単位): 同じ「action + 対象ウィンドウのリセット時刻」の組につき1回だけ注入する。
# 状況がエスカレートしたら(approaching → wrap_up_and_wait 等)組が変わるので再注入される。
# フラグは hook 入力の session_id で分離するので、並行セッションが互いの通知を抑制しない
# (枠の resets_at は全セッション共通のため、グローバル1ファイルだと1セッションのヒントが他を黙らせてしまう)。
# 閾値未満/取得不可に戻るとそのセッションのフラグを解除。
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

case "$action" in
  wrap_up_and_wait|wrap_up_and_stop|approaching) ;;
  *)
    rm -f "$FLAG" 2>/dev/null   # このセッションの超過解消/不明 → 解除(次の跨ぎで再ヒント)
    exit 0 ;;
esac

lim="$(printf '%s' "$res" | jq -r '.limiting_window // "five_hour"' 2>/dev/null)"
reset="$(printf '%s' "$res" | jq -r --arg w "$lim" '.windows[$w].resets_at // 0' 2>/dev/null)"
key="$action:$reset"
prev=""; [ -f "$FLAG" ] && prev="$(cat "$FLAG" 2>/dev/null)"
[ "$prev" = "$key" ] && exit 0   # 同一セッション・同一状況で既にヒント済み → 黙る

mkdir -p "$HINT_DIR" 2>/dev/null
find "$HINT_DIR" -name '*.flag' -mtime +1 -delete 2>/dev/null   # 終了済みセッションの古いフラグを掃除
printf '%s' "$key" > "$FLAG" 2>/dev/null

pct="$(printf '%s' "$res" | jq -r --arg w "$lim" '.windows[$w].used_percentage // "?"' 2>/dev/null)"
secs="$(printf '%s' "$res" | jq -r --arg w "$lim" '.windows[$w].resets_in_seconds // "?"' 2>/dev/null)"
case "$lim" in
  seven_day) wname="週次(7日)枠" ;;
  *)         wname="5時間枠" ;;
esac

ckpt="\$HOME/.claude/rate-limit-guard/checkpoints/${sid}.md"
case "$action" in
  approaching)
    msg="rate-limit-guard: ${wname}の使用率が ${pct}% で警告域に入りました(閾値まであと僅か)。作業は続行してよいが、以後は作業の節目ごとに check-rate-limit.sh で使用量を確認し、超過に備えて切りの良い単位で進めてください。" ;;
  wrap_up_and_stop)
    msg="rate-limit-guard: ${wname}の使用率が ${pct}% で閾値を超過し、リセットは約 ${secs} 秒先(自動待機の上限より遠い)です。新しい着手はせず、今の作業を切りの良い状態に整え(チェックポイントを ${ckpt} に保存/WIPコミット)、rate-limit-guard スキルの手順に従って状況をユーザーに報告して停止してください。チームで作業中ならメンバーにも切り上げを指示すること。" ;;
  *)
    msg="rate-limit-guard: ${wname}の使用率が ${pct}% で閾値を超過しています(約 ${secs} 秒でリセット)。新しい着手はせず、今の作業を切りの良い状態に整え(チェックポイントを ${ckpt} に保存/WIPコミット)、rate-limit-guard スキルの手順に従ってリセットまで待機し自動再開してください。チームで作業中ならメンバーにも切り上げを指示すること。" ;;
esac

jq -n --arg m "$msg" '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $m}}'
exit 0
