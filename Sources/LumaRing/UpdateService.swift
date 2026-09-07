import AppKit
import Combine
import Sparkle

struct UpdateConfiguration {
    let feedURL: URL
    let publicKey: Data

    init?(info: [String: Any]) {
        guard let text = info["SUFeedURL"] as? String, let url = URL(string: text),
              url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.path.hasSuffix("/releases/latest/download/appcast.xml"),
              let key = info["SUPublicEDKey"] as? String,
              let data = Data(base64Encoded: key), data.count == 32 else { return nil }
        feedURL = url; publicKey = data
    }
}

@MainActor final class UpdateService: NSObject, ObservableObject, NSMenuItemValidation {
    static let shared = UpdateService()
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L10n.text("开发版", "Development") }
    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = true
    @Published private(set) var lastChecked: Date?
    @Published private(set) var configurationMissing = false
    var configurationMessage: String? {
        configurationMissing ? L10n.text("此构建尚未配置更新源。", "Updates are not configured for this build.") : nil
    }
    private var controller: SPUStandardUpdaterController?
    private var subscriptions = Set<AnyCancellable>()

    func start() {
        guard controller == nil else { return }
        guard UpdateConfiguration(info: Bundle.main.infoDictionary ?? [:]) != nil else {
            configurationMissing = true
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheck = $0 }.store(in: &subscriptions)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.automaticChecks = $0 }.store(in: &subscriptions)
        controller.updater.publisher(for: \.lastUpdateCheckDate).receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.lastChecked = $0 }.store(in: &subscriptions)
        // Sparkle owns scheduling, skip/remind persistence, verification, installation and relaunch.
        // Defaults are configured in Info.plist; never override users' choices on launch.
        controller.startUpdater()
    }

    func setAutomaticChecks(_ enabled: Bool) { controller?.updater.automaticallyChecksForUpdates = enabled }
    @objc func checkForUpdates(_ sender: Any? = nil) {
        guard canCheck else { return }
        controller?.checkForUpdates(sender)
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { canCheck }
}
