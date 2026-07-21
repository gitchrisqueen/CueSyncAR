//
//  CueSyncApp.swift
//  CueSync AR
//
//  Created by Christopher Queen on 10/17/23.
//  Modernized to the SwiftUI app lifecycle in milestone M0.
//

import SwiftUI

@main
struct CueSyncApp: App {
    @State private var model = SessionModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.bootstrap() }
        }
    }
}
