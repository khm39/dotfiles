---
name: repo-explainer
description: Scans a repository and produces a structured summary — app purpose, tech stack, features, project structure, and suggested deep-dive topics. Use this skill whenever a user wants to understand the big picture of a codebase: what the project does, how it's built, and how it's organized. Trigger on requests like "what does this repo do", "explain this project", "codebase overview", "walk me through this code", "このリポジトリ何", "プロジェクトの概要", "全体像を掴みたい", "コードベースの説明". Also trigger when a user has just cloned, forked, or been assigned an unfamiliar repository and needs to get oriented, or when they're onboarding onto a new project, inheriting code from a predecessor, or preparing to review an unknown codebase. Do NOT trigger for specific file edits, bug fixes, feature additions, dependency updates, or CI/CD changes — those are implementation tasks, not codebase comprehension.
---

# Repo Explainer

ユーザーが初めて見るリポジトリを素早く理解できるよう、まず簡潔なサマリーを出し、そこからユーザーが興味のある部分を深掘りできるようにする。

## なぜこのアプローチか

コードベースの情報を一度に全部出すと、ユーザーは圧倒されてしまう。まず全体像をつかんでもらい、そこから興味のあるところを選んで掘り下げてもらう方が、理解が定着しやすい。美術館のガイドのように — まずフロアマップを見せてから、どの展示を見たいか選んでもらう。

## Step 1: リポジトリをスキャンする

以下の順序で情報源を確認する。**上にあるものほど優先度が高い**。

### 1-A. 既存のガイダンスファイル（最優先）

これらがあればプロジェクト理解が一気に進む。スキャン前に必ず確認する：

- `CLAUDE.md` / `AGENTS.md` / `.cursorrules` / `.github/copilot-instructions.md` — AI向けの既存指示
- `README.md` / `README.rst` / `docs/README.md` — プロジェクトの目的・使い方・全体像

READMEからは以下を抽出する：プロジェクト名、概要、技術スタック、ビルド/実行手順、ライセンス。アーキテクチャや設計判断の記述があれば、深掘りトピック候補として控える。

### 1-B. モノレポ検出

以下のファイルがあればモノレポ。ワークスペース構造を把握してからサマリを組み立てる：

- `pnpm-workspace.yaml` — pnpm workspaces
- `package.json` の `workspaces` フィールド — npm/yarn workspaces
- `turbo.json` — Turborepo
- `lerna.json` — Lerna
- `nx.json` — Nx
- `Cargo.toml` の `[workspace]` セクション — Rust workspaces
- `go.work` — Go workspaces

各ワークスペース/パッケージの役割を把握してからサマリに含める。

### 1-C. ルート設定ファイル

- **言語/FW**: `package.json`, `Cargo.toml`, `go.mod`, `pyproject.toml`, `Gemfile`, `composer.json`, `pom.xml`, `build.gradle`
- **コンテナ/インフラ**: `Dockerfile`, `docker-compose.yml`, `terraform/`, `k8s/`
- **CI/CD**: `.github/workflows/`, `.gitlab-ci.yml`, `.circleci/`
- **ビルド/タスク**: `Makefile`, `justfile`, `Taskfile.yml`

### 1-D. ディレクトリ構成

トップレベルと、主要ディレクトリ（`src/`, `app/`, `lib/` 等）の1階層下を把握する。

**`.gitignore` を尊重する** — `node_modules/`, `target/`, `dist/`, `build/`, `.venv/`, `__pycache__/` などの生成物・依存物は読まない。

### 1-E. エントリポイントとAPI

- **エントリポイント**: main / index / アプリのブートストラップファイル
- **API定義**: ルートファイル、GraphQLスキーマ、OpenAPI仕様、Protobuf

### 1-F. git logで活発な領域を把握

`git log --oneline -20` や `git log --since="1 month ago" --name-only --pretty=format:` で最近の変更箇所を把握すると、深掘りトピックの優先順位判断に使える。

### 巨大リポへの戦略

トップレベルディレクトリが20を超える、またはモノレポでワークスペースが10以上ある場合：

1. 既存のガイダンスファイル（CLAUDE.md, README）に最大限頼る
2. 全体を等しくスキャンせず、命名から「主要そう」なディレクトリ（`apps/`, `packages/core`, `services/api` など）を優先
3. それでも厳しい場合、ユーザーに「特に知りたいエリアはありますか？」と確認する

すべてのファイルを読む必要はない。戦略的に拾い読みして、プロジェクトの「形」を掴むことが目的。

## Step 2: サマリーを出力する

以下のフォーマットで構造化されたサマリーを出力する。**ユーザーの会話言語（または `settings.json` の `language`）に合わせて書く**。技術用語・ライブラリ名は原文のまま。

~~~markdown
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

**プロジェクト構成**:

```
project-name/
├── src/          # アプリのエントリポイントとルーティング
├── lib/          # ドメインロジックと共通ユーティリティ
├── tests/        # 単体・統合テスト
└── docs/         # 設計ドキュメントとAPI仕様
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
~~~

### サマリーのガイドライン

- **具体的に書く。** 「JWTを使ったユーザー認証」のように書く。「認証機能がある」のような曖昧な表現はしない。
- **実際の技術名を書く。** 「Next.js 14 の App Router」のように具体的に。「Reactベースのフレームワーク」のような抽象表現は避ける。
- **機能一覧はユーザー視点で書く。** アプリを使う人が体験する機能を書く。内部実装の詳細は深掘りに回す。
- **長さは画面1〜2スクロール程度に収める。** 30行を目安に、必要なら40行まで許容。それを超えるなら詳細は深掘りに回す。
- **役割コメントは具体的に。** `src/ # アプリのエントリポイントとルーティング` のように、何が入っているか分かる粒度で。空欄や `# ...` のままにしない。
- **プロジェクト構成はツリー形式で書く。** 主要なディレクトリに `# コメント` で役割を添える。
- **モノレポは構造を反映。** ワークスペースごとの役割を簡潔に書く（例: `apps/web — Next.jsフロントエンド`）。
- **深掘りトピックはリポジトリに合わせる。** DBがなければ「DBスキーマ」は提案しない。プロジェクト固有のトピック（例: 「プラグインシステム」「MLパイプライン」「決済フロー」）を追加する。

### 複数言語/技術が混在するリポの順序

ユーザーが「動かす側」に近い順序で書く：

- **フルスタックWebアプリ**: フロント → バックエンド → DB/インフラ
- **CLI + 内部ライブラリ**: CLI → ライブラリ
- **マイクロサービス群**: ゲートウェイ/エントリ → 個別サービス
- **アプリ + SDK**: アプリ → SDK

ユーザーの関心が明らかにバックエンド寄りなら順序を入れ替える。

### スキャン中のエラーケース

- **READMEも設定ファイルもない雑然としたリポ** — ディレクトリ構造とファイル拡張子から推測する。「主要な設定ファイルが見つからなかったため、推測ベースで説明します」と前置きする。
- **空に近いリポ** — 「このリポジトリはまだほぼ空です。何から始めたいですか？」とユーザーに次のステップを提案する。
- **読めないファイル（権限・バイナリ）** — 止まらずに「○○は読めなかったので省略します」と添えてサマリを進める。

## Step 3: ユーザーのリクエストに応じて深掘りする

ユーザーが特定のトピックについて聞いてきたら、コードベースの該当部分をより詳しく探索して説明する：

- **どう動いているか** — 実装のアプローチ、関係する主要ファイル
- **なぜそうなっているか** — コードから読み取れる設計判断
- **主要ファイル** — そのトピックで最も重要なファイルのパス（ユーザーが開けるように）

### 深掘りの粒度

- **コード引用は3〜10行程度に絞る。** 長すぎる引用は流し読まれる。意図が分かる最小限を切り出す。
- **`path/to/file.ts:42` 形式の行番号付き参照** を使い、ユーザーが自分で見に行けるようにする。
- **複雑なフローはmermaid等の図を活用する** — シーケンス図（リクエスト処理）、フロー図（状態遷移）、関係図（モジュール依存）など。コードだけでは伝わりにくい構造に有効。
- ユーザーの質問に応じて深さや技術レベルを調整する。「認証どうなってる？」なら具体的なウォークスルー、「認証の方針は？」ならハイレベルな説明。

深掘り回答の最後に、自然につながる関連トピックを提案する（例：APIルートを説明した後は「データベースモデルやミドルウェアも見てみますか？」）。

## してはいけないこと

- **全ファイルを読み上げない。** サマリは"地図"であって"全冊朗読"ではない。
- **テストコードを詳細に説明しない。** ユーザーから明示的に求められない限り、テストは深掘り対象外。
- **生成物・依存物を読みに行かない。** `.gitignore` で除外されている領域（`node_modules/`, `target/`, `dist/` 等）には触らない。
- **不確かな推測を断定形で書かない。** 「〜と思われる」「READMEを見る限り〜」のように出典を明示する。
- **30行を超えるサマリを最初から出力しない。** 圧倒される原因になる。長くなりそうなら深掘りに回す。
- **ユーザーが選ぶ前に勝手に深掘りしない。** Step 2 のサマリで止まり、ユーザーの選択を待つ。
