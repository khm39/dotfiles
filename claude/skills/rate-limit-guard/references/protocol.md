# 待機・再開プロトコル詳細

`SKILL.md` の「待つ / 再開」を実行する際の具体手順とエッジケース。

## チェックポイントの書式

待機前に `~/.claude/rate-limit-guard/checkpoint.md` を上書きで残す。次のセッション/起床がこれだけ読めば再開できる粒度にする:

```markdown
# Checkpoint — <タスク名>  (saved: <人間可読な時刻>)

## ゴール
<このタスク全体で達成したいこと>

## 完了したこと
- <箇条書き>

## 次にやること(再開時の最初の一手)
1. <具体的な次アクション>

## 触ったファイル / WIPコミット
- <ファイル一覧、または `git log -1` のハッシュ>

## 待機理由
- limiting_window: five_hour, used_percentage: 92, resets_at: <時刻>
```

可能なら WIP コミットも併用する(最も確実な復元手段)。コミットメッセージは日本語で。

## 待機の仕方(5時間枠)

`resets_in_seconds` を R とする。リセット判定は **現在時刻 ≥ `resets_at`** で行う。待機中は API 呼び出しが無く `used_percentage` が更新されないため、使用率の低下を待ってはいけない。

自動再開はセッションが開いている限り `/loop` 不要で動く。優先順:

### 1. 背景待機 + 自動再開(推奨・通常セッションで動く)

`Bash` を `run_in_background: true` で実行し、リセット時刻まで待つ until ループを回す。背景タスクは終了時に自動で再起動をかけるので、その通知で再開する。

```bash
target=$(( RESETS_AT + 60 ))           # RESETS_AT = check結果の resets_at(エポック秒)
until [ "$(date +%s)" -ge "$target" ]; do sleep 30; done
echo "RESET_REACHED"
```

- 前景 `sleep` はハーネスでブロックされるが、`run_in_background: true` の中の `sleep` は動く(実測確認済み)。
- 起こされたら「再開時のチェック」へ。**まだ `resets_at` 未到達なら同じ背景待機を張り直す**(背景タスクが途中で打ち切られても、これで確実に到達まで粘れる)。
- 1本の背景待機で済むので、キャッシュ再構築は実質1回。

### 2. Monitor(進捗表示・長時間向けの代替)

残り時間のハートビートを見たい、または待機が長くて背景待機の張り直しを避けたい場合:

```bash
target=$(( RESETS_AT + 60 ))
while [ "$(date +%s)" -lt "$target" ]; do
  echo "waiting... $(( (target - $(date +%s)) / 60 ))min left"; sleep 60
done
echo "RESET_REACHED"
```

`Monitor` の `timeout_ms` は最大3600000(1時間)。それより長い待機は `persistent: true`(TaskStop か到達で終了)。各行が通知になるのでハートビート間隔は粗め(60s〜)にする。

### 3. `/loop` 自走モードなら ScheduleWakeup でも可

ループで回している場合は各起床で `check-rate-limit.sh` を実行し、`action` に応じて `ScheduleWakeup(min(R + 60, 3600))` で次の起床を刻む(`delaySeconds` は [60,3600] クランプなので R>3600 は1時間刻み)。

### セッションを閉じる場合

背景待機・Monitor・`/loop` いずれもセッションに紐づくので、閉じると止まる。完全に閉じる前提なら `CronCreate`(`recurring:false`, `durable:true`)で `resets_at + 60秒` に再開プロンプトを仕込む(REPL がアイドルかつ Claude 起動中に発火)か、`checkpoint.md` を残して次回起動時に再開する運用にフォールバックする。設定変更を伴う場合はユーザー確認のうえで。

## 再開時のチェック

起床/再開したら、作業に戻る前に必ず:

1. `check-rate-limit.sh` を再実行。
2. `action == "continue"` を確認(まだ超過なら再待機)。
3. `source` と `fresh` を確認。`fresh: false` のまま判断が際どいときは、短く待って取り直す。
4. `checkpoint.md` を読み、「次にやること」から再開。

## 閾値とチューニング

- `RL_THRESHOLD`(既定90): 何%で発動するか。早めに切り上げたいなら 85 など。
- `RL_STALE_SECONDS`(既定180): 状態ファイルを「古い」とみなす秒数。
- これらは `check-rate-limit.sh` を呼ぶ際の環境変数で渡す。
