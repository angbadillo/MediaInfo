import SwiftUI
import UniformTypeIdentifiers

/// Entry point: `--print` runs a one-shot analysis on stdout, anything else opens the app.
@main
enum EntryPoint {
    static func main() {
        CommandLineMode.runIfRequested()
        MediaInfoApp.main()
    }
}

struct MediaInfoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("MediaInfo", id: "main") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { delegate.state = state }
        }
        .defaultSize(width: 1180, height: 780)
        .commands { commands }

        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }

    @CommandsBuilder
    private var commands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Abrir…") { state.showOpenPanel() }
                .keyboardShortcut("o")
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Volver a analizar") { state.reanalyze() }
                .keyboardShortcut("r")
                .disabled(state.selectedDocument == nil)
            Button("Mostrar en el Finder") { state.revealInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(state.selectedDocument == nil)
            Divider()
            Button("Quitar del listado") { state.removeSelected() }
                .keyboardShortcut(.delete)
                .disabled(state.selectedDocument == nil)
            Button("Vaciar el listado") { state.removeAll() }
                .disabled(state.documents.isEmpty)
        }
        CommandGroup(replacing: .saveItem) {
            Menu("Exportar informe") {
                ForEach(ReportExporter.Format.allCases) { format in
                    Button(format.rawValue) { state.save(format: format) }
                }
            }
            .disabled(state.selectedDocument?.report == nil)

            Menu("Copiar informe") {
                ForEach(ReportExporter.Format.allCases) { format in
                    Button(format.rawValue) { state.copyToPasteboard(format: format) }
                }
            }
            .disabled(state.selectedDocument?.report == nil)

            Divider()
            Button("Exportar comparativa (CSV)…") { state.saveComparison() }
                .disabled(state.readyReports.count < 1)
            Button("Copiar comparativa") { state.copyComparison() }
                .disabled(state.readyReports.count < 1)
        }
    }
}

/// Handles files opened from the Finder ("Abrir con…", drag onto the Dock icon).
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor weak var state: AppState?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            state?.open(urls: urls)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Analizar la tasa de bits paquete a paquete", isOn: $state.analyzeBitrateCurve)
                Text("Produce la gráfica de bitrate y las estadísticas de GOP. Requiere recorrer el fichero entero, "
                     + "así que en películas largas añade unos segundos al análisis.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Motor") {
                LabeledContent("ffprobe") {
                    Text(FFProbe.executableURL?.path ?? "no encontrado")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("Origen") {
                    Text(FFProbe.isBundled ? "Incluido en la app" : "Instalación del sistema")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
    }
}
