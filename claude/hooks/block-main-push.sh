#!/usr/bin/env bash
# PreToolUse hook for Bash.
# main/master ブランチへの git push をブロックし、feature 等への push は許可する。
# Claude Code の permission パターンはブランチ単位の制御ができず引数制約も脆弱なため
# (公式ドキュメント参照)、push 先ブランチの判定はこのフックで行う。
#   - git push 以外のコマンド            -> 許可
#   - 明示的に main/master を push 先指定 -> ブロック (force/+ refspec 含む)
#   - bare push / remote のみ指定        -> 現在ブランチ(または上流push先)が main/master ならブロック
#   - それ以外(feature 等)               -> 許可
# 緊急回避: CLAUDE_BYPASS_MAIN_PUSH=1

set -u

payload=$(cat)

[ "${CLAUDE_BYPASS_MAIN_PUSH:-}" = "1" ] && exit 0
command -v jq >/dev/null 2>&1 || { echo "[block-main-push] jq が無いため判定をスキップします。" >&2; exit 0; }

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)
[ -z "${cwd:-}" ] && cwd="${PWD:-$(pwd)}"
[ -z "${cmd:-}" ] && exit 0

# git push を含まないコマンドは対象外。
printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+push' || exit 0

block() {
  cat >&2 <<MSG
[block-main-push] main/master ブランチへの push をブロックしました。
feature 等のブランチへの push は許可されています。main へ反映するには PR 経由にしてください。
コマンド : $cmd
緊急回避 : CLAUDE_BYPASS_MAIN_PUSH=1 を設定するとこのフックを無効化できます。
MSG
  exit 2
}

# `git push` 以降の引数を走査する。
rest=$(printf '%s' "$cmd" | sed -E 's/.*git[[:space:]]+push//')
nonopt_count=0
for tok in $rest; do
  case "$tok" in
    -*) continue ;;
  esac
  nonopt_count=$((nonopt_count + 1))
  # refspec の destination 側を取り出す: 先頭 '+'(force) を除去し、src:dst なら dst を採用。
  dst="${tok#+}"
  case "$dst" in
    *:*) dst="${dst##*:}" ;;
  esac
  case "$dst" in
    main|master) block ;;
  esac
done

# 非オプション引数が 2 個以上 = リモート+明示ブランチ。main は上で弾いているので feature とみなし許可。
[ "$nonopt_count" -ge 2 ] && exit 0

# bare push / remote のみ: 実際の push 先(上流)か現在ブランチで判定。
target=$(git -C "$cwd" rev-parse --abbrev-ref '@{push}' 2>/dev/null | sed -E 's#^[^/]+/##' || true)
[ -z "${target:-}" ] && target=$(git -C "$cwd" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
case "${target:-}" in
  main|master) block ;;
esac

exit 0
