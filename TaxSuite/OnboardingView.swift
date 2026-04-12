import SwiftUI

struct OnboardingView: View {
    @AppStorage("taxRate") var taxRate: Double = 0.2
    @AppStorage("taxSuiteSenderName") var senderName: String = ""
    @AppStorage("taxSuiteBusinessName") var businessName: String = ""

    var onComplete: () -> Void

    @State private var step: Int = 0

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            VStack(spacing: 0) {
                ZStack {
                    if step == 0 {
                        step0View
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing),
                                removal: .move(edge: .leading)
                            ).combined(with: .opacity))
                    } else if step == 1 {
                        step1View
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing),
                                removal: .move(edge: .leading)
                            ).combined(with: .opacity))
                    } else {
                        step2View
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing),
                                removal: .move(edge: .leading)
                            ).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                progressDots
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                stepButton
                    .padding(.bottom, 32)
            }
        }
    }

    // MARK: - Step 0: Welcome

    private var step0View: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Spacer()
                    Image(systemName: "sparkles")
                        .font(.system(size: 64))
                        .foregroundColor(.black)
                    Spacer()
                }
                .padding(.top, 40)
                .padding(.bottom, 28)

                Text("TaxSuite へようこそ")
                    .font(.largeTitle.bold())
                    .foregroundColor(.black)
                    .padding(.bottom, 12)

                Text("フリーランスの経費・売上を、シンプルに管理しましょう。")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 36)

                VStack(spacing: 20) {
                    featureRow(icon: "yensign.circle.fill", text: "経費・売上を素早く記録")
                    featureRow(icon: "chart.pie.fill", text: "税負担と手取りをリアルタイム把握")
                    featureRow(icon: "square.grid.2x2.fill", text: "ホーム画面ウィジェットでワンタップ入力")
                }
                .padding(.bottom, 40)
            }
            .padding(.horizontal, 24)
        }
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(.secondary)
                .frame(width: 28)
            Text(text)
                .font(.body)
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    // MARK: - Step 1: Tax Rate + Name

    private var step1View: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("基本情報を設定")
                    .font(.largeTitle.bold())
                    .foregroundColor(.black)
                    .padding(.top, 40)
                    .padding(.bottom, 8)

                Text("あとから設定でいつでも変更できます")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 28)

                VStack(spacing: 0) {
                    // Tax rate row
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("消費税・所得税率")
                                .font(.subheadline)
                                .foregroundColor(.black)
                            Spacer()
                            Text("\(Int(taxRate * 100))%")
                                .font(.subheadline.monospacedDigit())
                                .foregroundColor(.black)
                                .fontWeight(.semibold)
                        }
                        Slider(value: $taxRate, in: 0.1...0.5, step: 0.05)
                            .tint(.black)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)

                    Divider()
                        .padding(.horizontal, 16)

                    // Sender name row
                    TextField("お名前 / ハンドルネーム", text: $senderName)
                        .font(.body)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)

                    Divider()
                        .padding(.horizontal, 16)

                    // Business name row
                    TextField("屋号・事業名（任意）", text: $businessName)
                        .font(.body)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                }
                .background(Color.white)
                .cornerRadius(18)
                .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 4)
                .padding(.bottom, 16)

                Text("税率は売上の規模感で変わります。わからなければ 20% のままでOKです。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 40)
            }
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Step 2: Done

    private var step2View: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Spacer()
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 72))
                        .foregroundColor(.black)
                    Spacer()
                }
                .padding(.top, 40)
                .padding(.bottom, 28)

                Text("準備完了です！")
                    .font(.largeTitle.bold())
                    .foregroundColor(.black)
                    .padding(.bottom, 12)

                Text("まず今日の経費をひとつ記録してみましょう。ダッシュボードの「＋」から追加できます。")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 36)

                VStack(spacing: 20) {
                    tipRow(icon: "bolt.fill", text: "ホーム画面のクイック追加は長押しで編集できます")
                    tipRow(icon: "camera.fill", text: "レシートのカメラスキャン（Pro）で自動入力も可能です")
                }
                .padding(.bottom, 40)
            }
            .padding(.horizontal, 24)
        }
    }

    private func tipRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.secondary)
                .frame(width: 20, height: 22)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    // MARK: - Progress Dots

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(index == step ? Color.black : Color.gray.opacity(0.3))
                    .frame(width: index == step ? 8 : 7, height: index == step ? 8 : 7)
                    .animation(.easeInOut(duration: 0.2), value: step)
            }
        }
    }

    // MARK: - Step Button

    @ViewBuilder
    private var stepButton: some View {
        switch step {
        case 0:
            primaryButton("はじめる") {
                withAnimation(.easeInOut(duration: 0.3)) {
                    step = 1
                }
            }
        case 1:
            primaryButton("次へ") {
                withAnimation(.easeInOut(duration: 0.3)) {
                    step = 2
                }
            }
        default:
            primaryButton("ダッシュボードへ") {
                onComplete()
            }
        }
    }

    // MARK: - Primary Button

    private func primaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(.horizontal, 24)
    }
}

#Preview {
    OnboardingView(onComplete: {})
}
