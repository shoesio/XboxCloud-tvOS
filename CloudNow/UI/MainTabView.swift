import SwiftUI

/// Compatibility entry point retained for the existing Xcode target.
/// The Fortnite build uses FortniteLauncherView directly from CloudNowApp.
struct MainTabView: View {
    var body: some View {
        FortniteLauncherView()
    }
}
