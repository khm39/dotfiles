#!/usr/bin/env bash
# evals.json の mock_state(resets_in = 現在からの相対秒)を、チェッカーが読む state.json 形式
# (resets_at = エポック絶対秒)に変換して書き出すテストヘルパ。
# stale 指定時はファイル mtime を過去に偽装する(fresh:false / 待機明けシナリオの再現)。
#
# 使い方:
#   make-mock.sh <出力パス> <five_pct> <five_resets_in> <seven_pct> <seven_resets_in> [stale_minutes]
#   値に "null" を渡すとそのフィールドを省略する。
# 例:
#   make-mock.sh /tmp/mock.json 92 1500 40 200000        # 5h超過・リセット1500秒後
#   make-mock.sh /tmp/mock.json 92 -300 45 200000 120    # リセット経過済み + 2時間前のmtime(eval4)
#   make-mock.sh /tmp/mock.json 95 null null null        # resets_at欠落エッジケース
set -eu

[ $# -ge 5 ] || { echo "usage: make-mock.sh <out> <five_pct> <five_resets_in> <seven_pct> <seven_resets_in> [stale_minutes]" >&2; exit 2; }

OUT="$1"; FP="$2"; FR="$3"; SP="$4"; SR="$5"; STALE="${6:-}"
NOW="$(date +%s)"

win() {  # $1=pct $2=resets_in
  [ "$1" = null ] && return 0
  if [ "$2" = null ]; then
    printf '{"used_percentage":%s,"resets_at":null}' "$1"
  else
    printf '{"used_percentage":%s,"resets_at":%s}' "$1" "$(( NOW + $2 ))"
  fi
}

FIVE="$(win "$FP" "$FR")"
SEVEN="$(win "$SP" "$SR")"

{
  printf '{'
  [ -n "$FIVE" ] && printf '"five_hour":%s' "$FIVE"
  [ -n "$FIVE" ] && [ -n "$SEVEN" ] && printf ','
  [ -n "$SEVEN" ] && printf '"seven_day":%s' "$SEVEN"
  printf '}'
} > "$OUT"

if [ -n "$STALE" ]; then
  # macOS / GNU 両対応で mtime を過去にずらす
  if touch -t "$(date -v"-${STALE}M" +%Y%m%d%H%M 2>/dev/null)" "$OUT" 2>/dev/null; then :
  else touch -d "-${STALE} minutes" "$OUT"; fi
fi

cat "$OUT"; echo
