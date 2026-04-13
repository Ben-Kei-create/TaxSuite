// MARK: - ReceiptParserTests.swift
//
// 単体テスト: OCR テキスト解析・手取り計算ロジックを外部依存なしで検証する。
//
// 実行方法: Xcode メニュー → Product → Test (⌘U)

import XCTest
@testable import TaxSuite

final class ReceiptParserTests: XCTestCase {

    // MARK: - 金額抽出

    func testExtractAmount_gokei_with_yen() {
        let lines = ["領収書", "合計 ¥ 1,200", "ありがとうございました"]
        let result = ReceiptParser.extractAmount(from: lines)
        XCTAssertEqual(result, 1200.0, "「合計 ¥」フォーマットから正しく抽出されること")
    }

    func testExtractAmount_yen_suffix() {
        let lines = ["スタバ", "フラペチーノ 680 円"]
        let result = ReceiptParser.extractAmount(from: lines)
        XCTAssertEqual(result, 680.0, "「数字＋円」フォーマットから正しく抽出されること")
    }

    func testExtractAmount_tax_included() {
        let lines = ["コンビニ", "小計 950", "消費税 95", "合計 1,045円"]
        let result = ReceiptParser.extractAmount(from: lines)
        XCTAssertEqual(result, 1045.0, "「合計 N,NNN円」フォーマットから税込金額を抽出できること")
    }

    func testExtractAmount_no_amount_returns_nil() {
        let lines = ["テキストのみ", "金額なし"]
        let result = ReceiptParser.extractAmount(from: lines)
        XCTAssertNil(result, "金額が含まれない場合は nil を返すこと")
    }

    // MARK: - タイトル抽出

    func testExtractTitle_returns_non_empty() {
        let lines = ["スターバックスコーヒー", "ラテ 500円", "合計 500円"]
        let result = ReceiptParser.extractTitle(from: lines)
        XCTAssertFalse(result.isEmpty, "タイトルが空でないこと")
    }

    // MARK: - ParsedReceipt 全体構造

    func testParse_returnsCompleteReceipt() {
        let lines = ["テストカフェ", "コーヒー 450円", "合計 450円"]
        let receipt = ReceiptParser.parse(from: lines)
        XCTAssertEqual(receipt.amount, 450.0, "金額が正しくパースされること")
        XCTAssertFalse(receipt.rawText.isEmpty, "rawText が空でないこと")
    }

    // MARK: - 手取り計算ロジック

    func testTakeHomeCalculation_basic() {
        let revenue: Double   = 500_000
        let expenses: Double  = 100_000
        let taxRate: Double   = 0.2

        let takeHome = TaxCalculator.calculateTakeHome(
            revenue: revenue,
            expenses: expenses,
            taxRate: taxRate
        )
        // 課税所得 400,000 × 20% = 80,000 税 → 手取り 320,000
        XCTAssertEqual(takeHome, 320_000.0, accuracy: 0.01,
                       "売上 50万 / 経費 10万 / 税率 20% で手取り 32万になること")
    }

    func testTakeHomeCalculation_zero_revenue() {
        let takeHome = TaxCalculator.calculateTakeHome(
            revenue: 0, expenses: 50_000, taxRate: 0.2
        )
        // 経費 > 売上 → 課税所得は max(0, ...) でゼロ、手取りはマイナス
        XCTAssertLessThanOrEqual(takeHome, 0,
                                 "売上ゼロ・経費ありの場合、手取りは 0 以下になること")
    }

    func testTakeHomeCalculation_no_expenses() {
        let takeHome = TaxCalculator.calculateTakeHome(
            revenue: 1_000_000, expenses: 0, taxRate: 0.3
        )
        // 税 300,000 → 手取り 700,000
        XCTAssertEqual(takeHome, 700_000.0, accuracy: 0.01,
                       "経費なしの場合、手取り = 売上 × (1 - 税率) になること")
    }
}
