import AppKit
import SwiftUI

struct ZeColetaApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            MainView(model: model)
                .frame(minWidth: 880, minHeight: 620)
                .tint(Palette.green)
                .preferredColorScheme(.light)
        }
        .defaultSize(width: 1120, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("Sobre o Zé Coleta") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Zé Coleta",
                        .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Desenvolvimento",
                        .credits: NSAttributedString(string: "Código aberto sob licença MIT.\nProcessamento local, sem telemetria."),
                    ])
                }
            }
            CommandMenu("Análise") {
                Button("Analisar") { model.startScan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isBusy)
                Button("Cancelar análise") { model.cancelScan() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.isScanning)
            }
        }
    }
}
