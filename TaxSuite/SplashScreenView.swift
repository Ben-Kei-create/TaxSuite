import SwiftUI
import SwiftData

struct TaxSuiteLaunchContainerView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    @State private var showContent = false
    @State private var isShowingSplash = true
    @State private var isSplashExiting = false
    @State private var hasStartedLaunchSequence = false

    var body: some View {
        ZStack {
            if showContent {
                ContentView()
                    .transition(.opacity)
            } else {
                Color.white.ignoresSafeArea()
            }

            if isShowingSplash {
                SplashScreenView(isExiting: isSplashExiting)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .task {
            guard !hasStartedLaunchSequence else { return }
            hasStartedLaunchSequence = true

            try? await Task.sleep(for: .milliseconds(1350))

            await MainActor.run {
                withAnimation(.easeOut(duration: 0.28)) {
                    showContent = true
                }
                withAnimation(.easeInOut(duration: 0.58)) {
                    isSplashExiting = true
                }
            }

            try? await Task.sleep(for: .milliseconds(520))

            await MainActor.run {
                isShowingSplash = false
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { showContent && !isShowingSplash && !hasCompletedOnboarding },
            set: { _ in }
        )) {
            OnboardingView {
                hasCompletedOnboarding = true
            }
        }
    }
}

struct SplashScreenView: View {
    var isExiting: Bool

    @State private var hasEntered = false
    @State private var iconSheenOffset: CGFloat = -140
    @State private var textSheenOffset: CGFloat = -220
    @State private var shadowStrength = 0.0
    @State private var ambientGlow = 0.0

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            backgroundShade

            VStack(spacing: 22) {
                brandMark

                VStack(spacing: 8) {
                    shadedTitle

                    Text("整えて、軽くする")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .tracking(1.2)
                        .foregroundColor(Color.black.opacity(0.38))
                }
            }
            .scaleEffect(isExiting ? 1.06 : (hasEntered ? 1.0 : 0.93))
            .opacity(isExiting ? 0 : (hasEntered ? 1.0 : 0))
            .offset(y: isExiting ? -28 : (hasEntered ? 0 : 12))
            .blur(radius: isExiting ? 6 : 0)
        }
        .onAppear(perform: startAnimations)
    }

    private var backgroundShade: some View {
        ZStack {
            RadialGradient(
                colors: [
                    Color.white,
                    Color(red: 0.975, green: 0.978, blue: 0.988).opacity(ambientGlow),
                    Color.white
                ],
                center: .center,
                startRadius: 30,
                endRadius: 280
            )
            .ignoresSafeArea()

            Ellipse()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.03 * shadowStrength),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 260, height: 110)
                .blur(radius: 16)
                .offset(y: 78)
        }
    }

    private var brandMark: some View {
        ZStack {
            Circle()
                .fill(Color.white)
                .frame(width: 98, height: 98)
                .shadow(color: Color.black.opacity(0.08 + (0.08 * shadowStrength)), radius: 26, x: 0, y: 16)
                .overlay(
                    Circle()
                        .stroke(Color.black.opacity(0.04), lineWidth: 1)
                )

            Image(systemName: "chart.line.uptrend.xyaxis.circle.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color.black,
                            Color.black.opacity(0.72)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    splashSheen(width: 66, height: 90, offset: iconSheenOffset)
                        .mask(
                            Image(systemName: "chart.line.uptrend.xyaxis.circle.fill")
                                .font(.system(size: 44, weight: .semibold))
                        )
                }
        }
    }

    private var shadedTitle: some View {
        Text("TaxSuite")
            .font(.system(size: 34, weight: .bold, design: .rounded))
            .tracking(-0.9)
            .foregroundStyle(
                LinearGradient(
                    colors: [
                        Color.black,
                        Color.black.opacity(0.66)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                splashSheen(width: 112, height: 70, offset: textSheenOffset)
                    .mask(
                        Text("TaxSuite")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .tracking(-0.9)
                    )
            }
    }

    private func splashSheen(width: CGFloat, height: CGFloat, offset: CGFloat) -> some View {
        LinearGradient(
            colors: [
                Color.white.opacity(0.0),
                Color.white.opacity(0.95),
                Color.white.opacity(0.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(width: width, height: height)
        .rotationEffect(.degrees(18))
        .offset(x: offset)
        .blendMode(.screen)
    }

    private func startAnimations() {
        withAnimation(.spring(response: 0.7, dampingFraction: 0.82)) {
            hasEntered = true
        }

        withAnimation(.easeInOut(duration: 0.55).delay(0.12)) {
            shadowStrength = 1.0
            ambientGlow = 1.0
        }

        withAnimation(.easeInOut(duration: 0.82).delay(0.18)) {
            iconSheenOffset = 138
        }

        withAnimation(.easeInOut(duration: 0.92).delay(0.28)) {
            textSheenOffset = 210
        }
    }
}

#Preview("Splash") {
    SplashScreenView(isExiting: false)
}

#Preview("Launch Container") {
    TaxSuiteLaunchContainerView()
        .modelContainer(for: [ExpenseItem.self, RecurringExpense.self, IncomeItem.self], inMemory: true)
}
