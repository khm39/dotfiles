#!/usr/bin/env bash
# rate-limit-guard のセットアップ。2つを冪等に導入/除去する(どちらも追記方式・バックアップ付き):
#   (1) 使用率キャプチャ: 既存の statusline スクリプトに、rate_limits を独自stateへ書き出す行を追記。
#       statusLine の "コマンド"(settings.json)は差し替えない。表示・動作は不変。
#   (2) ヒント用 hook:    settings.json の PreToolUse に、使用量を自動チェックして
#       skill 使用を促す hook(ratelimit-hint-hook.sh)を追加。非ブロッキング。
#
#   setup.sh install     両方を導入
#   setup.sh uninstall   両方を除去
#   setup.sh status      現在の状態を表示(既定)
#
# 環境変数: RLG_SETTINGS_FILE / RLG_STATUSLINE_FILE で対象ファイルを上書き可。
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="${RLG_SETTINGS_FILE:-$HOME/.claude/settings.json}"
STATE_DIR="${RL_STATE_DIR:-$HOME/.claude/rate-limit-guard}"

HOOK_SCRIPT="$SELF_DIR/ratelimit-hint-hook.sh"
HOOK_CMD="/bin/bash $HOOK_SCRIPT"
HOOK_MATCHER="Edit|Write|Bash"
HOOK_ID="ratelimit-hint-hook.sh"

ts() { date +%Y%m%d%H%M%S; }

# シンボリックリンクを実体まで辿る。symlink 先(例: dotfiles 実体)を直接書き換えることで、
# mv による書き戻しが symlink を実ファイルに置き換えて壊すのを防ぐ(symlink/実体どちらでも安全)。
resolve_real() {
  local p="$1" t
  while [ -L "$p" ]; do
    t="$(readlink "$p")"
    case "$t" in
      /*) p="$t" ;;
      *)  p="$(cd "$(dirname "$p")" && pwd)/$t" ;;
    esac
  done
  printf '%s' "$p"
}

# ───── (1) statusline 追記 ─────
resolve_statusline() {
  if [ -n "${RLG_STATUSLINE_FILE:-}" ]; then printf '%s' "$RLG_STATUSLINE_FILE"; return; fi
  local cmd tok script="" toks
  cmd="$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null)"
  # statusLine.command を空白分割し .sh で終わるトークンを拾う(末尾に引数があっても誤認しない)
  read -ra toks <<< "$cmd"
  for tok in "${toks[@]}"; do
    case "$tok" in *.sh) script="$tok" ;; esac
  done
  [ -n "$script" ] || script="$HOME/.claude/statusline.sh"   # 見つからなければ既定
  printf '%s' "${script/#\~/$HOME}"                          # ~ を展開
}

emit_block() {
  cat <<'BLOCK'
# >>> rate-limit-guard (managed; remove with setup.sh uninstall) >>>
# 既存 statusline が読み込んだ $input(stdinのJSON)から rate_limits を独自stateへ書き出す。
_rlg=$(printf '%s' "$input" | jq -c '.rate_limits // empty' 2>/dev/null)
if [ -n "$_rlg" ]; then
  mkdir -p "$HOME/.claude/rate-limit-guard" 2>/dev/null
  printf '%s' "$input" | jq -c '.rate_limits + {captured_at: (now|floor)}' > "$HOME/.claude/rate-limit-guard/state.json" 2>/dev/null
fi
# <<< rate-limit-guard <<<
BLOCK
}

install_capture() {
  local t; t="$(resolve_statusline)"
  if [ ! -f "$t" ]; then echo "  [capture] statusline 未検出: $t (RLG_STATUSLINE_FILE で指定可)"; return 1; fi
  if grep -q "rate-limit-guard" "$t"; then echo "  [capture] 既に導入済み: $t"; return 0; fi
  cp "$t" "$t.rlguard.bak.$(ts)"
  [ -n "$(tail -c1 "$t")" ] && printf '\n' >> "$t"
  emit_block >> "$t"
  echo "  [capture] 追記完了: $t (コマンドは非変更)"
}

uninstall_capture() {
  local t; t="$(resolve_statusline)"
  [ -f "$t" ] || { echo "  [capture] 対象なし: $t"; return 0; }
  if ! grep -q "rate-limit-guard" "$t"; then echo "  [capture] 追記なし: $t"; return 0; fi
  cp "$t" "$t.rlguard.bak.$(ts)"
  local tmp; tmp="$(mktemp)"
  awk -v s=">>> rate-limit-guard" -v e="<<< rate-limit-guard" '
    $0 ~ s {skip=1} skip==0 {print} $0 ~ e {skip=0}' "$t" > "$tmp" && mv "$tmp" "$(resolve_real "$t")"
  echo "  [capture] 除去完了: $t"
}

# ───── (2) PreToolUse hook ─────
hook_present() {
  [ -f "$SETTINGS" ] || return 1
  jq -e --arg id "$HOOK_ID" '
    [ (.hooks.PreToolUse // [])[]?.hooks[]?.command // "" | select(test($id)) ] | length > 0
  ' "$SETTINGS" >/dev/null 2>&1
}

install_hook() {
  [ -f "$SETTINGS" ] || { echo "  [hook] settings.json 未検出: $SETTINGS"; return 1; }
  if hook_present; then echo "  [hook] 既に導入済み: $SETTINGS"; return 0; fi
  cp "$SETTINGS" "$SETTINGS.rlguard.bak.$(ts)"
  local tmp; tmp="$(mktemp)"
  jq --arg cmd "$HOOK_CMD" --arg m "$HOOK_MATCHER" '
    .hooks //= {} | .hooks.PreToolUse //= [] |
    .hooks.PreToolUse += [ { matcher: $m, hooks: [ { type: "command", command: $cmd } ] } ]
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$(resolve_real "$SETTINGS")"
  echo "  [hook] PreToolUse に追加: $HOOK_CMD"
}

uninstall_hook() {
  [ -f "$SETTINGS" ] || { echo "  [hook] settings.json なし"; return 0; }
  if ! hook_present; then echo "  [hook] 追加なし"; return 0; fi
  cp "$SETTINGS" "$SETTINGS.rlguard.bak.$(ts)"
  local tmp; tmp="$(mktemp)"
  jq --arg id "$HOOK_ID" '
    if (.hooks.PreToolUse | type) == "array" then
      .hooks.PreToolUse |= map(select(
        ((.hooks // []) | map(.command // "") | join(" ")) | test($id) | not))
    else . end
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$(resolve_real "$SETTINGS")"
  echo "  [hook] PreToolUse から除去"
}

case "${1:-status}" in
  install)
    mkdir -p "$STATE_DIR"
    echo "rate-limit-guard をインストール:"
    install_capture
    install_hook
    echo "完了。statusLine のコマンドは差し替えていません。"
    ;;
  uninstall)
    echo "rate-limit-guard をアンインストール:"
    uninstall_hook
    uninstall_capture
    echo "完了。"
    ;;
  status)
    local_t="$(resolve_statusline)"
    echo "settings:        $SETTINGS"
    echo "statusline:      $local_t $([ -f "$local_t" ] && echo '(あり)' || echo '(なし)')"
    echo "  キャプチャ追記: $([ -f "$local_t" ] && grep -q 'rate-limit-guard' "$local_t" && echo '導入済み' || echo '未導入')"
    echo "  PreToolUse hook: $(hook_present && echo '導入済み' || echo '未導入')"
    echo "状態ファイル:    $STATE_DIR/state.json $([ -f "$STATE_DIR/state.json" ] && echo '(あり)' || echo '(なし)')"
    ;;
  *)
    echo "usage: setup.sh [install|uninstall|status]" >&2; exit 2 ;;
esac
