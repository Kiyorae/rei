import AppKit
import ReiLogging
import ReiUI
import SwiftUI

@main
@MainActor
struct ReiApplication: App {
    @State private var selectedSettingsTab: ReiSettingsTab = .connection

    private let appLog: AppLog
    private let launchState: LaunchState

    init() {
        let appLog = AppLog.standard
        appLog.record(.applicationStarted)
        self.appLog = appLog
        launchState = LaunchState.load(appLog: appLog)
    }

    var body: some Scene {
        Window("Rei", id: launchState.windowID) {
            switch launchState {
            case .ready(let environment, let showcase):
                RootView(
                    environment: environment,
                    selectedSettingsTab: $selectedSettingsTab,
                    showcase: showcase
                )
            case .failed(let failure):
                StartupFailureView(failure: failure)
            }
        }
        .defaultSize(width: 1_320, height: 820)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultLaunchBehavior(.presented)
        .commands {
            ReiCommands()
            LogConsoleCommands()
        }

        Window("Log Console", id: LogConsoleWindow.id) {
            LogConsoleView(log: appLog)
        }
        .defaultSize(width: 980, height: 640)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            switch launchState {
            case .ready(let environment, _):
                SettingsView(
                    environment: environment,
                    selectedTab: $selectedSettingsTab
                )
            case .failed:
                ContentUnavailableView(
                    "Settings Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(
                        "The app environment could not be initialized, so settings cannot be read or saved.")
                )
                .frame(width: 460, height: 240)
            }
        }
    }
}

@MainActor
private enum LaunchState {
    case ready(AppEnvironment, ShowcaseSession?)
    case failed(StartupFailure)

    var windowID: String {
        if case .ready(_, .some(_)) = self { return "showcase" }
        return "main"
    }

    static func load(appLog: AppLog) -> LaunchState {
        do {
            if ShowcaseSession.requested(in: ProcessInfo.processInfo.arguments) {
                let cache = try FileManager.default.url(
                    for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
                ).appendingPathComponent("Rei/Showcase", isDirectory: true)
                let showcase = try ShowcaseSession(appLog: appLog, cacheDirectory: cache)
                appLog.record(.environmentLoaded)
                return .ready(showcase.environment, showcase)
            }
            let environment = try AppEnvironment.standard(appLog: appLog)
            appLog.record(.environmentLoaded)
            return .ready(environment, nil)
        } catch {
            appLog.record(.environmentLoadFailed(AppLogFailure(error)))
            return .failed(StartupFailure(error: error))
        }
    }
}

private struct StartupFailure {
    let summary: String
    let diagnostic: String

    init(error: any Error) {
        summary =
            "Rei could not open its local data or asset directory. Make sure the Application Support directory is writable, then relaunch the app."
        diagnostic = error.localizedDescription
    }
}

private struct StartupFailureView: View {
    let failure: StartupFailure

    var body: some View {
        ContentUnavailableView {
            Label("Rei Couldn’t Start", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            VStack(spacing: 8) {
                Text(failure.summary)
                Text(failure.diagnostic)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
            .frame(maxWidth: 520)
        } actions: {
            Button("Copy Diagnostic Information") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(failure.diagnostic, forType: .string)
            }
            Button("Quit", role: .cancel) {
                NSApp.terminate(nil)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .containerBackground(.thickMaterial, for: .window)
    }
}
