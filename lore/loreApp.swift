//
//  loreApp.swift
//  lore
//
//  Created by Aark Koduru on 7/18/25.
//

import SwiftUI
import SwiftData

@main
struct loreApp: App {
    private let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try LoreModelContainer.make()
        } catch {
            fatalError("Failed to create model container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .modelContainer(modelContainer)
        }
    }
}
