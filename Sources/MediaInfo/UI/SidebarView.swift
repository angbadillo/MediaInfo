import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        List(selection: $state.selection) {
            Section(state.documents.isEmpty ? "Ficheros" : "Ficheros (\(state.documents.count))") {
                ForEach(state.documents) { document in
                    DocumentRow(document: document)
                        .tag(document.id)
                        .contextMenu {
                            Button("Volver a analizar") { state.analyze(document) }
                            Button("Mostrar en el Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([document.url])
                            }
                            Divider()
                            Button("Quitar del listado", role: .destructive) { state.remove(document) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if state.documents.isEmpty {
                Text("Arrastra vídeos aquí")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if state.documents.count > 1 {
                Divider()
                Button {
                    state.copyComparison()
                } label: {
                    Label("Copiar comparativa", systemImage: "tablecells")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .padding(8)
                .help("Copia una tabla CSV con los datos clave de todos los ficheros analizados")
            }
        }
    }
}

private struct DocumentRow: View {
    @ObservedObject var document: Document

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(document.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(document.subtitle)
                    .font(.caption)
                    .foregroundStyle(isFailed ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if document.isBusy {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 3)
    }

    private var isFailed: Bool {
        if case .failed = document.state { return true }
        return false
    }

    @ViewBuilder
    private var thumbnail: some View {
        Group {
            if let image = document.report?.thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: isFailed ? "exclamationmark.triangle" : "film")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
            }
        }
        .frame(width: 44, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
