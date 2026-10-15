import AppKit
import Combine
import Sparkle

/// Self-updates through Sparkle. The feed (`SUFeedURL`) and the EdDSA public key (`SUPublicEDKey`)
/// live in Info.plist; releases are published by scripts/release.sh.
@MainActor
final class Updater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController
    private var cancellables = Set<AnyCancellable>()

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &cancellables)
    }

    /// The app is `LSUIElement`, so activate it or Sparkle's window would open behind other apps.
    func checkForUpdates() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}
