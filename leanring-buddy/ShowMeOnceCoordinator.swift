//
//  ShowMeOnceCoordinator.swift
//  leanring-buddy
//
//  Ties Show Me Once together for the panel and the hotkey: teach, compile,
//  share card, and opening a `.clicky` file. Also owns the watching indicator.
//

import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum ShowMeOncePhase: Equatable {
    case idle
    case startingRecording
    case recording
    case compilingLesson
    case failed(message: String)
}

@MainActor
final class ShowMeOnceCoordinator: ObservableObject {
    @Published private(set) var phase: ShowMeOncePhase = .idle
    /// The lesson this session made, for the panel's "show card" button.
    @Published private(set) var latestLessonPackage: LessonPackage?

    let recorder = TeachModeRecorder()
    let followController = LessonFollowController()

    private let teachModeIndicator = TeachModeIndicatorManager()
    private let shareCardWindowManager = LessonShareCardWindowManager()
    private var modelValue = BrainConfiguration.configuredModelValue
    private var teachModeHotKey: TeachModeHotKey?
    private var nestedObjectCancellables: Set<AnyCancellable> = []

    private static let teacherNameEnvironmentVariableName = "CLICKY_TEACHER_NAME"
    private static let keepRecordingsEnvironmentVariableName = "CLICKY_KEEP_RECORDINGS"

    var isTeaching: Bool {
        phase == .startingRecording || phase == .recording
    }

    /// Forwarded so the panel, which only observes this object, redraws as the
    /// recording clock and the lesson's progress move.
    init() {
        recorder.objectWillChange
            .merge(with: followController.objectWillChange)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &nestedObjectCancellables)
    }

    func start(presenter: any LessonFollowPresenter) {
        followController.attach(presenter: presenter)

        let hotKey = TeachModeHotKey { [weak self] in
            Task { @MainActor [weak self] in
                self?.toggleTeachMode()
            }
        }
        hotKey.register()
        teachModeHotKey = hotKey
    }

    func stop() {
        teachModeHotKey?.unregister()
        teachModeHotKey = nil
        followController.stop()
        teachModeIndicator.hide()
    }

    func setModelValue(_ newModelValue: String) {
        modelValue = newModelValue
        followController.setBrain(BrainConfiguration.makeBrain(modelValue: newModelValue))
    }

    // MARK: Teach

    func toggleTeachMode() {
        switch phase {
        case .recording:
            stopTeachingAndCompile()
        case .idle, .failed:
            startTeaching()
        case .startingRecording, .compilingLesson:
            break
        }
    }

    private func startTeaching() {
        followController.stop()
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        phase = .startingRecording

        Task {
            do {
                try await recorder.startRecording(teacherName: Self.teacherName())
                phase = .recording
                teachModeIndicator.show(recorder: recorder)
            } catch {
                print("⚠️ Show Me Once: couldn't start teaching: \(error.localizedDescription)")
                phase = .failed(message: error.localizedDescription)
            }
        }
    }

    private func stopTeachingAndCompile() {
        phase = .compilingLesson
        teachModeIndicator.hide()

        Task {
            do {
                let recordingDirectoryURL = try await recorder.stopRecording()
                let archiveURL = try Self.makeLessonArchiveURL()

                let compilationResult = try await LessonCompiler(
                    brain: BrainConfiguration.makeBrain(modelValue: modelValue)
                ).compile(
                    recordingDirectoryURL: recordingDirectoryURL,
                    archiveURL: archiveURL,
                    deleteRecordingAfterwards: ProcessInfo.processInfo.environment[Self.keepRecordingsEnvironmentVariableName] == nil
                )

                let lessonPackage = try LessonPackageArchiver.openArchive(at: compilationResult.archiveURL)
                latestLessonPackage = lessonPackage
                phase = .idle
                shareCardWindowManager.show(lessonPackage: lessonPackage)
            } catch {
                print("⚠️ Show Me Once: couldn't make the lesson: \(error.localizedDescription)")
                phase = .failed(message: error.localizedDescription)
            }
        }
    }

    func showLatestShareCard() {
        guard let latestLessonPackage else { return }
        shareCardWindowManager.show(lessonPackage: latestLessonPackage)
    }

    // MARK: Follow

    /// Opening a file means a person chose to start this lesson, so it runs
    /// straight away. Everything it can do is point and talk.
    func openLesson(at lessonFileURL: URL) {
        guard lessonFileURL.pathExtension.lowercased() == ClickyLesson.fileExtension else {
            phase = .failed(message: "that isn't a .clicky lesson file.")
            return
        }
        guard !isTeaching else { return }

        do {
            let lessonPackage = try LessonPackageArchiver.openArchive(at: lessonFileURL)
            shareCardWindowManager.hide()
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
            phase = .idle
            followController.start(lessonPackage: lessonPackage)
        } catch {
            print("⚠️ Show Me Once: couldn't open lesson: \(error.localizedDescription)")
            phase = .failed(message: error.localizedDescription)
        }
    }

    func chooseLessonFile() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = LessonFileType.contentTypes
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        if openPanel.runModal() == .OK, let selectedFileURL = openPanel.url {
            openLesson(at: selectedFileURL)
        }
    }

    // MARK: Files

    static func lessonsDirectoryURL() throws -> URL {
        let applicationSupportURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let lessonsDirectoryURL = applicationSupportURL.appendingPathComponent("Clicky/Lessons", isDirectory: true)
        try FileManager.default.createDirectory(at: lessonsDirectoryURL, withIntermediateDirectories: true)
        return lessonsDirectoryURL
    }

    private static func makeLessonArchiveURL() throws -> URL {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return try lessonsDirectoryURL()
            .appendingPathComponent("lesson-\(dateFormatter.string(from: Date()))")
            .appendingPathExtension(ClickyLesson.fileExtension)
    }

    /// The first name from the Mac's account, which is what the follower
    /// knows the teacher by. The environment override is for a demo Mac whose
    /// account isn't under the teacher's own name.
    static func teacherName() -> String {
        if let environmentName = ProcessInfo.processInfo.environment[teacherNameEnvironmentVariableName],
           !environmentName.isEmpty {
            return environmentName
        }
        let firstName = NSFullUserName().split(separator: " ").first.map(String.init)
        return firstName?.lowercased() ?? "your friend"
    }
}

// MARK: - File Type

enum LessonFileType {
    /// Declared in Info.plist, so this resolves in any built copy of the app.
    static let typeIdentifier = "com.yourcompany.leanring-buddy.lesson"

    static var contentTypes: [UTType] {
        [UTType(typeIdentifier) ?? UTType(filenameExtension: ClickyLesson.fileExtension) ?? .data]
    }
}

// MARK: - Watching Indicator

/// The pill at the top of the screen for as long as teach mode records. Its
/// job is to make it impossible to forget that Clicky is watching.
struct TeachModeIndicatorView: View {
    let isPausedForSecureInput: Bool
    let actionCount: Int
    let elapsedSeconds: Double

    @State private var isDotPulsing = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isPausedForSecureInput ? DS.Colors.warning : DS.Colors.overlayCursorBlue)
                .frame(width: 9, height: 9)
                .shadow(color: DS.Colors.overlayCursorBlue.opacity(isDotPulsing ? 0.9 : 0.3), radius: isDotPulsing ? 7 : 2)
                .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isDotPulsing)

            Text(isPausedForSecureInput ? "clicky looked away for your password" : "clicky is watching, because you asked")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(DS.Colors.textPrimary)

            Text(Self.clockText(forSeconds: elapsedSeconds))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(DS.Colors.textTertiary)

            Text("⌃⇧T to finish")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            Capsule().fill(Color(red: 0.07, green: 0.08, blue: 0.10).opacity(0.94))
        )
        .overlay(
            Capsule().stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
        )
        .onAppear { isDotPulsing = true }
    }

    static func clockText(forSeconds seconds: Double) -> String {
        let wholeSeconds = Int(seconds)
        return String(format: "%d:%02d", wholeSeconds / 60, wholeSeconds % 60)
    }
}

/// Redraws the indicator from the recorder without the view knowing about it,
/// which also lets the same view be rendered with fixed values for a check.
private struct TeachModeIndicatorHostView: View {
    @ObservedObject var recorder: TeachModeRecorder

    var body: some View {
        TeachModeIndicatorView(
            isPausedForSecureInput: recorder.isPausedForSecureInput,
            actionCount: recorder.recordedActionCount,
            elapsedSeconds: recorder.elapsedSeconds
        )
    }
}

@MainActor
final class TeachModeIndicatorManager {
    private static let gapBelowMenuBar: CGFloat = 8
    private static let indicatorSize = CGSize(width: 460, height: 44)

    private var indicatorPanel: NSPanel?

    func show(recorder: TeachModeRecorder) {
        hide()
        guard let targetScreen = NSScreen.main ?? NSScreen.screens.first else { return }

        let hostingView = NSHostingView(rootView:
            TeachModeIndicatorHostView(recorder: recorder)
                .frame(width: Self.indicatorSize.width, height: Self.indicatorSize.height)
        )
        hostingView.frame = NSRect(origin: .zero, size: Self.indicatorSize)

        let visibleTop = targetScreen.visibleFrame.maxY
        let panelOrigin = CGPoint(
            x: targetScreen.frame.midX - Self.indicatorSize.width / 2,
            y: visibleTop - Self.indicatorSize.height - Self.gapBelowMenuBar
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: panelOrigin, size: Self.indicatorSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        // Clicks pass straight through, so the pill can't be recorded as, or
        // get in the way of, what the teacher is showing.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hostingView
        panel.orderFrontRegardless()
        indicatorPanel = panel
    }

    func hide() {
        indicatorPanel?.orderOut(nil)
        indicatorPanel = nil
    }
}

// MARK: - Panel Section

struct ShowMeOncePanelSection: View {
    @ObservedObject var coordinator: ShowMeOnceCoordinator
    @State private var isDropTargeted = false
    @State private var isTeachButtonHovered = false
    @State private var isOpenButtonHovered = false
    @State private var isCardButtonHovered = false
    @State private var isStopButtonHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SHOW ME ONCE")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)

            content

            if case .failed(let failureMessage) = coordinator.phase {
                Text(failureMessage)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDrop(of: LessonFileType.contentTypes + [.fileURL], isTargeted: $isDropTargeted) { droppedItems in
            handleDrop(droppedItems)
        }
    }

    @ViewBuilder
    private var content: some View {
        if coordinator.phase == .compilingLesson {
            statusRow("turning that into a lesson...")
        } else if coordinator.phase == .startingRecording {
            statusRow("getting ready to watch...")
        } else if coordinator.phase == .recording {
            HStack {
                statusRow("clicky is watching, \(coordinator.recorder.recordedActionCount) actions so far")
                Spacer()
                accentButton("finish", isHovered: $isTeachButtonHovered) {
                    coordinator.toggleTeachMode()
                }
            }
        } else if coordinator.followController.isFollowing {
            HStack {
                statusRow(followStatusText)
                Spacer()
                quietButton("stop", isHovered: $isStopButtonHovered) {
                    coordinator.followController.stop()
                }
            }
        } else {
            idleContent
        }
    }

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("do something once while talking, and clicky turns it into a lesson. press \(TeachModeHotKey.displayText) to start and finish.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                accentButton("teach clicky", isHovered: $isTeachButtonHovered) {
                    coordinator.toggleTeachMode()
                }
                quietButton("open lesson", isHovered: $isOpenButtonHovered) {
                    coordinator.chooseLessonFile()
                }
                if coordinator.latestLessonPackage != nil {
                    quietButton("share card", isHovered: $isCardButtonHovered) {
                        coordinator.showLatestShareCard()
                    }
                }
            }

            Text(isDropTargeted ? "let go to start this lesson" : "or drop a .clicky file here")
                .font(.system(size: 11, weight: isDropTargeted ? .semibold : .regular))
                .foregroundColor(isDropTargeted ? DS.Colors.overlayCursorBlue : DS.Colors.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .strokeBorder(
                            isDropTargeted ? DS.Colors.overlayCursorBlue : DS.Colors.borderSubtle,
                            style: StrokeStyle(lineWidth: 0.8, dash: [4, 3])
                        )
                )
        }
    }

    private var followStatusText: String {
        let stepCount = coordinator.followController.activeLessonPackage?.lesson.steps.count ?? 0
        switch coordinator.followController.state {
        case .gettingReady:
            return "getting the lesson ready..."
        case .findingStep(let stepNumber):
            return "finding step \(stepNumber) of \(stepCount)..."
        case .waitingForFollower(let stepNumber):
            return "step \(stepNumber) of \(stepCount), your turn"
        case .checkingStep(let stepNumber):
            return "looking at step \(stepNumber)..."
        case .answeringQuestion(let stepNumber):
            return "paused on step \(stepNumber) for your question"
        case .idle, .finished, .failed:
            return "lesson"
        }
    }

    private func statusRow(_ statusText: String) -> some View {
        Text(statusText)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(DS.Colors.textSecondary)
    }

    private func accentButton(_ title: String, isHovered: Binding<Bool>, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textOnAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(isHovered.wrappedValue ? DS.Colors.accentHover : DS.Colors.accent)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovered.wrappedValue = $0 }
    }

    private func quietButton(_ title: String, isHovered: Binding<Bool>, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isHovered.wrappedValue ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovered.wrappedValue = $0 }
    }

    private func handleDrop(_ droppedItems: [NSItemProvider]) -> Bool {
        guard let droppedItem = droppedItems.first else { return false }

        _ = droppedItem.loadObject(ofClass: URL.self) { droppedFileURL, _ in
            guard let droppedFileURL else { return }
            Task { @MainActor in
                coordinator.openLesson(at: droppedFileURL)
            }
        }
        return true
    }
}
