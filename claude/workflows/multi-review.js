export const meta = {
  name: 'multi-review',
  description: 'ブランチ/PRの差分を5観点で並列レビューし、各指摘を敵対的に検証してから日本語レポートに統合する',
  whenToUse: '変更差分を複数観点(正確性/セキュリティ/性能/保守性/テスト)で徹底レビューしたいとき。引数にbase ref・PR番号・"staged"・"working"などを渡せる。',
  phases: [
    { title: 'Scope', detail: '差分範囲を確定し変更ファイルを収集' },
    { title: 'Review', detail: '観点ごとに並列でレビュー' },
    { title: 'Verify', detail: '各指摘を敵対的に検証' },
    { title: 'Report', detail: '確定指摘を日本語レポートに統合' },
  ],
}

const SEVERITIES = ['critical', 'high', 'medium', 'low', 'nit']

const SCOPE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    baseRef: { type: 'string', description: '比較基準のref(例: main, origin/main, HEAD~1)。作業ツリーのレビューなら "WORKING"。' },
    diffCommand: { type: 'string', description: '全レビュー担当が一字一句そのまま実行する単一の差分取得コマンド(例: "git diff main...HEAD")。' },
    diffScope: { type: 'string', description: 'レビュー対象範囲の説明(コミット済みのbase...HEADか、未コミット作業ツリーか、PR番号か等)。' },
    changedFiles: { type: 'array', items: { type: 'string' } },
    diffStat: { type: 'string' },
    isEmpty: { type: 'boolean' },
    note: { type: 'string' },
  },
  required: ['baseRef', 'diffCommand', 'diffScope', 'changedFiles', 'isEmpty'],
}

const FINDINGS_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          file: { type: 'string' },
          line: { type: 'string', description: '行番号または範囲(例: "42", "42-50")。不明なら空文字。' },
          severity: { type: 'string', enum: SEVERITIES },
          title: { type: 'string' },
          detail: { type: 'string' },
          suggestion: { type: 'string' },
        },
        required: ['file', 'severity', 'title', 'detail'],
      },
    },
  },
  required: ['findings'],
}

const VERDICT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    verdict: { type: 'string', enum: ['confirmed', 'downgrade', 'reject'], description: 'confirmed=妥当, downgrade=深刻度を下げて残す, reject=誤検知として除外' },
    adjustedSeverity: { type: 'string', enum: SEVERITIES },
    reasoning: { type: 'string' },
  },
  required: ['verdict', 'reasoning'],
}

const DIMENSIONS = [
  { key: 'correctness', label: '正確性・バグ', focus: 'ロジック誤り、境界条件、null/undefined、例外/エラー処理漏れ、競合状態、型の不整合、想定外入力。' },
  { key: 'security', label: 'セキュリティ', focus: 'インジェクション(SQL/コマンド/XSS)、認証・認可の欠落、機密情報のハードコード/ログ出力、安全でないデフォルト、未検証の外部入力、脆弱な暗号・乱数。' },
  { key: 'performance', label: '性能', focus: 'N+1クエリ、不要なループ/再計算、過剰なメモリ確保、同期I/Oによるブロッキング、非効率なデータ構造、ホットパスの重い処理。' },
  { key: 'maintainability', label: '保守性・設計', focus: '可読性、命名、重複コード、過度な複雑さ、責務の混在、不要なコメント、抽象化の過不足、既存パターンからの逸脱、挙動変更に伴うドキュメント/コメントの更新漏れ。' },
  { key: 'tests', label: 'テスト', focus: '新規/変更ロジックに対するテスト欠如、境界値・異常系の未カバー、壊れた/無意味なアサーション、テスト容易性の低い設計。' },
]

function scopePrompt() {
  const arg = (args === undefined || args === null || args === '')
    ? '(指定なし)'
    : (typeof args === 'string' ? args : JSON.stringify(args))
  return [
    'あなたはコードレビューの差分範囲を確定する担当です。',
    `引数(args): ${arg}`,
    '',
    '手順:',
    '1. gitリポジトリのルートで作業していることを確認する。',
    '2. レビュー対象の差分範囲を決める:',
    '   - argsがbase ref(例: main, origin/main, develop, HEAD~3)なら `git diff <base>...HEAD` を対象にする。',
    '   - argsが "staged" なら `git diff --staged`、"working" なら `git diff`(未コミット作業ツリー) を対象にする。',
    '   - argsがPR番号(例: "#123" や "123")なら `gh pr diff <番号>` が使えるか試す。使えなければそのPRのbase基準にフォールバックする。',
    '   - args指定が無い場合: 既定ブランチ(main/master)を検出してmerge-baseを取り `git diff <merge-base>...HEAD` を基本とする。現在が既定ブランチ上でコミット差分が無ければ、未コミット作業ツリー `git diff`(必要なら staged も含む) を対象にする。',
    '3. 決めた差分を実際に実行し、変更ファイル一覧(`--name-only`)とdiffstat(`--stat`)を取得する。',
    '',
    '出力:',
    '- diffCommand には、レビュー担当全員が一字一句そのまま実行できる単一のコマンド文字列を入れる(例: "git diff main...HEAD")。パイプやシェル補間を含めない。',
    '- baseRef は比較基準。作業ツリーのレビュー時は "WORKING"。',
    '- diffScope は範囲の説明(コミット済みbase...HEADか、未コミットか、PR番号か等)。',
    '- changedFiles は変更ファイルの相対パス配列。',
    '- 変更が一切無ければ isEmpty=true とし、note に理由を書く。',
  ].join('\n')
}

function reviewPrompt(d, scope) {
  return [
    `あなたは「${d.label}」の観点に特化したコードレビュアーです。`,
    `この観点の重点: ${d.focus}`,
    '',
    `差分範囲: ${scope.diffScope}`,
    `次のコマンドを一字一句そのまま実行して差分を取得すること: ${scope.diffCommand}`,
    `変更ファイル: ${(scope.changedFiles || []).join(', ') || '(差分コマンドの出力を参照)'}`,
    '',
    '進め方:',
    '- 上記コマンドで差分を取得し、変更された行を中心にレビューする。文脈把握のため周辺コードやファイル全体を読んでよいが、指摘は今回の変更が原因・影響する箇所に限定する。',
    `- 「${d.label}」以外の観点(他のレビュアーが担当)は報告しない。重複を避ける。`,
    '- 各指摘に file, line(行/範囲), severity, title(簡潔), detail(なぜ問題か), suggestion(具体的な修正案) を付ける。',
    '- severity基準: critical=本番障害/データ損失/重大な脆弱性, high=明確なバグ/重要な欠陥, medium=条件付きの問題/設計上の懸念, low=軽微, nit=好みの範囲。',
    '- 問題が無ければ findings を空配列で返す。憶測や一般論で水増ししない。',
  ].join('\n')
}

function verifyPrompt(f, scope) {
  return [
    'あなたは他のレビュアーが挙げた指摘を敵対的に検証する懐疑的なレビュアーです。',
    'デフォルトの姿勢は「その指摘は本当に正しいのか?」と疑うこと。',
    '',
    '検証対象の指摘:',
    `- ファイル: ${f.file}${f.line ? ' :' + f.line : ''}`,
    `- 深刻度(申告): ${f.severity}`,
    `- タイトル: ${f.title}`,
    `- 詳細: ${f.detail}`,
    f.suggestion ? `- 提案: ${f.suggestion}` : '',
    '',
    `差分範囲: ${scope.diffScope}`,
    `差分取得コマンド(必要なら実行): ${scope.diffCommand}`,
    '',
    '手順:',
    '- 実際に該当ファイル/差分を読み、その指摘が今回の変更に起因して現実に成立するかを確認する。',
    '- verdict の決め方:',
    '  * reject: 明確な誤検知、既に対処済み、今回の変更範囲外、または事実誤認のとき。',
    '  * downgrade: 問題は起こりうるが申告ほど深刻でない、または再現条件が限定的なとき。adjustedSeverity に下げた深刻度を入れる。',
    '  * confirmed: 指摘は妥当。深刻度が適切なら adjustedSeverity は申告どおりにする。',
    '- 重要: critical または high の指摘は、誤検知だと確信できる場合のみ reject する。再現を確認しきれないが妥当性が残る場合は reject せず downgrade にすること(取りこぼし防止)。',
    '- reasoning に根拠を簡潔に書く。',
  ].filter(Boolean).join('\n')
}

function reportPrompt(confirmed, scope) {
  return [
    'あなたはレビュー結果を統合して最終レポートを書く担当です。出力は日本語のMarkdown。',
    '',
    `差分範囲: ${scope.diffScope}`,
    `base: ${scope.baseRef} / コマンド: ${scope.diffCommand}`,
    `変更ファイル数: ${(scope.changedFiles || []).length}`,
    '',
    '検証を通過した指摘(JSON):',
    '```json',
    JSON.stringify(confirmed, null, 2),
    '```',
    '',
    'レポート構成:',
    '1. まず指摘を統合する: 複数の観点(dimension)から挙がった「同じ根本原因」の指摘は1件にまとめる。file:lineの機械的一致ではなく意味で判断し、関連する観点を併記し、深刻度は最も高いものを採用する。',
    '2. 冒頭に総評(2〜4行)と総合判定: ✅ Approve / 🔧 Request changes / ⛔ Block のいずれか。critical/highが残る場合は Approve にしない。',
    '3. 深刻度の高い順(critical→high→medium→low→nit)に指摘を列挙。各指摘は見出しに [深刻度] file:line とタイトル、本文に理由と具体的な修正案を書き、該当する観点(複数可)を併記する。',
    '4. nit/lowが多い場合はまとめて簡潔に列挙し、critical/highが埋もれないようにする。',
    '5. 全体として良い点があれば簡潔に触れる。',
    '6. 指摘が1件も無ければ、変更範囲を確認した上で「問題なし」と明記する。',
    '',
    '冗長な前置きや一般論は避け、変更に即した具体的な内容のみを書くこと。',
  ].join('\n')
}

phase('Scope')
log('差分範囲を確定中...')
const scope = await agent(scopePrompt(), { label: 'scope', phase: 'Scope', schema: SCOPE_SCHEMA })

if (!scope || scope.isEmpty) {
  log('レビュー対象の差分がありません。')
  return {
    baseRef: scope ? scope.baseRef : null,
    diffCommand: scope ? scope.diffCommand : null,
    changedFiles: [],
    confirmed: [],
    report: `## multi-review\n\nレビュー対象の差分が見つかりませんでした。${scope && scope.note ? '\n\n理由: ' + scope.note : ''}`,
  }
}

log(`差分範囲: ${scope.diffScope} / 変更ファイル ${(scope.changedFiles || []).length} 件。${DIMENSIONS.length} 観点で並列レビューを開始。`)

const reviewed = await pipeline(
  DIMENSIONS,
  (d) => agent(reviewPrompt(d, scope), { label: `review:${d.key}`, phase: 'Review', schema: FINDINGS_SCHEMA }),
  (review, d) => parallel(
    ((review && review.findings) || []).map((f) => () => {
      if (f.severity === 'low' || f.severity === 'nit') {
        return Promise.resolve({ ...f, dimension: d.key, verified: false, verdict: { verdict: 'unverified', reasoning: '低深刻度のため敵対的検証を省略' } })
      }
      return agent(verifyPrompt(f, scope), { label: `verify:${d.key}:${f.file}`, phase: 'Verify', schema: VERDICT_SCHEMA })
        .then((v) => ({ ...f, dimension: d.key, verified: true, verdict: v }))
    })
  )
)

const all = reviewed.flat().filter(Boolean)
const confirmed = all
  .filter((f) => !(f.verdict && f.verdict.verdict === 'reject'))
  .map((f) => (f.verdict && f.verdict.verdict === 'downgrade' && f.verdict.adjustedSeverity)
    ? { ...f, severity: f.verdict.adjustedSeverity }
    : f)

const rejectedCount = all.length - confirmed.length
log(`指摘 ${all.length} 件中 ${confirmed.length} 件が確定(${rejectedCount} 件は誤検知として除外)。レポートを生成中。`)

phase('Report')
const report = await agent(reportPrompt(confirmed, scope), { label: 'report', phase: 'Report' })

return {
  baseRef: scope.baseRef,
  diffCommand: scope.diffCommand,
  diffScope: scope.diffScope,
  changedFiles: scope.changedFiles,
  totalRaw: all.length,
  confirmed,
  rejected: rejectedCount,
  report,
}
