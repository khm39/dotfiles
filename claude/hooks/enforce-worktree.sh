#!/usr/bin/env bash
# PreToolUse hook for Edit/Write/NotebookEdit.
# 複数Claudeセッションでの作業ツリー衝突を避けるため、
# git管理下のリポジトリで main worktree から編集しようとした場合にブロックする。
# claude/CLAUDE.md の「Worktree運用」セクションを参照。

set -u

payload=$(cat)

cwd=""
if command -v jq >/dev/null 2>&1; then
  cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)
fi
[ -z "${cwd:-}" ] && cwd="${PWD:-$(pwd)}"

if [ "${CLAUDE_BYPASS_WORKTREE:-}" = "1" ]; then
  exit 0
fi

if ! git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
  exit 0
fi

case "$cwd" in
  */.claude/worktrees/*)
    exit 0
    ;;
esac

git_dir=$(git -C "$cwd" rev-parse --git-dir 2>/dev/null || true)
case "$git_dir" in
  *.git/worktrees/*)
    exit 0
    ;;
esac

cat >&2 <<MSG
[enforce-worktree] worktree外でのファイル編集をブロックしました。

複数のClaudeセッションが同一リポジトリで同時に編集すると git作業ツリーが衝突します。
まず EnterWorktree ツールを呼んで隔離worktreeに移動してから編集してください。

現在地 : $cwd
ルール : claude/CLAUDE.md の「Worktree運用」セクション
緊急回避: シェル側で CLAUDE_BYPASS_WORKTREE=1 を設定すると、このhookを無効化できます
MSG
exit 2
