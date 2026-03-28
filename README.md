# Dotfiles

macOS 開発環境の設定ファイル管理リポジトリ

## セットアップ

```bash
git clone git@github.com:khm39/dotfiles.git ~/dotfiles
cd ~/dotfiles
./install.sh
```

## 構成

```
dotfiles/
├── install.sh              # セットアップスクリプト (zsh)
├── Brewfile                # Homebrew パッケージ一覧
├── zsh/
│   ├── .zshrc              # Zsh メイン設定
│   └── .zprofile           # ログインシェル設定
├── git/
│   ├── .gitconfig          # Git 設定
│   └── ignore              # グローバル gitignore
├── nvim/                   # Neovim 設定
│   ├── init.lua
│   ├── lazy-lock.json
│   └── lua/
│       ├── config/         # 基本設定・キーマップ・LSP
│       └── plugins/        # プラグイン設定
└── claude/
    ├── CLAUDE.md           # グローバルルール
    ├── settings.json       # Claude Code 設定
    ├── statusline.sh       # カスタムステータスライン
    └── skills/             # カスタムスキル
```

## セットアップ後の手動作業

1. ターミナルを再起動
2. GPG キーをインポート (`gpg --import`)
3. 1Password にログイン
4. `gh auth login` で GitHub にログイン

## Brewfile の更新

```bash
brew bundle dump --file=~/dotfiles/Brewfile --force
```
