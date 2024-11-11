//
//  MicroQR_2App.swift
//  MicroQR-2
//
//  Created by Bastiaan Quast on 11/10/24.
//

import SwiftUI

@main
struct MicroQR_2App: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
