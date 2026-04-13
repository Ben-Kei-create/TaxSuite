import SwiftUI
import AVFoundation

// MARK: - OnboardingView

struct OnboardingView: View {
    @AppStorage("taxRate") var taxRate: Double = 0.2
    @AppStorage("taxSuiteSenderName") var senderName: String = ""
    @AppStorage("taxSuiteBusinessName") var businessName: String = ""

    var onComplete: () -> Void

    @State private var step: Int = 0

    // Permissions
    @State private var cameraGranted = false
    @State private var cameraChecked = false

    // Entrance animations
    @State private var heroAppeared = false

    private let stepTransition: AnyTransition = .asymmetric(
        insertion: .move(edge: .trailing).combined(with: .opacity),
        removal: .move(edge: .leading).combined(with: .opacity)
    )

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            VStack(spacing: 0) {
                // Step content
                ZStack {
                    if step == 0 {
                        welcomeStep.transition(stepTransition)
                    } else if step == 1 {
                        personalizeStep.transition(stepTransition)
                    } else {
                        permissionsStep.transition(stepTransition)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Progress dots
                progressDots
                    .padding(.top, 16)
                    .padding(.bottom, 14)

                // Bottom button
                stepButton
                    .padding(.bottom, 36)
            }
        }
        .onAppear {
            checkCameraStatus()
            withAnimation(.spring(response: 0.7, dampingFraction: 0.8).delay(0.15)) {
                heroAppeared = true
            }
        }
    }

    // MARK: - Step 0 : Welcome

    private var welcomeStep: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                // Hero icon
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 110, height: 110)
                        .shadow(color: .black.opacity(0.06), radius: 24, x: 0, y: 14)
                        .overlay(Circle().stroke(Color.black.opacity(0.04), lineWidth: 1))

                    Image("SplashIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .scaleEffect(heroAppeared ? 1.0 : 0.82)
                .opacity(heroAppeared ? 1 : 0)
                .padding(.top, 48)
                .padding(.bottom, 32)

                // Title
                Text("ようこそ、TaxSuiteへ")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .tracking(-0.5)
                    .foregroundColor(.black)
                    .padding(.bottom, 10)

                Text("フリーランスの経費・税金を、\nもっとシンプルに。")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.bottom, 40)

                // Feature cards
                VStack(spacing: 14) {
                    featureCard(
                        icon: "camera.viewfinder",
                        iconColor: .black,
                        title: "カメラでレシート一発入力",
                        subtitle: "OCR が金額・日付を自動読み取り"
                    )
                    featureCard(
                        icon: "bolt.fill",
                        iconColor: .orange,
                        title: "ショートカットで1秒記録",
                        subtitle: "ウィジェット＆クイック追加ボタン"
                    )
                    featureCard(
                        icon: "yensign.circle.fill",
                        iconColor: .blue,
                        title: "売上から手取りを自動計算",
                        subtitle: "税額・経費を差し引いたリアルな手取り"
                    )
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .padding(.horizontal, 24)
        }
    }

    private func featureCard(icon: String, iconColor: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(iconColor)
                .frame(width: 44, height: 44)
                .background(iconColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.black)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.black.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Step 1 : Personalize

    private var personalizeStep: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 48))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.black, .black.opacity(0.6)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .padding(.top, 48)
                    .padding(.bottom, 20)

                Text("基本情報を設定")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.black)
                    .padding(.bottom, 6)

                Text("あとから設定でいつでも変更できます")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 28)

                // Card
                VStack(spacing: 0) {
                    // Tax rate
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("推定税率")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text("\(Int(taxRate * 100))%")
                                .font(.system(.title3, design: .rounded).weight(.bold))
                                .monospacedDigit()
                                .foregroundColor(.black)
                        }
                        Slider(value: $taxRate, in: 0.1...0.5, step: 0.05)
                            .tint(.black)
                    }
                    .padding(16)

                    Divider().padding(.horizontal, 16)

                    // Sender name
                    HStack(spacing: 12) {
                        Image(systemName: "person.fill")
                            .foregroundColor(.secondary)
                            .frame(width: 18)
                        TextField("お名前 / ハンドルネーム", text: $senderName)
                    }
                    .padding(16)

                    Divider().padding(.horizontal, 16)

                    // Business name
                    HStack(spacing: 12) {
                        Image(systemName: "building.2.fill")
                            .foregroundColor(.secondary)
                            .frame(width: 18)
                        TextField("屋号・事業名（任意）", text: $businessName)
                    }
                    .padding(16)
                }
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.06), radius: 14, x: 0, y: 6)
                .padding(.bottom, 16)

                Text("税率は売上規模で変わります。わからなければ 20% のままで OK。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 40)
            }
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Step 2 : Permissions

    private var permissionsStep: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                // Hero
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.black.opacity(0.04), Color.clear],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 120, height: 120)

                    Image(systemName: cameraGranted ? "checkmark.seal.fill" : "camera.circle.fill")
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: cameraGranted
                                    ? [.green, .green.opacity(0.7)]
                                    : [.black, .black.opacity(0.65)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .contentTransition(.symbolEffect(.replace))
                }
                .padding(.top, 48)
                .padding(.bottom, 28)

                Text(cameraGranted ? "準備完了です!" : "あと少しで準備完了")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.black)
                    .padding(.bottom, 10)

                Text(cameraGranted
                     ? "すべての設定が整いました。\nさっそく最初の経費を記録してみましょう。"
                     : "レシートを魔法のように読み取るため、\nカメラへのアクセスが必要です。")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.bottom, 36)

                if !cameraGranted {
                    Button {
                        requestCameraAccess()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 16, weight: .semibold))
                            Text("カメラを許可する")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundColor(.black)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                        .background(Color.black.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .padding(.bottom, 12)

                    Button("あとで設定する") {
                        withAnimation(.spring(response: 0.4)) {
                            cameraChecked = true
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 28)
                }

                // Tips
                VStack(spacing: 14) {
                    tipCard(icon: "bolt.fill", color: .orange,
                            text: "クイック追加は長押しで金額やカテゴリを編集できます")
                    tipCard(icon: "square.grid.2x2.fill", color: .purple,
                            text: "ホーム画面ウィジェットでワンタップ経費記録")
                    tipCard(icon: "chart.pie.fill", color: .blue,
                            text: "分析タブで経費の内訳と推移をいつでもチェック")
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .padding(.horizontal, 24)
        }
    }

    private func tipCard(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(12)
        .background(Color.black.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Progress Dots

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<3) { index in
                Capsule()
                    .fill(index == step ? Color.black : Color.black.opacity(0.12))
                    .frame(width: index == step ? 24 : 8, height: 8)
                    .animation(.spring(response: 0.35, dampingFraction: 0.75), value: step)
            }
        }
    }

    // MARK: - Step Button

    @ViewBuilder
    private var stepButton: some View {
        switch step {
        case 0:
            primaryButton("はじめる") {
                advance()
            }
        case 1:
            primaryButton("次へ") {
                advance()
            }
        default:
            primaryButton("ダッシュボードへ", isActive: cameraGranted || cameraChecked) {
                onComplete()
            }
        }
    }

    private func primaryButton(_ label: String, isActive: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(isActive ? Color.black : Color.black.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .disabled(!isActive)
        .padding(.horizontal, 24)
    }

    // MARK: - Helpers

    private func advance() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            step += 1
        }
    }

    private func checkCameraStatus() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        cameraGranted = (status == .authorized)
        cameraChecked = (status == .authorized || status == .denied || status == .restricted)
    }

    private func requestCameraAccess() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.4)) {
                    cameraGranted = granted
                    cameraChecked = true
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    OnboardingView(onComplete: {})
}
