---
name: repo-explainer
description: Scans a repository and produces a structured summary — app purpose, tech stack, features, project structure, and suggested deep-dive topics. Use this skill whenever a user wants to understand the big picture of a codebase: what the project does, how it's built, and how it's organized. Trigger on requests like "what does this repo do", "explain this project", "codebase overview", "walk me through this code", "このリポジトリ何", "プロジェクトの概要", "全体像を掴みたい", "コードベースの説明". Also trigger when a user has just cloned, forked, or been assigned an unfamiliar repository and needs to get oriented, or when they're onboarding onto a new project, inheriting code from a predecessor, or preparing to review an unknown codebase. Do NOT trigger for specific file edits, bug fixes, feature additions, dependency updates, or CI/CD changes — those are implementation tasks, not codebase comprehension.
---

# Repo Explainer

ユーザーが初めて見るリポジトリを素早く理解できるよう、まず簡潔なサマリーを出し、そこからユーザーが興味のある部分を深掘りできるようにする。

## なぜこのアプローチか

コードベースの情報を一度に全部出すと、ユーザーは圧倒されてしまう。まず全体像をつかんでもらい、そこから興味のあるところを選んで掘り下げてもらう方が、理解が定着しやすい。美術館のガイドのように — まずフロアマップを見せてから、どの展示を見たいか選んでもらう。

## Step 1: リポジトリをスキャンする

リポジトリの構造を探索して全体像を把握する。以下の情報源を優先的に確認する：

- **ルートファイル**: README, package.json, Cargo.toml, go.mod, pyproject.toml, docker-compose.yml, Makefile など
- **ディレクトリ構成**: トップレベルのフォルダと、主要ディレクトリ（src/, app/, lib/ 等）の1階層下
- **エントリポイント**: main ファイル、index ファイル、アプリのブートストラップファイル
- **設定ファイル**: CI/CD設定、環境変数テンプレート、インフラ設定
- **API定義**: ルートファイル、GraphQLスキーマ、OpenAPI仕様

すべてのファイルを読む必要はない。戦略的に拾い読みして、プロジェクトの「形」を掴むことが目的。

## Step 2: サマリーを出力する

以下のフォーマットで構造化されたサマリーを出力する。**すべて日本語で書く**（技術用語やライブラリ名はそのまま）。

```
## [アプリ/プロジェクト名]

**概要**: このアプリが何をするもので、誰のためのものか。1〜2文で。

**技術スタック**:
- 言語: ...
- フレームワーク: ...
- データベース: ...
- その他の主要技術: ...

**主な機能**:
- 機能1 — 簡潔な説明
- 機能2 — 簡潔な説明
- ...

**プロジェクト構成**:
```
project-name/
├── src/          # ...
├── lib/          # ...
├── tests/        # ...
└── docs/         # ...
```

---

以下のトピックについて、さらに詳しく聞くことができます。気になるものがあればどうぞ:

- アーキテクチャとデータフロー
- APIエンドポイントの設計
- データベーススキーマとモデル
- 認証・認可の仕組み
- テスト戦略
- ビルドとデプロイのパイプライン
- [このリポジトリ固有のトピック]
```

### サマリーのガイドライン

- **具体的に書く。** 「JWTを使ったユーザー認証」のように書く。「認証機能がある」のような曖昧な表現はしない。
- **実際の技術名を書く。** 「Next.js 14 の App Router」のように具体的に。「Reactベースのフレームワーク」のような抽象表現は避ける。
- **機能一覧はユーザー視点で書く。** アプリを使う人が体験する機能を書く。内部実装の詳細は深掘りに回す。
- **1画面に収める。** サマリー全体が1画面に収まる程度の長さにする。30行を超えそうなら、詳細は深掘りに回す。
- **プロジェクト構成はツリー形式で書く。** 箇条書きではなく、ディレクトリツリー（`├──` `└──`）を使って視覚的に分かりやすくする。主要なディレクトリに `# コメント` で役割を添える。
- **深掘りトピックはリポジトリに合わせる。** データベースがなければ「データベーススキーマ」は提案しない。そのプロジェクト固有のトピック（例：「プラグインシステム」「MLパイプライン」「決済フロー」）を追加する。

## Step 3: ユーザーのリクエストに応じて深掘りする

ユーザーが特定のトピックについて聞いてきたら、コードベースの該当部分をより詳しく探索して説明する：

- **どう動いているか** — 実装のアプローチ、関係する主要ファイル
- **なぜそうなっているか** — コードから読み取れる設計判断
- **主要ファイル** — そのトピックで最も重要なファイルのパスを示す（ユーザーが開けるように）

ユーザーの質問に応じて深さや技術レベルを調整する。「認証どうなってる？」なら具体的なウォークスルーを、「認証の方針は？」ならハイレベルな説明を。

深掘り回答の最後に、自然につながる関連トピックを提案する（例：APIルートを説明した後は「データベースモデルやミドルウェアも見てみますか？」）。
