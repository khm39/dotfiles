#!/usr/bin/env bash
# PreToolUse hook for Edit/Write/NotebookEdit.
# 複数Claudeセッションでの作業ツリー衝突を避けるため、
# git管理下リポジトリの「メインworktree内のファイル」を編集しようとした場合にブロックする。
# 判定は cwd ではなく「編集対象ファイルのパス」で行う。
#   - 対象がgit管理外（/tmp や ~/.claude/jobs などの一時ファイル）       -> 許可
#   - 対象がリンクworktree配下（.claude/worktrees/... など）            -> 許可
#   - 対象がメインworktree内                                          -> ブロック
# claude/CLAUDE.md の「Worktree運用」セクションを参照。

set -u

payload=$(cat)

if [ "${CLAUDE_BYPASS_WORKTREE:-}" = "1" ]; then
  exit 0
fi

cwd=""
target=""
if command -v jq >/dev/null 2>&1; then
  cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)
  target=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null || true)
fi
[ -z "${cwd:-}" ] && cwd="${PWD:-$(pwd)}"

# 対象パスが特定できないときはフェイルオープン（ブロックしない）。
if [ -z "${target:-}" ]; then
  echo "[enforce-worktree] 編集対象パスを特定できませんでした。安全側に倒さずスキップします。" >&2
  exit 0
fi

# 相対パスは cwd 基準で絶対化。
case "$target" in
  /*) ;;
  *) target="$cwd/$target" ;;
esac

# 新規ファイルで対象ディレクトリが未作成なことがあるため、存在する最近接の祖先まで遡る。
target_dir=$(dirname "$target")
while [ -n "$target_dir" ] && [ "$target_dir" != "/" ] && [ ! -d "$target_dir" ]; do
  target_dir=$(dirname "$target_dir")
done

# 対象がgit管理外なら許可（/tmp、~/.claude/jobs などの一時ファイル）。
if ! git -C "$target_dir" rev-parse --git-dir >/dev/null 2>&1; then
  exit 0
fi

# ディレクトリへ実際に降りてパスを正規化（シンボリックリンク差を吸収）するヘルパ。
abs_dir() (
  cd "$1" 2>/dev/null && cd "$2" 2>/dev/null && pwd -P
)

git_dir=$(git -C "$target_dir" rev-parse --git-dir 2>/dev/null || true)
common_dir=$(git -C "$target_dir" rev-parse --git-common-dir 2>/dev/null || true)
git_dir_abs=$(abs_dir "$target_dir" "$git_dir")
common_dir_abs=$(abs_dir "$target_dir" "$common_dir")

# リンクworktreeでは git-dir != git-common-dir。一致するのはメインworktreeのみ。
if [ -n "$git_dir_abs" ] && [ "$git_dir_abs" != "$common_dir_abs" ]; then
  exit 0
fi

cat >&2 <<MSG
[enforce-worktree] メインworktree内のファイル編集をブロックしました。

複数のClaudeセッションが同一リポジトリのメイン作業ツリーを同時に編集すると git作業ツリーが衝突します。
まず EnterWorktree ツールを呼んで隔離worktreeに移動してから編集してください。

編集対象 : $target
ルール   : claude/CLAUDE.md の「Worktree運用」セクション
緊急回避 : シェル側で CLAUDE_BYPASS_WORKTREE=1 を設定すると、このhookを無効化できます
MSG
exit 2
