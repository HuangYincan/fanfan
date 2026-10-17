import Foundation
import Combine

// This edition uses a root-installed, hash-pinned LaunchDaemon. It never
// unregisters or repairs the official SMAppService daemon.
class PermissionsManager: ObservableObject {
    static let shared = PermissionsManager()
    @Published var isHelperInstalled = false
    @Published private(set) var isInstalling = false
    @Published private(set) var needsApproval = false
    private var isChecking = false

    private init() { checkInstallation() }

    func checkInstallation() {
        guard !isChecking else { return }
        isChecking = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ready = SMCDaemonClient.ping()
            DispatchQueue.main.async {
                self?.isHelperInstalled = ready
                self?.isChecking = false
            }
        }
    }

    func installHelper(completion: @escaping (Bool, String?) -> Void) {
        checkInstallation()
        completion(false, "请重新运行本机版安装脚本，以管理员身份安装专用辅助程序。")
    }

    nonisolated static func waitUntil(timeout: TimeInterval, pollInterval: TimeInterval,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        check: () -> Bool) -> Bool {
        guard timeout > 0, pollInterval > 0 else { return check() }
        let deadline = now() + timeout
        while true {
            if check() { return true }
            let remaining = deadline - now()
            if remaining <= 0 { return false }
            sleep(min(pollInterval, remaining))
        }
    }

    nonisolated static func shouldApplyStatusResult(generation: Int,
        currentGeneration: Int, isInstalling: Bool) -> Bool {
        generation == currentGeneration && !isInstalling
    }
}
