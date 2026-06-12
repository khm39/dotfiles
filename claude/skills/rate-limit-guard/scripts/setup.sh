#!/usr/bin/env bash
# rate-limit-guard のセットアップ。2つを冪等に導入/除去する(どちらも追記方式・バックアップ付き):
#   (1) 使用率キャプチャ: 既存の statusline スクリプトに、rate_limits を独自stateへ書き出す行を追記。
#       statusLine の "コマンド"(settings.json)は差し替えない。表示・動作は不変。
#   (2) ヒント用 hook:    settings.json の PreToolUse に、使用量を自動チェックして
#       skill 使用を促す hook(ratelimit-hint-hook.sh)を追加。非ブロッキング。
#
#   setup.sh install     両方を導入(部分失敗時は非零 exit)
#   setup.sh uninstall   両方を除去
#   setup.sh status      現在の状態を表示(既定)
#
# 環境変数: RLG_SETTINGS_FILE / RLG_STATUSLINE_FILE で対象ファイルを上書き可。
#           RLG_FORCE=1 で worktree パスからの install 警告を無視。
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="${RLG_SETTINGS_FILE:-$HOME/.claude/settings.json}"
STATE_DIR="${RL_STATE_DIR:-$HOME/.claude/rate-limit-guard}"

HOOK_SCRIPT="$SELF_DIR/ratelimit-hint-hook.sh"
HOOK_CMD="/bin/bash $HOOK_SCRIPT"
# チームリードは Edit/Write をほぼ使わないため、調整系ツールにも反応させる
HOOK_MATCHER="Edit|Write|Bash|SendMessage|Agent"
HOOK_ID="ratelimit-hint-hook.sh"

ts() { date +%Y%m%d%H%M%S; }

# シンボリックリンクを実体まで辿る。symlink 先(例: dotfiles 実体)を直接書き換えることで、
# 書き戻しが symlink を実ファイルに置き換えて壊すのを防ぐ(symlink/実体どちらでも安全)。
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

# mktemp ファイルを mv すると対象の権限が 600 に置き換わる(statusline.sh の実行ビット喪失など)。
# cat による上書きなら inode・権限とも保持される。
safe_write() {  # $1=tmpfile $2=target
  cat "$1" > "$(resolve_real "$2")" && rm -f "$1"
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

# 既存 statusline が stdin の JSON をどの変数名で読んでいるかを検出する(例: input=$(cat))。
# キャプチャ行はこの変数を参照するため、検出できなければ install を中断する
# (黙って動かないブロックを追記しないため)。
detect_stdin_var() {  # $1=statusline file
  # BSD sed(macOS)は \b 非対応なので使わない
  sed -nE 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)="?\$\(cat[^A-Za-z0-9_].*/\1/p; s/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)="?\$\(cat\)"?$/\1/p' "$1" | head -1
}

emit_block() {  # $1=stdin変数名
  sed "s/__RLGVAR__/$1/g" <<'BLOCK'
# >>> rate-limit-guard (managed; remove with setup.sh uninstall) >>>
# 既存 statusline が読み込んだ $__RLGVAR__(stdinのJSON)から rate_limits を独自stateへ書き出す。
# tmp→mv のアトミック書き込み(チェッカーが書き込み途中の断片を読まないため)。
_rlg=$(printf '%s' "${__RLGVAR__-}" | jq -c '.rate_limits // empty' 2>/dev/null)
if [ -n "$_rlg" ]; then
  _rlg_dir="${RL_STATE_DIR:-$HOME/.claude/rate-limit-guard}"
  mkdir -p "$_rlg_dir" 2>/dev/null
  if printf '%s' "${__RLGVAR__-}" | jq -c '.rate_limits + {captured_at: (now|floor)}' > "$_rlg_dir/state.json.tmp.$$" 2>/dev/null; then
    mv -f "$_rlg_dir/state.json.tmp.$$" "$_rlg_dir/state.json" 2>/dev/null
  else
    rm -f "$_rlg_dir/state.json.tmp.$$" 2>/dev/null
  fi
fi
# <<< rate-limit-guard <<<
BLOCK
}

install_capture() {
  local t var; t="$(resolve_statusline)"
  if [ ! -f "$t" ]; then echo "  [capture] statusline 未検出: $t (RLG_STATUSLINE_FILE で指定可)"; return 1; fi
  if grep -q "rate-limit-guard" "$t"; then echo "  [capture] 既に導入済み: $t"; return 0; fi
  var="$(detect_stdin_var "$t")"
  if [ -z "$var" ]; then
    echo "  [capture] 中断: $t に stdin を読む行(例: input=\$(cat))が見つからない。"
    echo "            キャプチャ行はその変数を参照するため、このままでは動作しない。"
    echo "            statusline が stdin の JSON を変数に読み込む形であることを確認してから再実行を。"
    return 1
  fi
  cp "$t" "$t.rlguard.bak.$(ts)"
  [ -n "$(tail -c1 "$t")" ] && printf '\n' >> "$t"
  emit_block "$var" >> "$t"
  echo "  [capture] 追記完了: $t (stdin変数: \$$var, コマンドは非変更)"
}

uninstall_capture() {
  local t; t="$(resolve_statusline)"
  [ -f "$t" ] || { echo "  [capture] 対象なし: $t"; return 0; }
  if ! grep -q "rate-limit-guard" "$t"; then echo "  [capture] 追記なし: $t"; return 0; fi
  cp "$t" "$t.rlguard.bak.$(ts)"
  local tmp; tmp="$(mktemp)"
  awk -v s=">>> rate-limit-guard" -v e="<<< rate-limit-guard" '
    $0 ~ s {skip=1} skip==0 {print} $0 ~ e {skip=0}' "$t" > "$tmp" && safe_write "$tmp" "$t"
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
  ' "$SETTINGS" > "$tmp" && safe_write "$tmp" "$SETTINGS"
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
  ' "$SETTINGS" > "$tmp" && safe_write "$tmp" "$SETTINGS"
  echo "  [hook] PreToolUse から除去"
}

case "${1:-status}" in
  install)
    # worktree 内のパスを settings.json に焼き込むと、worktree 削除後に hook が
    # 毎ツール呼び出しで exit 127 になる。本体(マージ後)のパスから install すること。
    case "$SELF_DIR" in
      */worktrees/*)
        if [ "${RLG_FORCE:-}" != "1" ]; then
          echo "中断: スキルが worktree 内にある ($SELF_DIR)。"
          echo "worktree 削除後に hook のパスが壊れるため、マージ後の本体パスから install すること。"
          echo "(意図的なら RLG_FORCE=1 で強行可)"
          exit 1
        fi ;;
    esac
    mkdir -p "$STATE_DIR"
    rc=0
    echo "rate-limit-guard をインストール:"
    install_capture || rc=1
    install_hook || rc=1
    if [ "$rc" -eq 0 ]; then
      echo "完了。statusLine のコマンドは差し替えていません。"
      echo "次の statusline 更新(最初のAPI応答)で $STATE_DIR/state.json が生成されます。"
      echo "しばらくしてから 'setup.sh status' で生成を確認してください。"
    else
      echo "一部失敗。上のメッセージを確認してください。"
    fi
    exit "$rc"
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
    echo "状態ファイル:    $STATE_DIR/state.json $([ -f "$STATE_DIR/state.json" ] && echo '(あり・最終更新 '"$(stat -f %Sm "$STATE_DIR/state.json" 2>/dev/null || stat -c %y "$STATE_DIR/state.json" 2>/dev/null)"')' || echo '(なし)')"
    ;;
  *)
    echo "usage: setup.sh [install|uninstall|status]" >&2; exit 2 ;;
esac
