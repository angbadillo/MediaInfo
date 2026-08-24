import SwiftUI

/// A collapsible group of rows, nesting for streams and their sub-groups.
struct SectionCard: View {
    let section: InfoSection
    let startsExpanded: Bool
    var depth: Int = 0

    @State private var isExpanded: Bool

    init(section: InfoSection, startsExpanded: Bool, depth: Int = 0) {
        self.section = section
        self.startsExpanded = startsExpanded
        self.depth = depth
        _isExpanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                        RowView(row: row, isAlternate: index.isMultiple(of: 2))
                    }
                    if !section.subsections.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(section.subsections) { subsection in
                                SectionCard(section: subsection,
                                            startsExpanded: depth == 0 && section.rows.isEmpty,
                                            depth: depth + 1)
                            }
                        }
                        .padding(12)
                    }
                }
            }
        }
        .background(depth == 0 ? AnyShapeStyle(.background.secondary) : AnyShapeStyle(.background))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary)
        }
    }

    private var header: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Image(systemName: section.symbol)
                    .foregroundStyle(.tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(section.title)
                        .font(depth == 0 ? .headline : .subheadline.weight(.semibold))
                    if let subtitle = section.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Text("\(fieldCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var fieldCount: Int {
        func count(_ section: InfoSection) -> Int {
            section.rows.count + section.subsections.reduce(0) { $0 + count($1) }
        }
        return count(section)
    }
}

/// One label/value pair. Values are selectable and copyable; the label carries the
/// original ffprobe key and its explanation as a tooltip.
private struct RowView: View {
    let row: InfoRow
    let isAlternate: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(spacing: 4) {
                Text(row.label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if row.note != nil {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 250, alignment: .leading)

            Text(row.value)
                .font(row.isHighlighted ? .callout.weight(.semibold) : .callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovering ? 1 : 0)
            .help("Copiar el valor")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isAlternate ? Color.clear : Color.primary.opacity(0.03))
        .onHover { isHovering = $0 }
        .help(tooltip)
        .contextMenu {
            Button("Copiar valor") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.value, forType: .string)
            }
            Button("Copiar «campo: valor»") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(row.label): \(row.value)", forType: .string)
            }
            if let key = row.rawKey {
                Button("Copiar clave original (\(key))") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key, forType: .string)
                }
            }
        }
    }

    private var tooltip: String {
        var parts: [String] = []
        if let note = row.note { parts.append(note) }
        if let key = row.rawKey { parts.append("Clave original: \(key)") }
        return parts.joined(separator: "\n\n")
    }
}
