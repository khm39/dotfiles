---
name: codex
description: >
  OpenAI Codex を MCP サーバ（codex mcp-server）経由で別エージェントとして呼び出し、
  実装タスクの委譲やコードレビュー（セカンドオピニオン）を行うスキル。
  mcp__codex__codex / mcp__codex__codex-reply ツールを使う。
  以下のような場面では必ずこのスキルを使うこと：
  - 「Codexに実装させて」「Codexに任せて」「Codexに書かせて」「Codexで直して」
  - 「Codexにレビューさせて」「Codexの意見を聞いて」「Codexに（別の頭で）セカンドオピニオンが欲しい」
  - 「Codexに調べさせて」「Codexに聞いて」「Codexはどう思う？」
  - 「別のモデル（GPT/Codex）にやらせて」「もう一つのエージェントに確認させて」
  - 自己完結したコーディングタスクを別エージェントにオフロードしたいとき全般
  - Claude 自身の実装・判断を Codex に検証・対比させたいとき
  ユーザーが「MCP」と明示しなくても、Codex（や別モデル）への委譲・相談・レビュー依頼であればこのスキルを使う。
  逆に、Codex を指定しない単なる「レビューして」「コードレビューして」は通常のレビュー手段に任せ、このスキルは発動しない。
---

# Codex 委譲スキル

OpenAI Codex を **MCP サーバ経由** で独立したコーディングエージェントとして呼び出し、
実装の委譲・コードレビュー・調査相談を任せるスキル。Codex は Claude とは別のモデル
（GPT 系）で動くため、実装の分担や「別の頭での見直し（セカンドオピニオン）」に向く。

使うツールは 2 つ：

- `mcp__codex__codex` — 新しい Codex セッションを開始してタスクを実行する。`prompt` が必須。
- `mcp__codex__codex-reply` — 既存セッションを継続する。`prompt` と `threadId` が必須。

## Step 0: 前提を確認する

Codex セッションを始める前に、ツールと認証が揃っているかを確認する。

### MCP ツールが使えるか

`mcp__codex__codex` が現在のセッションで利用可能かを確認する。使えるなら以降の手順へ進む。

使えない場合、原因はほぼ次のどちらか：

1. **codex MCP サーバが未登録** — `claude mcp list` に `codex` が無い。次で登録する。
   ```bash
   # 全プロジェクトで使えるようにする場合（推奨）
   claude mcp add -s user codex -- codex mcp-server
   # 現在のプロジェクトだけで使う場合
   claude mcp add codex -- codex mcp-server
   ```
2. **登録済みだがこのセッションにツールが読み込まれていない** — MCP ツールはセッション開始時に接続される。登録直後は、ユーザーにセッションの再起動または `/mcp` での再接続を依頼する。ツールが読み込まれていない状態では呼べないため、ここはユーザー操作が必要になる。

`claude mcp list` で `codex: codex mcp-server - ✓ Connected` を確認できればよい。

### 認証とログインの確認

Codex MCP サーバは `codex login` で保存された認証情報を使う。MCP 呼び出しが認証エラー（未ログイン）
で失敗した場合は、**勝手にログインさせず、まずユーザーに選んでもらう**。`AskUserQuestion` で次の二択を出す：

- **Codex にログインして使う** — `codex login`（対話ログインなので、プロンプトで `! codex login` を実行してもらう）を案内し、ログイン完了後に同じ呼び出しを再試行する。
- **Codex を使わない** — 委譲を取りやめる。Claude 自身で対応するか、どう進めたいかをユーザーに確認する。

ログインはセッションをまたいで保持されるので、一度ログインできれば以降は聞き直さない。認証のための
`codex login` 以外に Codex の CLI をユーザーへ実行させない。

**タスクの実行・レビュー・調査はすべて MCP ツール経由で行う。** `codex exec` / `codex review` など
Codex の CLI をタスク遂行のために実行しない（認証セットアップを除く）。

## 基本方針

**Codex は会話履歴を一切引き継がない独立エージェント。** Claude のこれまでのやり取り・
開いているファイル・暗黙の前提は見えない。だから `prompt` には必要な文脈を**すべて**書く：
何をしてほしいか、対象ファイル・ディレクトリ、満たすべき条件、完了の定義。曖昧な指示は
曖昧な結果を生む。

呼び出しの基本形（実装委譲の例）：

```
mcp__codex__codex(
  prompt: "<タスクの完全な説明と完了条件>",
  cwd: "<対象リポジトリの絶対パス>",
  sandbox: "workspace-write",
  approval-policy: "never"
)
```

- **`cwd` は毎回明示する。** Codex はここを作業ルートにする。worktree で作業中なら worktree のパスを渡す。
- 戻り値の構造は次の通り。Codex の**最終メッセージ**は `content`、継続用の **`threadId`** は `structuredContent.threadId` に入る：
  ```json
  { "content": [{ "type": "text", "text": "<最終メッセージ>" }],
    "structuredContent": { "threadId": "<...>", "content": "<最終メッセージ>" } }
  ```
  `threadId` は継続に使うので控えておく。
- Codex は内部で自分の判断でシェルコマンド・git を実行する（サンドボックス内）。Claude 側で逐一指示する必要はない。
- **Codex の出力を鵜呑みにしない。** 委譲後は必ず `git diff` / テストで実際の変更を検証し、要点をユーザーへ自分の言葉で要約する。

## 権限（sandbox / approval-policy）の選び方

権限はタスクに応じて選ぶ。原則は「目的を達成できる最小権限」。

| タスク | `sandbox` | 理由 |
|---|---|---|
| レビュー・調査・相談（読むだけ） | `read-only` | ファイルを書き換えさせない。最も安全 |
| 実装委譲（ファイル編集が必要） | `workspace-write` | 作業ディレクトリ内の編集を許可 |
| ネットワークや作業外への書き込みが必須 | `danger-full-access` | 原則避ける。**ユーザーに確認してから**のみ |

**`approval-policy` は `never` を基本にする。** MCP 経由では Codex が出す承認プロンプトに
人が応答できない（承認待ちで止まってしまう）。`never` にすると、サンドボックスが禁じた操作は
承認を求めずにそのまま失敗し、Codex はそのエラーを見て別の方法を試す。安全装置は
`approval-policy` ではなく `sandbox` が担う、と理解するとよい。

注意点：

- `workspace-write` は**デフォルトでネットワークが無効**。`npm install` 等の依存取得を伴うタスクは失敗しうる。必要なら `config: { sandbox_workspace_write: { network_access: true } }` を渡すか、ユーザー確認の上 `danger-full-access` を使う。
- `danger-full-access` は承認もサンドボックスも無い。使う前に必ずユーザーへ理由とともに確認する。

## 実装タスクの委譲

Codex に実装を任せ、結果を Claude が検証する流れ。

1. **完全な指示で `mcp__codex__codex` を呼ぶ。** `sandbox: "workspace-write"`、`approval-policy: "never"`、`cwd` を指定。`prompt` には対象・要件・完了条件・テスト方法まで含める。
2. **戻り値（最終メッセージ）と `threadId` を控える。**
3. **実際の変更を検証する。** `git status` / `git diff` で Codex が何を変えたか確認し、テストやビルドを走らせる。Codex の自己申告だけで「完了」と判断しない。
4. **修正が要れば `mcp__codex__codex-reply` で継続する**（`threadId` と追加指示を渡す）。文脈を再送しなくてよい。
5. ユーザーへは、Codex が何をしたか・diff の要点・検証結果を自分の言葉で報告する。

**Example:**
Input（ユーザー）: 「`src/utils/date.ts` に、ISO文字列を「YYYY年M月D日」形式に変換する関数 `formatJaDate` をCodexに追加させて。テストも書いて」
Action:
```
mcp__codex__codex(
  prompt: "Add a function `formatJaDate(iso: string): string` to src/utils/date.ts that converts an ISO 8601 string to the Japanese format 'YYYY年M月D日'. Also add unit tests in the existing test file for this module. Match the file's existing code style. Run the test suite and make sure it passes before finishing.",
  cwd: "/abs/path/to/repo",
  sandbox: "workspace-write",
  approval-policy: "never"
)
```
その後 `git diff src/utils/date.ts` とテスト結果を確認し、要約して報告。

## コードレビュー / セカンドオピニオン

Codex に「別の頭」で見てもらう用途。Codex には書き換えさせず、指摘だけ受け取る。

1. **`sandbox: "read-only"`、`approval-policy: "never"` で `mcp__codex__codex` を呼ぶ。**
2. `prompt` でレビュー対象と観点を指定する。Codex は自分で `git diff` を実行できるので、未コミット差分のレビューなら「review the uncommitted changes」と伝えればよい。
3. 返ってきた指摘を**そのまま採用せず**、Claude 側で妥当性を判断してからユーザーへ整理して伝える。誤検知や的外れな指摘もありうる。

**Example:**
Input: 「いまの変更、Codexにもレビューさせて」
Action:
```
mcp__codex__codex(
  prompt: "Review the uncommitted changes in this repository. Focus on correctness bugs, edge cases, and security issues. List findings grouped by severity, each with file:line and a concrete fix. If you find nothing serious, say so.",
  cwd: "/abs/path/to/repo",
  sandbox: "read-only",
  approval-policy: "never"
)
```

補足：重大度ごとに整理された出力（`[P1]`/`[P2]` のような形）が欲しいときは、`prompt` でそう指示すれば
よい（上の例のように "List findings grouped by severity" など）。レビューも含め、Codex の利用は
常に MCP ツール経由で行う。

## 出力の扱いと失敗検知

- `mcp__codex__codex` の呼び出しは **Codex がタスクを終えるまでブロックする**。大きめの実装は数分かかることがある。
- 戻り値の最終メッセージが**空でないこと**、Codex が「できなかった」と報告していないかを確認してから「完了」と判断する。`approval-policy: "never"` では拒否された操作が静かに失敗するため、最終メッセージに `blocked` / `permission denied` / `できなかった` 等の文言があれば `sandbox` 設定を見直してから再実行する。サンドボックスにブロックされた実行は、見かけ上は成功に見えることがある。
- **一時的なネットワークエラー**（`Network is unreachable`、websocket の再接続失敗など）が起きることがある。その場合は 1 回リトライする。繰り返すなら接続・認証を疑う。

## 継続（threadId）

複数ターンのやり取りは `mcp__codex__codex-reply` を使う：

```
mcp__codex__codex-reply(
  threadId: "<最初のcodex呼び出しで返ったthreadId>",
  prompt: "<追加の指示>"
)
```

`threadId` を渡すことで Codex 側の文脈（それまでの作業）を保ったまま続けられる。最初の `codex`
呼び出しの戻り値から `threadId` を必ず控えておくこと。

## その他

- **モデル指定**：特定モデルを使わせたいときは `model`（例 `"gpt-5.2-codex"`）を渡す。通常は省略でよい。
- **コストと時間**：Codex 呼び出しは別途トークン・時間を消費する。小さな確認や Claude 単独で十分なタスクにまで委譲しない。委譲が活きるのは、独立性の高いまとまった作業や、別モデルの視点が欲しいとき。
- **git リポジトリ外**：Codex は git リポジトリ前提で動く部分がある。リポジトリ外で実行する必要があれば、その旨を `prompt` で明示する。
