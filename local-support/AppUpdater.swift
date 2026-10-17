import Foundation
import Combine

// A local build cannot participate in the upstream Developer ID/Sparkle chain.
// Keep the UI binding, with both update controls disabled by the local builder.
final class AppUpdater: NSObject, ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published var automaticallyChecksForUpdates = false
    func checkForUpdates() {}
}
