//
//  CloudNowApp.swift
//  CloudNow
//
//  Created by Owen Selles on 11/04/2026.
//

import SwiftUI

@main
struct CloudNowApp: App {
    @State private var xcloudAuth = XCloudAuthManager()
    @State private var xcloudLibrary = XCloudLibraryStore()
    @State private var launchSelection = XCloudLaunchSelection()

    init() {
        // Catalog payloads do not belong in CFPreferences. Older builds stored
        // xCloud artwork/metadata there and tvOS aborts when the domain grows
        // beyond its hard limit, so clear those legacy cache keys before any
        // view-model preference writes occur.
        for key in [
            "xcloud.entitledLibrary.v1", "xcloud.homePlaylists.v1",
            "xcloud.entitledLibrary.v2", "xcloud.homePlaylists.v2"
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.synchronize()
        URLCache.shared = URLCache(
            memoryCapacity: 256 * 1024 * 1024,
            diskCapacity: 1024 * 1024 * 1024
        )
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if xcloudAuth.isSignedIn {
                    FortniteLauncherView()
                } else {
                    LoginView()
                }
            }
            .environment(xcloudAuth)
            .environment(xcloudLibrary)
            .environment(launchSelection)
            .onOpenURL { url in launchSelection.open(url) }
            .background(Color.black.ignoresSafeArea())
        }
    }
}
