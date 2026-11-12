import AVFoundation
import Speech
import SwiftUI
import UIKit

@MainActor
struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var session = VoiceSession.shared
    @ObservedObject private var settings = AssistantSettings.shared
    @ObservedObject private var timeline = ChatTimeline.shared
    @ObservedObject private var navigation = AppNavigation.shared
    @State private var page: ChatDestination?
    @State private var pendingSharingAction: SharingAction?
    @State private var showingSharingConsent = false
    @State private var showingOnboarding = false
    @State private var confirmingClearHistory = false
    @State private var messageToDelete: UUID?
    @State private var historyActionError: String?
    @State private var configureAfterOnboarding = false
    @State private var draftMessage = ""
    @State private var position = ScrollPosition(idType: UUID.self, edge: .bottom)
    @State private var metrics = ChatScrollMetrics()
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var followsLatest = true
    @State private var isPaging = false
    @State private var scrollPhase: ScrollPhase = .idle
    @State private var pagingGeneration = UUID()
    @FocusState private var composerFocused: Bool
    #if DEBUG && targetEnvironment(simulator)
    @State private var previewVoiceState: VoiceSession.Phase?
    #endif

    init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--show-settings") { _page = State(initialValue: .settings) }
        else if arguments.contains("--show-memory") { _page = State(initialValue: .memory) }
        else if arguments.contains("--show-reminders") { _page = State(initialValue: .reminders) }
        #endif
        #if DEBUG && targetEnvironment(simulator)
        if let value = ProcessInfo.processInfo.environment["FINDY_UI_TEST_SESSION"], UUID(uuidString: value) != nil {
            let args = ProcessInfo.processInfo.arguments
            if let input = ProcessInfo.processInfo.environment["FINDY_UI_TEST_DRAFT"] {
                _draftMessage = State(initialValue: AssistantLimits.clipped(input, to: AssistantLimits.inputCharacters))
            }
            let phase: VoiceSession.Phase? = args.contains("--preview-voice-listening") ? .listening
                : args.contains("--preview-voice-thinking") ? .thinking
                : args.contains("--preview-voice-speaking") ? .speaking
                : args.contains("--preview-voice-stopping") ? .stopping : nil
            _previewVoiceState = State(initialValue: phase)
        }
        #endif
    }

    private var needsPermissions: Bool {
        AVAudioApplication.shared.recordPermission != .granted
            || (!settings.usesProviderVoice && SFSpeechRecognizer.authorizationStatus() != .authorized)
    }
    private var visibleRecords: [StoredMessage] {
        timeline.records.filter { !$0.message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    private var visibleStreamingReply: AssistantMessage? {
        guard timeline.isAtLatest, let reply = session.streamingReply, !reply.text.isEmpty,
              !visibleRecords.contains(where: { $0.id == reply.id }) else { return nil }
        return reply
    }
    private var actualError: String? { session.lastError ?? timeline.lastError }
    private var historyMutationAllowed: Bool { session.phase == .idle && !session.isRunning && !session.isSendingText }
    private var previewVoicePhase: VoiceSession.Phase? {
        #if DEBUG && targetEnvironment(simulator)
        return previewVoiceState
        #else
        return nil
        #endif
    }
    private var voiceComposerActive: Bool { session.isRunning || session.phase != .idle || previewVoicePhase != nil }
    private var displayedVoicePhase: VoiceSession.Phase { previewVoicePhase ?? session.phase }
    private var voiceIsStopping: Bool { displayedVoicePhase == .stopping }
    private var voiceComposerStatus: String {
        switch displayedVoicePhase {
        case .idle, .starting: return "Подключаюсь…"
        case .listening: return "Слушаю"
        case .thinking: return "Думаю…"
        case .speaking: return "Говорю"
        case .stopping: return "Завершаю…"
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            ScrollView {
                // The timeline is bounded to 120 rows. Measuring this bounded
                // window avoids lazy estimated heights shifting the bottom and
                // paging anchors as long messages and source chips appear.
                VStack(alignment: .leading, spacing: 15) {
                    if timeline.hasOlder {
                        Button("Ранее") { paginate(.older) }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .disabled(isPaging)
                            .accessibilityIdentifier("chat-load-older")
                    }
                    ForEach(visibleRecords) { record in
                        ConversationMessageView(message: record.message, canDelete: historyMutationAllowed) {
                            messageToDelete = record.id
                        }
                            .containerRelativeFrame(.horizontal) { width, _ in max(0, width - 36) }
                            .id(record.id)
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(key: ChatRowFrames.self, value: [record.id: geometry.frame(in: .named("chatViewport"))])
                                }
                            }
                    }
                    if let reply = visibleStreamingReply {
                        ConversationMessageView(message: reply)
                            .containerRelativeFrame(.horizontal) { width, _ in max(0, width - 36) }
                            .id(reply.id)
                    }
                    if timeline.isAtLatest && (session.phase == .thinking || session.isSendingText)
                        && visibleStreamingReply == nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Готовлю ответ…").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                    }
                    if timeline.hasNewer {
                        Button("Позже") { paginate(.newer) }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .disabled(isPaging)
                            .accessibilityIdentifier("chat-load-newer")
                    }
                    Color.clear.frame(height: 1)
                }
                .scrollTargetLayout()
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 14)
            }
            .accessibilityIdentifier("chat-history")
            .coordinateSpace(name: "chatViewport")
            .scrollPosition($position)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .scrollDismissesKeyboard(.interactively)
            .onPreferenceChange(ChatRowFrames.self) { rowFrames = $0 }
            .onScrollPhaseChange { _, next in
                scrollPhase = next
                if next == .idle && followsLatest && timeline.isAtLatest { scrollToBottom() }
            }
            .onScrollGeometryChange(for: ChatScrollMetrics.self) { geometry in
                return ChatScrollMetrics(
                    offset: geometry.contentOffset.y + geometry.contentInsets.top,
                    distanceToBottom: max(0, geometry.contentSize.height - geometry.visibleRect.maxY),
                    viewportHeight: geometry.containerSize.height,
                    topInset: geometry.contentInsets.top,
                    bottomInset: geometry.contentInsets.bottom
                )
            } action: { old, new in
                metrics = new
                guard !isPaging else { return }
                let userScrolling = scrollPhase == .interacting || scrollPhase == .decelerating
                if !userScrolling && followsLatest && timeline.isAtLatest &&
                    (old.viewportHeight != new.viewportHeight || old.topInset != new.topInset || old.bottomInset != new.bottomInset) {
                    scrollToBottom()
                }
                if userScrolling {
                    setFollowing(new.distanceToBottom < 60 && timeline.isAtLatest)
                    if new.offset < 220 && new.offset < old.offset - 0.5 && timeline.hasOlder { paginate(.older) }
                    else if new.distanceToBottom < 220 && new.offset > old.offset + 0.5 && timeline.hasNewer { paginate(.newer) }
                }
            }
            .onChange(of: timeline.records) { _, _ in
                if followsLatest && timeline.isAtLatest && !isPaging { scrollToBottom() }
            }
            .onChange(of: session.streamingReply?.text) { _, _ in
                if followsLatest && timeline.isAtLatest && !isPaging { scrollToBottom() }
            }
            .onChange(of: session.isSendingText) { _, _ in
                if followsLatest && timeline.isAtLatest && !isPaging { scrollToBottom() }
            }
            .overlay(alignment: .bottomTrailing) {
                if !followsLatest || timeline.hasNewer {
                    Button(action: jumpToLatest) {
                        Image(systemName: "arrow.down")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .background(.regularMaterial, in: Circle())
                            .overlay { Circle().strokeBorder(.quaternary, lineWidth: 1) }
                    }
                    .buttonStyle(.plain)
                    .padding(14)
                    .accessibilityLabel("К последним сообщениям")
                    .accessibilityIdentifier("chat-jump-latest")
                }
            }
            .overlay {
                if timeline.totalCount == 0 && session.streamingReply == nil && !voiceComposerActive {
                    emptyState.padding(.horizontal, 24)
                }
            }
            .background(Color(.systemBackground))
            composer
            }
            .navigationTitle("Findy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Память", systemImage: "brain") { page = .memory }
                        Button("Напоминания", systemImage: "bell") { navigation.openReminder(id: nil) }
                        Button("Настройки", systemImage: "gearshape") { page = .settings }
                    } label: {
                        Label("Меню Findy", systemImage: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("findy-menu")
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        FindyMark().foregroundStyle(Color.accentColor)
                            .frame(width: 31, height: 15)
                            .accessibilityHidden(true)
                        Text("Findy").font(.headline)
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { confirmingClearHistory = true } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(!historyMutationAllowed || timeline.totalCount == 0)
                    .accessibilityLabel("Очистить чат")
                    .accessibilityIdentifier("chat-clear")
                }
            }
            .alert("Очистить чат?", isPresented: $confirmingClearHistory) {
                Button("Отмена", role: .cancel) { }
                Button("Очистить чат", role: .destructive) {
                    guard historyMutationAllowed else { return }
                    do { try timeline.deleteHistory(); jumpToLatest() }
                    catch { historyActionError = error.localizedDescription }
                }
            } message: { Text("Сообщения удалятся. Память и напоминания сохранятся.") }
            .alert("Удалить сообщение?", isPresented: Binding(
                get: { messageToDelete != nil }, set: { if !$0 { messageToDelete = nil } }
            )) {
                Button("Отмена", role: .cancel) { messageToDelete = nil }
                Button("Удалить сообщение", role: .destructive) {
                    guard historyMutationAllowed, let id = messageToDelete else { return }
                    do { try timeline.deleteMessage(id: id) }
                    catch { historyActionError = error.localizedDescription }
                    messageToDelete = nil
                }
            }
            .alert("Не удалось изменить историю", isPresented: Binding(
                get: { historyActionError != nil }, set: { if !$0 { historyActionError = nil } }
            )) {
                Button("Понятно", role: .cancel) { historyActionError = nil }
            } message: { Text(historyActionError ?? "") }
            .sheet(item: $page, onDismiss: {
                if page == nil {
                    navigation.showingReminders = false
                    navigation.selectedReminderID = nil
                }
            }) { destination in
                switch destination {
                case .memory: MemoryView()
                case .reminders: RemindersView()
                case .settings: SettingsView()
                }
            }
            .fullScreenCover(isPresented: $showingOnboarding, onDismiss: {
                if configureAfterOnboarding {
                    configureAfterOnboarding = false
                    page = .settings
                }
            }) {
                OnboardingView(onClose: { showingOnboarding = false }, onConfigure: {
                    configureAfterOnboarding = true
                    showingOnboarding = false
                })
            }
            .alert("Разрешить передачу данных?", isPresented: $showingSharingConsent) {
                Button("Отмена", role: .cancel) { pendingSharingAction = nil }
                Button("Разрешить") {
                    guard let provider = settings.selectedProvider else { return }
                    settings.grantSharing(for: provider)
                    let action = pendingSharingAction
                    pendingSharingAction = nil
                    if action == .text { sendMessage() }
                    else if action == .voice { handleVoiceButton() }
                }
            } message: {
                Text(sharingDescription)
            }
            .onAppear {
                session.refreshReadiness()
                if !settings.isConfiguredForChat && !settings.hasSeenOnboarding { showingOnboarding = true }
                if navigation.showingReminders { page = .reminders }
                timeline.setFollowingLatest(followsLatest)
                if followsLatest && timeline.isAtLatest { scrollToBottom() }
            }
            .onChange(of: voiceComposerActive, initial: true) { _, active in
                if active { composerFocused = false }
            }
            #if DEBUG && targetEnvironment(simulator)
            .task(id: draftMessage) {
                // A simulated external start tests Siri-style focus changes
                // without opening the microphone or modifying VoiceSession.
                guard let value = ProcessInfo.processInfo.environment["FINDY_UI_TEST_SESSION"], UUID(uuidString: value) != nil,
                      ProcessInfo.processInfo.arguments.contains("--ui-preview-voice"),
                      !draftMessage.isEmpty, previewVoiceState == nil else { return }
                do { try await Task.sleep(for: .milliseconds(1200)) }
                catch { return }
                guard !Task.isCancelled else { return }
                previewVoiceState = .listening
            }
            #endif
            .onChange(of: navigation.showingReminders) { _, show in
                if show { composerFocused = false; page = .reminders }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            FindyMark()
                .foregroundStyle(Color.gray.opacity(0.11))
                .frame(width: 144, height: 64)
                .accessibilityHidden(true)
            if !settings.isConfiguredForChat {
                Text("Приложение не настроено")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Настроить") { page = .settings }
                    .font(.subheadline.weight(.medium))
                    .accessibilityIdentifier("chat-setup")
            }
        }
        .multilineTextAlignment(.center)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if let error = actualError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error.components(separatedBy: .newlines).first ?? error)
                        .fixedSize(horizontal: false, vertical: true)
                    if timeline.lastError != nil && session.lastError == nil {
                        Button("Повторить", action: jumpToLatest)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !voiceComposerActive {
                // Keep the intrinsic line height while hidden so crossing the
                // threshold never moves the chat or composer, at any text size.
                CharacterLimitCounter(count: draftMessage.count, limit: AssistantLimits.inputCharacters)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 16)
                    .opacity(showsDraftCharacterCount ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityRepresentation {
                        // An empty accessibility representation also removes the
                        // hidden caption from native automation/VoiceOver trees.
                        if showsDraftCharacterCount {
                            CharacterLimitCounter(count: draftMessage.count, limit: AssistantLimits.inputCharacters)
                                .accessibilityIdentifier("chat-character-count")
                        }
                    }
                    .accessibilityHidden(!showsDraftCharacterCount)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Group {
                    if voiceComposerActive {
                        HStack(spacing: 10) {
                            Text(voiceComposerStatus)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .accessibilityAddTraits(.updatesFrequently)
                            VoiceComposerWave(phase: displayedVoicePhase, isPresented: page == nil && !showingOnboarding)
                                .frame(maxWidth: .infinity)
                                .frame(height: 34)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 50)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("chat-voice-composer")
                    } else {
                        HStack(alignment: .bottom, spacing: 0) {
                            TextField("Сообщение…", text: Binding(
                                get: { draftMessage },
                                set: { draftMessage = AssistantLimits.clipped($0, to: AssistantLimits.inputCharacters) }
                            ), axis: .vertical)
                                .lineLimit(1...5)
                                .font(.body)
                                .textInputAutocapitalization(.sentences)
                                .submitLabel(.send)
                                .focused($composerFocused)
                                .onSubmit(sendMessage)
                                .padding(.leading, 16)
                                .padding(.vertical, 13)
                                .accessibilityLabel("Текст сообщения")
                                .accessibilityIdentifier("chat-composer")
                            Button {
                                if session.isSendingText { session.cancelTextReply() } else { sendMessage() }
                            } label: {
                                Image(systemName: session.isSendingText ? "stop.fill" : "arrow.up")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(sendEnabled ? Color(.systemBackground) : Color.secondary)
                                    .frame(width: 36, height: 36)
                                    .background(sendEnabled ? Color.accentColor : Color(.tertiarySystemFill), in: Circle())
                                    .frame(width: 44, height: 50)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!sendEnabled)
                            .accessibilityLabel(session.isSendingText ? "Остановить ответ" : "Отправить сообщение")
                            .accessibilityIdentifier("chat-send")
                            .keyboardShortcut(.return, modifiers: .command)
                            .padding(.trailing, 3)
                        }
                    }
                }
                .findyComposerGlass(in: RoundedRectangle(cornerRadius: 25))
                if voiceComposerActive {
                    Button(action: stopVoiceConversation) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(0.8))
                            .frame(width: 48, height: 48)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .findyComposerGlass(in: Circle(), interactive: true)
                    .disabled(voiceIsStopping)
                    .accessibilityLabel("Завершить голосовой разговор")
                    .accessibilityIdentifier("chat-voice-stop")
                    .padding(.bottom, 1)
                } else if draftMessage.isEmpty && !session.isSendingText {
                    Button(action: handleVoiceButton) {
                        Image(systemName: "mic")
                            .font(.system(size: 21, weight: .medium))
                            .foregroundStyle(Color.primary)
                            .frame(width: 48, height: 48)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .findyComposerGlass(in: Circle(), interactive: true)
                    .accessibilityLabel(needsPermissions ? "Разрешить микрофон" : "Начать голосовой разговор")
                    .accessibilityIdentifier("chat-microphone")
                    .padding(.bottom, 1)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: draftMessage.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 8)
    }

    private var showsDraftCharacterCount: Bool {
        draftMessage.count >= AssistantLimits.inputCharacters * 4 / 5
    }

    private var sendEnabled: Bool {
        session.isSendingText || (draftMessage.count <= AssistantLimits.inputCharacters
            && !draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func setFollowing(_ value: Bool) {
        followsLatest = value
        timeline.setFollowingLatest(value)
    }

    private func scrollToBottom() {
        Task { @MainActor in
            await Task.yield()
            guard followsLatest, timeline.isAtLatest, !isPaging, scrollPhase == .idle else { return }
            position.scrollTo(edge: .bottom)
        }
    }

    private func jumpToLatest() {
        pagingGeneration = UUID()
        isPaging = false
        setFollowing(true)
        timeline.loadLatest()
        scrollToBottom()
    }

    private func paginate(_ direction: ChatPageDirection) {
        guard !isPaging, !timeline.isLoading else { return }
        let visible = rowFrames.filter { $0.value.maxY > 0 && $0.value.minY < metrics.viewportHeight }.sorted { $0.value.minY < $1.value.minY }
        let visibleAnchor = direction == .older ? visible.first : visible.last
        let remembered = visibleAnchor.map { ChatVisibleAnchor(id: $0.key, minY: $0.value.minY) }
        let token = UUID()
        pagingGeneration = token
        isPaging = true
        setFollowing(false)
        let fallback = direction == .older ? timeline.loadOlder() : timeline.loadNewer()
        Task { @MainActor in
            // SwiftUI first lays out the inserted/trimmed bounded rows. Restore the
            // retained visible row's measured offset without animating the page.
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(30))
            guard pagingGeneration == token else { return }
            if let remembered, let frame = rowFrames[remembered.id] {
                let delta = frame.minY - remembered.minY
                if abs(delta) > 1 { position.scrollTo(y: max(0, metrics.offset + delta)) }
            } else if let fallback {
                position.scrollTo(id: fallback, anchor: direction == .older ? .top : .bottom)
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(30))
            guard pagingGeneration == token else { return }
            isPaging = false
            if metrics.distanceToBottom < 60 && timeline.isAtLatest { setFollowing(true) }
        }
    }

    private var sharingDescription: String {
        let provider = settings.selectedProvider
        let recipient = "\(provider?.name ?? "Провайдер") · \(URL(string: settings.configuration.endpoint)?.host ?? settings.configuration.endpoint)"
        return "\(recipient)\n\nСообщения и сохранённая память передаются этому сервису для ответа. В режиме «Провайдер» также передаётся аудио. Обработка данных определяется условиями сервиса. Разрешение можно отозвать в настройках."
    }

    private func ensureSharing(_ action: SharingAction) -> Bool {
        guard !settings.providerSharingAllowed else { return true }
        // Let the session present its actionable endpoint validation error.
        guard (try? settings.configuration.validatedEndpoint()) != nil else { return true }
        pendingSharingAction = action
        showingSharingConsent = true
        return false
    }

    private func sendMessage() {
        guard settings.isConfiguredForChat else { page = .settings; return }
        guard !voiceComposerActive, !session.isSendingText, sendEnabled, ensureSharing(.text) else { return }
        if session.sendText(draftMessage) {
            draftMessage = ""
            jumpToLatest()
        }
    }

    private func stopVoiceConversation() {
        guard voiceComposerActive, !voiceIsStopping else { return }
        #if DEBUG && targetEnvironment(simulator)
        if previewVoiceState != nil {
            previewVoiceState = .stopping
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                previewVoiceState = nil
            }
            return
        }
        #endif
        Task { await session.stop(reason: "Кнопка в приложении") }
    }

    private func handleVoiceButton() {
        guard settings.isConfiguredForChat else { page = .settings; return }
        guard !session.isSendingText, session.isRunning || ensureSharing(.voice) else { return }
        composerFocused = false
        if !session.isRunning { jumpToLatest() }
        Task {
            if session.isRunning { await session.stop(reason: "Кнопка в приложении") }
            else {
                if needsPermissions { await session.requestPermissions() }
                if !needsPermissions { try? await session.start(source: "UI") }
            }
        }
    }
}

private enum SharingAction { case text, voice }

private enum ChatDestination: String, Identifiable {
    case memory, reminders, settings
    var id: String { rawValue }
}
private enum ChatPageDirection { case older, newer }
private struct ChatVisibleAnchor { let id: UUID; let minY: CGFloat }
private struct ChatScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var distanceToBottom: CGFloat = 0
    var viewportHeight: CGFloat = 0
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
}
private struct ChatRowFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct ConversationMessageView: View {
    let message: AssistantMessage
    var canDelete = false
    var onDelete: (() -> Void)? = nil
    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 42) }
            VStack(alignment: .leading, spacing: 7) {
                Text(message.text)
                    .font(.body)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !message.sources.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(message.sources) { source in
                                Link(destination: source.url) {
                                    Label(source.url.host ?? source.title, systemImage: "arrow.up.right")
                                        .font(.caption)
                                        .lineLimit(1)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 5)
                                        .background(Color(.tertiarySystemFill), in: Capsule())
                                        .frame(minHeight: 38)
                                }
                                .accessibilityLabel(source.title.isEmpty ? source.url.absoluteString : source.title)
                            }
                        }
                    }
                }
            }
            .padding(isUser ? 12 : 0)
            .background(isUser ? Color.accentColor.opacity(0.11) : Color.clear, in: RoundedRectangle(cornerRadius: 18))
            .contextMenu {
                Button("Копировать", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
                if let onDelete {
                    Button("Удалить", systemImage: "trash", role: .destructive, action: onDelete)
                        .disabled(!canDelete)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(isUser ? "Вы" : "Findy")
            if !isUser { Spacer(minLength: 5) }
        }
        .padding(.vertical, isUser ? 0 : 3)
    }
}
