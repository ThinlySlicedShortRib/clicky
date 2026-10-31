//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import ServiceManagement
import SwiftUI
import Sparkle

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()
    private var sparkleUpdaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A CLI that exits while its stdin is being written raises SIGPIPE,
        // which would otherwise kill the whole app instead of failing the call.
        signal(SIGPIPE, SIG_IGN)

        // Headless flags run a scripted check and exit without any menu bar
        // UI, so child agents can verify the app without a human at the hotkey.
        if let headlessCommand = HeadlessCommand.parse(arguments: CommandLine.arguments) {
            Task {
                await HeadlessCommandRunner(companionManager: companionManager).run(headlessCommand)
            }
            return
        }

        print("🎯 Clicky: Starting...")
        print("🎯 Clicky: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        // Onboarding off by default: it streams a remote video, plays music, and
        // collects an email, none of which belong in a demo base. The panel's
        // "Watch Onboarding Again" link still replays it.
        UserDefaults.standard.register(defaults: [
            "NSInitialToolTipDelay": 0,
            "hasCompletedOnboarding": true
        ])

        ClickyAnalytics.configure()
        ClickyAnalytics.trackAppOpened()

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()

        // For scripts/demo-stuck.sh and scripts/prove-privacy.sh, which print
        // the consent sentence first. Neither flag can inject an event.
        if CommandLine.arguments.contains("--enable-stuck") {
            companionManager.stuckCompanion.setEnabled(true)
        }
        if CommandLine.arguments.contains("--show-stuck-receipt") {
            companionManager.stuckReceiptPanelManager.show()
        }

        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        // Not calling registerAsLoginItemIfNeeded(): it would make a dev build
        // in a scratch checkout start on every login.
        // startSparkleUpdater()
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 Clicky: Registered as login item")
            } catch {
                print("⚠️ Clicky: Failed to register as login item: \(error)")
            }
        }
    }

    private func startSparkleUpdater() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.sparkleUpdaterController = updaterController

        do {
            try updaterController.updater.start()
        } catch {
            print("⚠️ Clicky: Sparkle updater failed to start: \(error)")
        }
    }
}
