import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var isTargetedByDrop = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 420)
        } detail: {
            Group {
                if let document = state.selectedDocument {
                    DocumentView(document: document)
                } else {
                    EmptyStateView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { toolbar }
        .dropDestination(for: URL.self) { urls, _ in
            let accepted = urls.filter(isMediaFile)
            guard !accepted.isEmpty else { return false }
            state.open(urls: accepted)
            return true
        } isTargeted: { isTargetedByDrop = $0 }
        .overlay {
            if isTargetedByDrop { DropOverlay() }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                state.showOpenPanel()
            } label: {
                Label("Abrir", systemImage: "plus")
            }
            .help("Abrir ficheros para analizar (⌘O)")
        }

        ToolbarItemGroup {
            Button {
                state.reanalyze()
            } label: {
                Label("Volver a analizar", systemImage: "arrow.clockwise")
            }
            .help("Volver a analizar el fichero seleccionado (⌘R)")
            .disabled(state.selectedDocument == nil)

            Button {
                state.revealInFinder()
            } label: {
                Label("Mostrar en el Finder", systemImage: "folder")
            }
            .help("Mostrar en el Finder (⇧⌘R)")
            .disabled(state.selectedDocument == nil)

            Menu {
                Section("Guardar como") {
                    ForEach(ReportExporter.Format.allCases) { format in
                        Button(format.rawValue) { state.save(format: format) }
                    }
                }
                Section("Copiar al portapapeles") {
                    ForEach(ReportExporter.Format.allCases) { format in
                        Button(format.rawValue) { state.copyToPasteboard(format: format) }
                    }
                }
                if state.readyReports.count > 1 {
                    Section("Comparativa (\(state.readyReports.count) ficheros)") {
                        Button("Guardar CSV…") { state.saveComparison() }
                        Button("Copiar CSV") { state.copyComparison() }
                    }
                }
            } label: {
                Label("Exportar", systemImage: "square.and.arrow.up")
            }
            .disabled(state.selectedDocument?.report == nil)
        }
    }

    /// Accepts anything macOS classifies as audiovisual, plus unknown extensions —
    /// ffprobe often reads containers the system has no UTI for (MKV, TS, VOB…).
    private func isMediaFile(_ url: URL) -> Bool {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return true
        }
        if type.conforms(to: .audiovisualContent) || type.conforms(to: .audio) { return true }
        return !type.conforms(to: .folder)
    }
}

private struct DropOverlay: View {
    var body: some View {
        ZStack {
            Color.accentColor.opacity(0.08)
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                .padding(16)
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 40, weight: .light))
                Text("Suelta los ficheros para analizarlos")
                    .font(.title3.weight(.medium))
            }
            .foregroundStyle(Color.accentColor)
        }
        .allowsHitTesting(false)
    }
}

struct EmptyStateView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "film.stack")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text("Sin ficheros que analizar")
                    .font(.title2.weight(.semibold))
                Text("Arrastra vídeos a esta ventana o ábrelos con ⌘O.\nPuedes soltar varios a la vez para compararlos.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Button("Abrir ficheros…") { state.showOpenPanel() }
                .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
