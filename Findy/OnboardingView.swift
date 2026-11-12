import SwiftUI

@MainActor
struct OnboardingView: View {
    @ObservedObject private var settings = AssistantSettings.shared
    @State private var page = 0

    let onClose: () -> Void
    let onConfigure: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    card(
                        image: "OnboardingHandsFree", fallback: "airpods",
                        title: "Говорите, не доставая iPhone",
                        detail: "Findy работает в фоне: через Siri и AirPods, даже с заблокированным экраном."
                    )
                    .tag(0)
                    card(
                        image: "OnboardingShortcuts", fallback: "square.stack.3d.up",
                        title: "Добавьте команду Siri",
                        detail: "Кнопка откроет готовую команду «Давай поболтаем» в «Командах». Подтвердите добавление и разрешите Siri при блокировке iPhone.",
                        showsShortcuts: true
                    )
                    .tag(1)
                    card(
                        image: "OnboardingProvider", fallback: "network",
                        title: "Подключите свою модель",
                        detail: "Добавьте провайдера и выберите модель в настройках."
                    )
                    .tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                Button {
                    if page < 2 {
                        withAnimation { page += 1 }
                    } else {
                        settings.completeOnboarding()
                        onConfigure()
                    }
                } label: {
                    Text(page < 2 ? "Далее" : "Настроить Findy")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("onboarding-next")
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Знакомство с Findy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Пропустить") {
                        settings.completeOnboarding()
                        onClose()
                    }
                    .accessibilityIdentifier("onboarding-skip")
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private func card(image: String, fallback: String, title: String, detail: String, showsShortcuts: Bool = false) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Group {
                    if UIImage(named: image) != nil {
                        Image(image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: fallback)
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(Color.accentColor)
                            .padding(64)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 240)
                .accessibilityHidden(true)

                Text(title)
                    .font(.largeTitle.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if showsShortcuts {
                    AddChatShortcutButton(accessibilityIdentifier: "onboarding-shortcuts-link")
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 44)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }
}
