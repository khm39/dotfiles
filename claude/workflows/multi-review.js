export const meta = {
  name: 'multi-review',
  description: 'リポジトリ全体を観点別にレビューする。攻撃面/重要度で優先度付けした単位にファンアウトし、各指摘を敵対的に検証、カバレッジを明示した日本語レポートに統合する',
  whenToUse: 'リポジトリ全体のコード品質を多観点(正確性/セキュリティ/性能/保守性/テスト)で棚卸ししたいとき。引数なしで全体、パスを渡すとその範囲、base ref/"diff"を渡すと差分のみ。差分やセキュリティ単体は既存の /code-review・/security-review でも可。',
  phases: [
    { title: 'Map', detail: '構成を把握しレビュー単位に分割・優先度付け' },
    { title: 'Review', detail: '単位ごとに観点別レビュー(優先度順・予算でスケール)' },
    { title: 'Verify', detail: '各指摘を敵対的に検証' },
    { title: 'Report', detail: '重複排除・カバレッジ明示で日本語レポートに統合' },
  ],
}

const SEVERITIES = ['critical', 'high', 'medium', 'low', 'nit']

const DIMENSIONS = [
  { key: 'correctness', label: '正確性・バグ', focus: 'ロジック誤り、境界条件、null/undefined、例外/エラー処理漏れ、競合状態、型の不整合、想定外入力。' },
  { key: 'security', label: 'セキュリティ', focus: 'インジェクション(SQL/コマンド/XSS)、認証・認可の欠落、機密情報のハードコード/ログ出力、安全でないデフォルト、未検証の外部入力、脆弱な暗号・乱数。' },
  { key: 'performance', label: '性能', focus: 'N+1クエリ、不要なループ/再計算、過剰なメモリ確保、同期I/Oによるブロッキング、非効率なデータ構造、ホットパスの重い処理。' },
  { key: 'maintainability', label: '保守性・設計', focus: '可読性、命名、重複コード、過度な複雑さ、責務の混在、不要なコメント、抽象化の過不足、既存パターンからの逸脱、挙動と乖離したドキュメント/コメント。' },
  { key: 'tests', label: 'テスト', focus: '重要ロジックに対するテスト欠如、境界値・異常系の未カバー、壊れた/無意味なアサーション、テスト容易性の低い設計。' },
]
const DIM_KEYS = DIMENSIONS.map((d) => d.key)

// 1単位のレビュー+検証+レポート按分で消費する出力トークンの概算(予算スケール用)
const PER_UNIT = 12000
// エージェント総数(〜1000)・同時実行(〜14)上限を踏まえた安全上限。超過分は黙って捨てずlogする
const HARD_CAP = 80

const MAP_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    mode: { type: 'string', enum: ['full', 'path', 'diff'], description: 'full=リポ全体, path=指定パス配下, diff=変更差分のみ。' },
    target: { type: 'string', description: 'レビュー対象の説明(全体/対象パス/diffコマンド等)。' },
    repoSummary: { type: 'string', description: 'リポジトリの役割・構成の要約。' },
    languages: { type: 'array', items: { type: 'string' } },
    detectedTools: { type: 'array', items: { type: 'string' }, description: 'リポ内に設定が見つかった静的解析/lint/scanner(例: semgrep, eslint, gitleaks)。無ければ空配列。' },
    units: {
      type: 'array',
      description: 'レビュー単位。モジュール/ディレクトリ粒度で、優先度(high→low)順に並べる。',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          id: { type: 'string', description: '短い識別子(kebab-case)。' },
          label: { type: 'string', description: '人間向けの名称。' },
          paths: { type: 'array', items: { type: 'string' }, description: 'この単位に含まれるディレクトリ/ファイル/グロブ。' },
          priority: { type: 'string', enum: ['high', 'medium', 'low'] },
          rationale: { type: 'string', description: 'なぜこの優先度か(攻撃面/重要度/複雑さ等)。' },
        },
        required: ['id', 'label', 'paths', 'priority'],
      },
    },
    isEmpty: { type: 'boolean' },
    note: { type: 'string' },
  },
  required: ['mode', 'target', 'units', 'isEmpty'],
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
          dimension: { type: 'string', enum: DIM_KEYS, description: 'どの観点の指摘か。' },
          severity: { type: 'string', enum: SEVERITIES },
          title: { type: 'string' },
          detail: { type: 'string' },
          suggestion: { type: 'string' },
        },
        required: ['file', 'dimension', 'severity', 'title', 'detail'],
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

function mapPrompt() {
  const arg = (args === undefined || args === null || args === '')
    ? '(指定なし)'
    : (typeof args === 'string' ? args : JSON.stringify(args))
  return [
    'あなたはリポジトリ全体のレビュー計画を立てる担当です。コードを読み、レビュー単位に分割して優先度を付けます。',
    `引数(args): ${arg}`,
    '',
    'まずレビュー対象(mode)を決める:',
    '- args指定なし → mode="full"。リポジトリ全体。',
    '- argsがパス/グロブ(例: "src/", "packages/api", "**/*.py") → mode="path"。その範囲配下のみ。',
    '- argsが "diff" / base ref(例: main) / PR番号 → mode="diff"。変更があったファイルとその周辺コンポーネントのみ。`git diff` 等で変更範囲を特定する。',
    '',
    '次に対象を調査する:',
    '1. 言語・フレームワーク・ビルド構成を把握する(languages)。',
    '2. リポの役割と全体構成を要約する(repoSummary)。',
    '3. 静的解析/lint/scannerの設定(semgrep, eslint, gitleaks, CodeQL設定, 依存スキャナ等)が存在すれば detectedTools に列挙する(無ければ空配列)。導入されていないツールを勝手に追加・実行はしない。',
    '4. 対象コードを「レビュー単位」に分割する。粒度はモジュール/ディレクトリ程度。極端に小さいものはまとめ、巨大なモジュールは分割する。中規模リポなら概ね15〜50単位が目安。',
    '5. 各単位に優先度を付ける。high=外部入力の入口・認証認可・データ取扱い・中核ロジック・複雑/巨大な箇所。units は priority の高い順に並べる。',
    '',
    '出力:',
    '- units は id/label/paths/priority/rationale を持ち、優先度順。paths は実在する相対パス/グロブ。',
    '- 対象にレビューすべきコードが無い(空リポ/対象パスが空/差分なし)場合は isEmpty=true とし note に理由を書く。',
    '- 推測でファイルをでっち上げない。実際に存在するパスのみ。',
  ].join('\n')
}

function dimensionChecklist() {
  return DIMENSIONS.map((d) => `  - ${d.key} (${d.label}): ${d.focus}`).join('\n')
}

function reviewUnitPrompt(unit, map) {
  return [
    'あなたはコードレビュアーです。指定された「レビュー単位」を複数観点でレビューします。',
    '',
    `リポジトリ概要: ${map.repoSummary || '(不明)'}`,
    `言語: ${(map.languages || []).join(', ') || '(自動判定)'}`,
    '',
    `レビュー単位: ${unit.label} [優先度: ${unit.priority}]`,
    `対象パス: ${(unit.paths || []).join(', ')}`,
    unit.rationale ? `この単位の重点: ${unit.rationale}` : '',
    '',
    '進め方:',
    '- 対象パスのファイルを読んでレビューする。文脈把握のため直接の依存(呼び出し元/先)を参照してよいが、指摘は原則この単位のコードに限定する(他単位は別途レビューされる。重複報告を避ける)。',
    '- 次の観点すべてで見る。各指摘には該当する観点(dimension)を付ける:',
    dimensionChecklist(),
    '- 各指摘に file, line(行/範囲), dimension, severity, title(簡潔), detail(なぜ問題か), suggestion(具体的な修正案) を付ける。',
    '- severity基準: critical=本番障害/データ損失/重大な脆弱性, high=明確なバグ/重要な欠陥, medium=条件付きの問題/設計上の懸念, low=軽微, nit=好みの範囲。',
    '- 問題が無ければ findings を空配列で返す。憶測や一般論で水増ししない。実在する具体的な問題のみ。',
  ].filter(Boolean).join('\n')
}

function verifyPrompt(f, unit) {
  return [
    'あなたは他のレビュアーが挙げた指摘を敵対的に検証する懐疑的なレビュアーです。',
    'デフォルトの姿勢は「その指摘は本当に正しいのか?」と疑うこと。',
    '',
    '検証対象の指摘:',
    `- レビュー単位: ${unit.label}`,
    `- ファイル: ${f.file}${f.line ? ' :' + f.line : ''}`,
    `- 観点: ${f.dimension}`,
    `- 深刻度(申告): ${f.severity}`,
    `- タイトル: ${f.title}`,
    `- 詳細: ${f.detail}`,
    f.suggestion ? `- 提案: ${f.suggestion}` : '',
    '',
    '手順:',
    '- 実際に該当ファイル/コードを読み、その指摘が現実に成立するかを確認する。',
    '- verdict の決め方:',
    '  * reject: 明確な誤検知、既に対処済み、または事実誤認のとき。',
    '  * downgrade: 問題は起こりうるが申告ほど深刻でない、または条件が限定的なとき。adjustedSeverity に下げた深刻度を入れる。',
    '  * confirmed: 指摘は妥当。深刻度が適切なら adjustedSeverity は申告どおりにする。',
    '- 重要: critical または high の指摘は、誤検知だと確信できる場合のみ reject する。妥当性が残るが確証が持てない場合は reject せず downgrade にすること(取りこぼし防止)。',
    '- reasoning に根拠を簡潔に書く。',
  ].filter(Boolean).join('\n')
}

function reportPrompt(confirmed, map, coverage) {
  return [
    'あなたはリポジトリ全体のレビュー結果を統合して最終レポートを書く担当です。出力は日本語のMarkdown。',
    '',
    `対象: ${map.target}`,
    `リポジトリ概要: ${map.repoSummary || ''}`,
    `言語: ${(map.languages || []).join(', ')}`,
    '',
    'カバレッジ情報(レポートに必ず明記する):',
    '```json',
    JSON.stringify(coverage, null, 2),
    '```',
    '',
    '検証を通過した指摘(JSON):',
    '```json',
    JSON.stringify(confirmed, null, 2),
    '```',
    '',
    'レポート構成:',
    '1. まず指摘を統合する: 異なる単位・観点から挙がった「同じ根本原因」の指摘は1件にまとめる。file:lineの機械的一致ではなく意味で判断し、関連する観点を併記し、深刻度は最も高いものを採用する。',
    '2. 冒頭に総評(2〜4行)と総合判定: ✅ 良好 / 🔧 要改善 / ⛔ 重大問題あり のいずれか。critical/highが残る場合は良好にしない。',
    '3. **カバレッジ**セクション: 全N単位中M単位をレビュー(未カバーがあれば優先度下位の単位名を挙げる)。これはLLMベースのレビューであり、ファイル横断のデータフローや網羅性には限界があること、決定的な保証には専用の静的解析(SAST)が必要なことを明記する。detectedToolsがあれば併用を勧める。',
    '4. 深刻度の高い順(critical→high→medium→low→nit)に指摘を列挙。各指摘は見出しに [深刻度] file:line とタイトル、本文に理由と具体的な修正案を書き、該当する観点(複数可)と単位を併記する。',
    '5. nit/lowが多い場合はまとめて簡潔に列挙し、critical/highが埋もれないようにする。',
    '6. 指摘が1件も無ければ、確認した範囲を明記した上で「重大な問題は見つからなかった」と書く。',
    '',
    '冗長な前置きや一般論は避け、具体的な内容のみを書くこと。',
  ].join('\n')
}

phase('Map')
log('リポジトリ構成を把握しレビュー単位に分割中...')
const map = await agent(mapPrompt(), { label: 'map', phase: 'Map', schema: MAP_SCHEMA })

const units = (map && map.units) || []
if (!map || map.isEmpty || units.length === 0) {
  log('レビュー対象のコードが見つかりませんでした。')
  return {
    mode: map ? map.mode : null,
    target: map ? map.target : null,
    units: [],
    confirmed: [],
    report: `## multi-review\n\nレビュー対象のコードが見つかりませんでした。${map && map.note ? '\n\n理由: ' + map.note : ''}`,
  }
}

let cap = budget.total ? Math.max(3, Math.floor(budget.remaining() / PER_UNIT)) : units.length
cap = Math.min(cap, HARD_CAP)
const toReview = units.slice(0, cap)
const skipped = units.slice(cap)

log(`対象: ${map.target} / ${units.length} 単位を検出。${toReview.length} 単位(優先度上位)を${DIMENSIONS.length}観点でレビュー開始。`)
if (skipped.length) {
  log(`注意: 予算/上限により ${skipped.length} 単位は未カバー(優先度下位): ${skipped.map((u) => u.label || u.id).join(', ')}`)
}

const reviewed = await pipeline(
  toReview,
  (unit) => agent(reviewUnitPrompt(unit, map), { label: `review:${unit.id}`, phase: 'Review', schema: FINDINGS_SCHEMA }),
  (review, unit) => parallel(
    ((review && review.findings) || []).map((f) => () => {
      const base = { ...f, unit: unit.label || unit.id }
      if (f.severity === 'low' || f.severity === 'nit') {
        return Promise.resolve({ ...base, verified: false, verdict: { verdict: 'unverified', reasoning: '低深刻度のため敵対的検証を省略' } })
      }
      return agent(verifyPrompt(f, unit), { label: `verify:${unit.id}:${f.file}`, phase: 'Verify', schema: VERDICT_SCHEMA })
        .then((v) => ({ ...base, verified: true, verdict: v }))
    })
  )
)

const all = reviewed.flat().filter(Boolean)
const confirmed = all
  .filter((f) => !(f.verdict && f.verdict.verdict === 'reject'))
  .map((f) => (f.verdict && f.verdict.verdict === 'downgrade' && f.verdict.adjustedSeverity)
    ? { ...f, severity: f.verdict.adjustedSeverity }
    : f)

const coverage = {
  mode: map.mode,
  totalUnits: units.length,
  reviewedUnits: toReview.length,
  skippedUnits: skipped.map((u) => u.label || u.id),
  detectedTools: map.detectedTools || [],
  method: 'LLMベースのレビュー(決定的な網羅保証なし)',
}

const rejectedCount = all.length - confirmed.length
log(`指摘 ${all.length} 件中 ${confirmed.length} 件が確定(${rejectedCount} 件は誤検知として除外)。レポートを生成中。`)

phase('Report')
const report = await agent(reportPrompt(confirmed, map, coverage), { label: 'report', phase: 'Report' })

return {
  mode: map.mode,
  target: map.target,
  languages: map.languages,
  coverage,
  totalRaw: all.length,
  confirmed,
  rejected: rejectedCount,
  report,
}
