import Foundation
import Combine

// MARK: - Navigation

/// Every destination the app shell can push onto the navigation stack.
/// Value type so it can be used directly as a `NavigationStack` path element.
enum AppScreen: Hashable {
    case viewfinder
    case gallery
    case settings
}

/// Main-actor navigation value-holder shared by every screen via
/// `NavigationStack(path:)`. Deliberately UI-framework-light: it owns the path
/// and the mutation helpers, while the root view owns the presentation.
@MainActor
final class Router: ObservableObject {
    /// Backing path for `NavigationStack(path:)`.
    @Published var path: [AppScreen] = []

    /// Pushes a destination onto the stack.
    func push(_ screen: AppScreen) {
        path.append(screen)
    }

    /// Pops the topmost destination, if any.
    func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    /// Returns to the root screen.
    func popToRoot() {
        path.removeAll()
    }
}
