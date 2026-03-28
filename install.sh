#!/usr/bin/env zsh
#
# dotfiles セットアップスクリプト
# Homebrew パッケージのインストールとシンボリックリンクの作成を行う

set -euo pipefail

readonly DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"

# State tracking
CHANGED=0
OK=0

#######################################
# 変更があったことを表示し、カウントを増やす
# Arguments:
#   $1 - 変更内容の説明
#######################################
changed() {
  echo "\033[0;33m[changed]\033[0m $1"
  (( CHANGED += 1 ))
}

#######################################
# 変更なしを表示し、カウントを増やす
# Arguments:
#   $1 - 確認内容の説明
#######################################
ok() {
  echo "\033[0;32m[ok]\033[0m      $1"
  (( OK += 1 ))
}

#######################################
# エラーメッセージを STDERR に出力する
# Arguments:
#   $1 - エラーメッセージ
#######################################
error() {
  echo "\033[0;31m[error]\033[0m   $1" >&2
}

#######################################
# ヘルプメッセージを表示する
#######################################
help() {
  cat << EOF
Usage: $0 [options...]
  Options:
    --help|-h        ヘルプを表示
    --verbose|-V     詳細出力
EOF
}

#######################################
# 実ファイルが既にある場合、diff を表示して対話的に解決する
# Arguments:
#   $1 - ソースパス
#   $2 - デスティネーションパス
# Returns:
#   0 - 上書き許可
#   1 - スキップ
#######################################
resolve_conflict() {
  local src="$1"
  local dest="$2"

  echo ""
  echo "\033[0;31m[conflict]\033[0m ${dest} に実ファイルが存在します"

  if [[ -d "${src}" ]]; then
    echo "--- diff (既存 vs dotfiles) ---"
    diff -r "${dest}" "${src}" 2>/dev/null || true
  else
    echo "--- diff (既存 vs dotfiles) ---"
    diff --color=always "${dest}" "${src}" 2>/dev/null || true
  fi

  echo ""
  echo "  b) バックアップして上書き"
  echo "  o) バックアップせず上書き"
  echo "  s) スキップ (何もしない)"
  echo ""

  while true; do
    read -r "choice?選択 [b/o/s]: "
    case "${choice}" in
      b)
        local backup
        backup="${dest}.bak.$(date +%Y%m%d%H%M%S)"
        mv "${dest}" "${backup}"
        changed "backup ${dest} -> ${backup}"
        return 0
        ;;
      o)
        rm -rf "${dest}"
        changed "overwrite ${dest}"
        return 0
        ;;
      s)
        ok "skip ${dest} (kept existing)"
        return 1
        ;;
      *)
        echo "b, o, s のいずれかを入力してください"
        ;;
    esac
  done
}

#######################################
# シンボリックリンクが正しければスキップ、違えば修正する
# Arguments:
#   $1 - ソースパス
#   $2 - デスティネーションパス
#######################################
ensure_link() {
  local src="$1"
  local dest="$2"

  mkdir -p "$(dirname "${dest}")"

  if [[ -L "${dest}" ]] && [[ "$(readlink "${dest}")" == "${src}" ]]; then
    ok "link ${dest}"
    return
  fi

  if [[ -L "${dest}" ]]; then
    rm "${dest}"
  elif [[ -e "${dest}" ]]; then
    resolve_conflict "${src}" "${dest}" || return
  fi

  ln -s "${src}" "${dest}"
  changed "link ${dest} -> ${src}"
}

#######################################
# ディレクトリが正しいパーミッションで存在することを保証する
# Arguments:
#   $1 - ディレクトリパス
#   $2 - パーミッション (optional)
#######################################
ensure_dir() {
  local dir="$1"
  local mode="${2:-}"

  if [[ -d "${dir}" ]]; then
    if [[ -n "${mode}" ]]; then
      local current
      current=$(stat -f "%Lp" "${dir}" 2>/dev/null \
        || stat -c "%a" "${dir}" 2>/dev/null)
      if [[ "${current}" != "${mode}" ]]; then
        chmod "${mode}" "${dir}"
        changed "chmod ${mode} ${dir}"
        return
      fi
    fi
    ok "dir ${dir}"
  else
    mkdir -p "${dir}"
    [[ -n "${mode}" ]] && chmod "${mode}" "${dir}"
    changed "mkdir ${dir}"
  fi
}

#######################################
# ファイルのパーミッションを保証する
# Arguments:
#   $1 - ファイルパス
#   $2 - パーミッション
#######################################
ensure_mode() {
  local file="$1"
  local mode="$2"

  local current
  current=$(stat -f "%Lp" "${file}" 2>/dev/null \
    || stat -c "%a" "${file}" 2>/dev/null)
  if [[ "${current}" == "${mode}" ]]; then
    ok "mode ${mode} ${file}"
  else
    chmod "${mode}" "${file}"
    changed "chmod ${mode} ${file}"
  fi
}

#######################################
# コマンドが存在することを確認する
# Arguments:
#   $1 - コマンド名
# Returns:
#   0 - コマンドが存在する
#   1 - コマンドが存在しない
#######################################
ensure_command() {
  local cmd="$1"
  if command -v "${cmd}" &>/dev/null; then
    ok "command ${cmd}"
    return 0
  else
    return 1
  fi
}

#######################################
# Homebrew のインストールとパッケージの同期
#######################################
task_homebrew() {
  echo ""
  echo "=== Homebrew ==="

  if ! ensure_command brew; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
    changed "install homebrew"
  fi

  if brew bundle check --file="${DOTFILES_DIR}/Brewfile" &>/dev/null; then
    ok "brew bundle"
  else
    brew bundle --file="${DOTFILES_DIR}/Brewfile"
    changed "brew bundle install"
  fi
}

#######################################
# シンボリックリンクの作成
#######################################
task_link() {
  echo ""
  echo "=== Symlinks ==="

  # Zsh
  ensure_link "${DOTFILES_DIR}/zsh/.zshrc"   "${HOME}/.zshrc"
  ensure_link "${DOTFILES_DIR}/zsh/.zprofile" "${HOME}/.zprofile"
  ensure_link "${DOTFILES_DIR}/zsh/.zshenv"   "${HOME}/.zshenv"

  # Git
  ensure_link "${DOTFILES_DIR}/git/.gitconfig" "${HOME}/.gitconfig"
  ensure_link "${DOTFILES_DIR}/git/ignore"     "${HOME}/.config/git/ignore"

  # Neovim
  ensure_link "${DOTFILES_DIR}/nvim" "${HOME}/.config/nvim"

  # Claude Code
  ensure_dir "${HOME}/.claude"
  ensure_dir "${HOME}/.claude/skills"
  ensure_link "${DOTFILES_DIR}/claude/settings.json"  "${HOME}/.claude/settings.json"
  ensure_link "${DOTFILES_DIR}/claude/statusline.sh"  "${HOME}/.claude/statusline.sh"
  ensure_mode "${HOME}/.claude/statusline.sh" "755"
  ensure_link "${DOTFILES_DIR}/claude/CLAUDE.md"             "${HOME}/.claude/CLAUDE.md"
  ensure_link "${DOTFILES_DIR}/claude/skills/repo-explainer" "${HOME}/.claude/skills/repo-explainer"
}

#######################################
# メインエントリーポイント
#######################################
main() {
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --help|-h)
        help
        exit 0
        ;;
      --verbose|-V)
        set -x
        ;;
      -*)
        error "不明なオプション: ${1}"
        help
        exit 1
        ;;
      *) ;;
    esac
    shift
  done

  echo "dotfiles setup: ${DOTFILES_DIR}"

  task_homebrew
  task_link

  echo ""
  echo "=== Summary ==="
  echo "\033[0;33m${CHANGED} changed\033[0m / \033[0;32m${OK} ok\033[0m"

  if (( CHANGED > 0 )); then
    echo ""
    echo "次のステップ:"
    echo "  1. ターミナルを再起動してください"
    echo "  2. GPGキーをインポートしてください"
    echo "  3. 1Passwordにログインしてください"
  fi
}

main "$@"
