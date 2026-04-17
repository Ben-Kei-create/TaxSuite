import SwiftUI

// MARK: - AppTutorialView
// 初回起動チュートリアル。オンボーディング完了後に一度だけ表示される。
// ContentView の .overlay で差し込むため、fullScreenCover との競合なし。

struct AppTutorialView: View {
    var onComplete: () -> Void

    @State private var currentSlide = 0
    @State private var appeared = false

    private let slides: [TutorialSlide] = [
        TutorialSlide(
            icon: "plus.circle.fill",
            iconColor: .primary,
            tabIcon: "house.fill",
            tabLabel: "ホーム",
            title: "経費を追加しよう",
            body: "右下の ＋ ボタンをタップ。\n金額を入れるだけですぐ記録できます。"
        ),
        TutorialSlide(
            icon: "bolt.fill",
            iconColor: .orange,
            tabIcon: "house.fill",
            tabLabel: "ホーム",
            title: "クイック追加で1秒記録",
            body: "ダッシュボードのタイルをタップするだけ。\n長押しで金額や項目を編集できます。"
        ),
        TutorialSlide(
            icon: "calendar",
            iconColor: .red,
            tabIcon: "calendar",
            tabLabel: "カレンダー",
            title: "カレンダーで支出を振り返る",
            body: "日ごとの支出をヒートマップで表示。\n赤いほど支出が多い日です。"
        ),
        TutorialSlide(
            icon: "chart.pie.fill",
            iconColor: .blue,
            tabIcon: "chart.pie.fill",
            tabLabel: "分析",
            title: "分析で傾向をつかむ",
            body: "カテゴリ別・月別の経費推移をグラフで確認。\n手取りの目安も自動で計算されます。"
        ),
        TutorialSlide(
            icon: "gearshape.fill",
            iconColor: .secondary,
            tabIcon: "gearshape.fill",
            tabLabel: "設定",
            title: "設定でカスタマイズ",
            body: "税率・プロジェクト・固定費を管理。\nGoogleドライブやGmailとも連携できます。"
        )
    ]

    private var isLast: Bool { currentSlide == slides.count - 1 }

    var body: some View {
        ZStack {
            // ── 背景ブラー ──
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { advance() }

            VStack(spacing: 0) {
                Spacer()

                // ── スライドカード ──
                slideCard
                    .padding(.horizontal, 24)
                    .id(currentSlide)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal:   .move(edge: .leading).combined(with: .opacity)
                    ))

                // ── 吹き出しの尾 ──
                bubbleTail
                    .padding(.bottom, 2)

                // ── フェイクタブバー（どのタブの説明かを視覚的に示す） ──
                fakeTabBar
                    .padding(.bottom, 0)
            }
            .ignoresSafeArea(edges: .bottom)

            // ── スキップボタン ──
            VStack {
                HStack {
                    Spacer()
                    Button("スキップ") {
                        withAnimation(.easeOut(duration: 0.25)) { onComplete() }
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white.opacity(0.75))
                    .padding(.trailing, 22)
                    .padding(.top, 58)
                }
                Spacer()
            }
        }
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.35)) { appeared = true }
        }
    }

    // MARK: - Slide card

    private var slideCard: some View {
        let slide = slides[currentSlide]
        return VStack(spacing: 0) {
            // アイコンエリア
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(slide.iconColor.opacity(0.1))
                    .frame(height: 110)

                Image(systemName: slide.icon)
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [slide.iconColor, slide.iconColor.opacity(0.65)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 18)

            // テキスト
            VStack(spacing: 8) {
                Text(slide.title)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.center)

                Text(slide.body)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)

            // ドットインジケーター + ボタン
            VStack(spacing: 14) {
                progressDots

                Button(action: advance) {
                    Text(isLast ? "始める" : "次へ")
                        .font(.headline)
                        .foregroundColor(Color(UIColor.systemBackground))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 22)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    // MARK: - Bubble tail (▼)

    private var bubbleTail: some View {
        Triangle()
            .fill(.ultraThinMaterial)
            .frame(width: 24, height: 12)
            .offset(x: tabOffset)
            .animation(.spring(response: 0.4, dampingFraction: 0.75), value: currentSlide)
    }

    // フェイクタブバー
    private var fakeTabBar: some View {
        HStack(spacing: 0) {
            ForEach(tabItems, id: \.label) { item in
                let isActive = item.label == slides[currentSlide].tabLabel
                VStack(spacing: 4) {
                    Image(systemName: item.icon)
                        .font(.system(size: 22))
                        .foregroundColor(isActive ? .primary : .white.opacity(0.4))
                    Text(item.label)
                        .font(.system(size: 10))
                        .foregroundColor(isActive ? .primary : .white.opacity(0.4))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                .padding(.bottom, 28)
                .background(isActive ? Color.white.opacity(0.1) : Color.clear)
                .animation(.spring(response: 0.35), value: currentSlide)
            }
        }
        .background(.ultraThinMaterial)
    }

    private let tabItems: [(icon: String, label: String)] = [
        ("house.fill",      "ホーム"),
        ("calendar",        "カレンダー"),
        ("chart.pie.fill",  "分析"),
        ("gearshape.fill",  "設定")
    ]

    // 吹き出しの尾のX位置をアクティブなタブに合わせる
    private var tabOffset: CGFloat {
        let label = slides[currentSlide].tabLabel
        let index = tabItems.firstIndex(where: { $0.label == label }) ?? 0
        // 4タブ均等割りのセンター位置 (スクリーン幅を使えないのでUIScreen fallback)
        let screenW = UIScreen.main.bounds.width - 48 // card horizontal padding
        let slotW   = screenW / CGFloat(tabItems.count)
        return slotW * CGFloat(index) + slotW / 2 - screenW / 2
    }

    // MARK: - Progress dots

    private var progressDots: some View {
        HStack(spacing: 7) {
            ForEach(0..<slides.count, id: \.self) { i in
                Capsule()
                    .fill(i == currentSlide ? Color.primary : Color.primary.opacity(0.2))
                    .frame(width: i == currentSlide ? 20 : 7, height: 7)
                    .animation(.spring(response: 0.35, dampingFraction: 0.75), value: currentSlide)
            }
        }
    }

    // MARK: - Actions

    private func advance() {
        if isLast {
            withAnimation(.easeOut(duration: 0.25)) { onComplete() }
        } else {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                currentSlide += 1
            }
        }
    }
}

// MARK: - Supporting types

private struct TutorialSlide {
    let icon: String
    let iconColor: Color
    let tabIcon: String
    let tabLabel: String
    let title: String
    let body: String
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.closeSubpath()
        }
    }
}

// MARK: - Preview

#Preview {
    AppTutorialView(onComplete: {})
}
