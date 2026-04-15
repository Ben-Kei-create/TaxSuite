# TaxSuite Pro: 投資・iDeCo モジュール 設計スケッチ

> ステータス: Draft（Pro 版の参考設計。現時点では未実装。スコープ外）
> 目的: iDeCo / NISA / 株式・投資信託の保有状況を、税シミュレーションや節税提案とセットで見えるようにする

## 1. 全体方針

- **中核は節税提案のための計算エンジン**。ポートフォリオ管理アプリを作るのではなく、
  「いくら税金が減るか・手取りがどう変わるか」を個人事業主の目線で可視化することに全振り。
- **データは手入力が主 + CSV 取り込み補助**。証券口座連携はセキュリティ／審査／
  リスクが重いので v1 では見送り。将来 Pro+ でオプション化を検討。
- **無料版との境界**: 税の知識（Glossary）や固定費リマインダーは無料のまま。
  Pro は「数値を入れる → 節税額が出る・年間シナリオが引ける」体験で差別化。

## 2. 提供する体験（3 レイヤー）

### L1: 税優遇シミュレーター（最初に入れる）

- iDeCo の掛金と年齢・職業種別から「今年いくら所得控除されるか → 所得税+住民税が
  いくら減るか」を 1 画面で即計算。
- NISA は非課税枠の消化状況（つみたて枠 年 120 万 / 成長投資枠 年 240 万、総枠 1800 万）を
  プログレスバーで表示し、残り枠と想定運用益の非課税メリットを提示。
- 結果はダッシュボードの「推定税額」カードと連動し、iDeCo 反映前 / 後 の手取りを並べて表示する。

### L2: ポートフォリオ台帳

- 資産クラスごとに残高を記録（株式 / 投資信託 / 債券 / iDeCo / 現金）。
- 月次で残高を手入力するだけで推移グラフ、資産クラスの配分円グラフを描画。
- 各レコードに「課税口座 / NISA / iDeCo」のタグを付け、売却時の税計算を自動判定。

### L3: 節税提案（自動ヒント）

- 例: 「課税所得が X 円以上あるので、iDeCo 掛金を +5,000 円にすると年間 Y 円節税」。
- 例: 「NISA 成長投資枠の残りが多いので、課税口座より NISA に寄せると Z 年で節税額 W 円」。
- あくまで「提案」。免責文言と『試算です。最終判断は税理士 / FP へ』のメッセージを必ず表示。

## 3. データモデル（SwiftData ベース）

```swift
@Model final class InvestmentAccount {
    @Attribute(.unique) var id: UUID = UUID()
    var name: String              // "SBI 証券 特定口座", "楽天 iDeCo" など
    var accountType: AccountType  // .taxable / .nisaTsumitate / .nisaGrowth / .ideco / .cash
    var openedAt: Date?
    var note: String = ""
}

@Model final class InvestmentHolding {
    @Attribute(.unique) var id: UUID = UUID()
    var account: InvestmentAccount?
    var symbol: String            // "eMAXIS Slim 全世界株式" など（自由入力で十分）
    var assetClass: AssetClass    // .domesticStock / .globalStock / .bond / .reit / .cash
    var quantity: Double          // 口数 / 株数
    var averageCost: Double       // 平均取得単価
    var currentPrice: Double      // 手入力 or 月次更新
    var updatedAt: Date = Date()
}

@Model final class InvestmentContribution {
    @Attribute(.unique) var id: UUID = UUID()
    var account: InvestmentAccount?
    var amount: Double            // 当月の拠出額
    var date: Date
    var kind: ContributionKind    // .regular / .spot
}

@Model final class IDecoProfile {
    @Attribute(.unique) var id: UUID = UUID()
    var occupationCategory: IDecoOccupation  // 第1号 / 第2号（会社員・公務員）/ 第3号 / 国民年金基金併用
    var monthlyContribution: Double          // 現在の掛金
    var startedAt: Date?
    var plannedEndYear: Int                  // 受給開始予定
}
```

- 既存の `ExpenseItem` / `IncomeItem` には触らない（後方互換）。
- `IDecoProfile` は 1 レコードのみ。計算は income と cross-reference。

## 4. 主要計算ロジック（実装予定の小さな純粋関数）

```swift
enum InvestmentCalculator {
    /// iDeCo 掛金による所得控除額 → 所得税・住民税の減税見込み
    static func idecoTaxSavings(
        monthlyContribution: Double,
        taxableIncome: Double,
        residentTaxRate: Double = 0.10
    ) -> IDecoSavings

    /// NISA 残り非課税枠（つみたて / 成長 / 総枠）
    static func nisaRemaining(
        tsumitateUsedThisYear: Double,
        growthUsedThisYear: Double,
        lifetimeUsed: Double
    ) -> NisaRemaining

    /// 保有銘柄を課税口座で売却した場合の譲渡益税
    static func capitalGainsTax(
        proceeds: Double,
        costBasis: Double
    ) -> Double
}
```

- **副作用なし** + **単体テストで固定の期待値を検証** を徹底。税制は毎年微調整されるので
  `TaxYear.current` に切り替えロジックを集約し、年度ごとのテーブルを分離する。

## 5. UI スケッチ（画面単位）

### 5-1 ダッシュボードの追加カード（Pro ON の時のみ表示）

```
┌──────────────────────────────────┐
│  iDeCo                              │
│  今月 23,000 円 × 12 = 276,000 円  │
│  ━━━━━━━━━━━━━━━  70% (年額)      │
│  今年の節税見込み  ¥55,200         │
│  [詳細を見る]                      │
└──────────────────────────────────┘
┌──────────────────────────────────┐
│  NISA 非課税枠                    │
│  つみたて 480,000 / 1,200,000     │
│  成長   1,200,000 / 2,400,000     │
│  総枠   1,680,000 / 18,000,000    │
│  [非課税枠を計算]                 │
└──────────────────────────────────┘
```

### 5-2 iDeCo シミュレーター画面

- 上段: 年齢・職業種別・現在の課税所得をピッカー／スライダーで入力
- 中段: 掛金スライダー（下限〜職業別上限、例: 会社員 23,000円/月）
- 下段:
  - 「所得税の減額」
  - 「住民税の減額」
  - 「年間の節税合計」
  - 「60 歳までの累計節税（＝今の条件が続いた場合）」
- 免責文言を最下部にピン留め。

### 5-3 ポートフォリオ画面

- 上部: 総資産の大きな数字 + 前月比（％）
- 円グラフ: 資産クラスの配分
- セクションリスト: 口座種別ごとに銘柄を折りたたみ表示。タップで編集シート。
- 右上 + ボタン: 口座追加 / 銘柄追加 / 月次残高入力

### 5-4 「節税提案」タブ（L3）

- カード型ヒント（Glossary の UI を踏襲し無料版との一貫性を保つ）。
- カードごとに「根拠」「計算式」「参照 URL（国税庁 / 金融庁）」を折りたたみで展開可能。

## 6. 税計算との統合

- 既存の `TaxCalculator` に `adjustments: TaxAdjustments` を注入する口を足す。
  - `adjustments.idecoDeduction` を所得控除に加算
  - `adjustments.smallEnterpriseMutualRelief`（小規模企業共済）も同様
- ダッシュボードは Pro が ON かつ `IDecoProfile` が入っている時だけ
  「控除後の推定税額」と「控除前の推定税額」を両方表示する差分 UI を採用。

## 7. データ投入経路

- **手入力 UI** を v1 の中心に据える。
- **CSV 取り込み** を補助（SBI / 楽天 / マネックスなどの取引明細 CSV を読み込む）。
  マッピング設定は「スキーマ辞書」として Bundle に持ち、ユーザー編集可能。
- **証券 API 連携は v1 スコープ外**。本人確認やトークン保管が重く、
  App Review 通過コストも高いため Pro+ のロードマップに逃がす。

## 8. セキュリティ / プライバシー

- 金額はローカル（SwiftData）＋ CloudKit（個人 iCloud 内）のみで完結。
- 既存の CloudKit 構成（`TaxSuitePersistence.makeContainer` の `cloudKitDatabase: .automatic`）
  をそのまま拡張すれば、オフラインファースト＋自動同期が得られる。
- 解析ログに金額や銘柄名を混入させない（ラベル単位の集計のみに限定）。
- Face ID / Touch ID による起動ロック（App 全体オプション）を Pro 機能として同時に提供すると訴求力が高い。

## 9. 収益モデル（メモ）

- **Pro 月額** 500〜800 円程度 / **年額** 5,000〜8,000 円程度のレンジで StoreKit 2 の
  `Product.SubscriptionInfo` を利用。
- 無料体験 7 日。
- 解約後もデータは残す（読み取りは可、シミュレーション機能が無効化）。

## 10. 段階リリース

| フェーズ | 内容 | 無料 / Pro |
|:-:|:--|:--|
| P0 (現状) | 税の知識ページで iDeCo / NISA を「説明」のみ | 無料 |
| P1 | 本書の L1（iDeCo シミュレーター + NISA 枠表示） | Pro |
| P2 | L2 ポートフォリオ台帳 + CSV 取り込み | Pro |
| P3 | L3 自動ヒント（年度差分・複利シナリオ） | Pro |
| P4 | 証券 API 連携 / Face ID ロック / 家族共有 | Pro+ |

## 11. やらないこと（明示）

- 銘柄推奨、個別株の売買判断アドバイス
- 税理士の代替となる確定的な助言
- 証券会社への自動発注 / 出金

---

設計上の議論ポイント（次回レビューで決めたいこと）:

1. iDeCo の職業種別上限は年度で変わる → `TaxYear` 切り替えの UI 露出をどこまで見せるか
2. NISA の「年初リセット」「翌年復活」ルールの表現
3. 節税提案の免責ラインをどこに引くか（「〜を検討しましょう」程度に留める？）
4. Pro / 無料の境界を「機能ごと」にするか「上限ごと」にするか
