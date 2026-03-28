# NeoVim
alias vim='nvim'

# Python Alias
alias python=python3

# Java
export JAVA_HOME="$(brew --prefix openjdk)"
export PATH="$JAVA_HOME/bin:$PATH"

# Homebrew zsh completions
export PATH="/opt/homebrew/share/zsh/site-functions:$PATH"

# SSH Agent Use GPG
export GPG_TTY=$(tty)
gpgconf --launch gpg-agent
export SSH_AUTH_SOCK="$(gpgconf --list-dirs agent-ssh-socket)"

# Android SDK
export ANDROID_HOME=$HOME/Library/Android/sdk
export PATH=$PATH:$ANDROID_HOME/emulator
export PATH=$PATH:$ANDROID_HOME/platform-tools

# Yarn
export PATH="$PATH:$HOME/.yarn/bin"

# PostgreSQL
export PATH="/opt/homebrew/opt/postgresql/bin:$PATH"

# Go
export PATH="$HOME/go/bin:$PATH"

# pnpm
export PNPM_HOME="$HOME/Library/pnpm"
case ":$PATH:" in
  *":$PNPM_HOME:"*) ;;
  *) export PATH="$PNPM_HOME:$PATH" ;;
esac

# Rust
. "$HOME/.cargo/env"

# Docker CLI completions
fpath=($HOME/.docker/completions $fpath)
autoload -Uz compinit
compinit

source $(brew --prefix)/share/zsh-autosuggestions/zsh-autosuggestions.zsh
