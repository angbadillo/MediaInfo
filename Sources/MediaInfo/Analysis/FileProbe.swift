import CoreServices
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Everything the file system and Spotlight know about the file, independent of its contents.
enum FileProbe {
    static func analyze(url: URL) -> [InfoSection] {
        var sections: [InfoSection] = []
        sections.append(fileSection(url: url))
        if let xattr = xattrSection(url: url) { sections.append(xattr) }
        if let spotlight = spotlightSection(url: url) { sections.append(spotlight) }
        return sections
    }

    // MARK: - File system

    private static func fileSection(url: URL) -> InfoSection {
        var rows: [InfoRow] = []
        rows.append(InfoRow("Nombre", url.lastPathComponent, rawKey: "lastPathComponent", highlighted: true))
        rows.append(InfoRow("Ruta", url.deletingLastPathComponent().path, rawKey: "path"))
        rows.append(InfoRow("Extensión", url.pathExtension.isEmpty ? "—" : ".\(url.pathExtension)",
                            rawKey: "pathExtension"))

        let keys: Set<URLResourceKey> = [
            .fileSizeKey, .totalFileAllocatedSizeKey, .creationDateKey, .contentModificationDateKey,
            .contentAccessDateKey, .addedToDirectoryDateKey, .contentTypeKey, .isAliasFileKey,
            .isSymbolicLinkKey, .isPackageKey, .isHiddenKey, .isReadableKey, .isWritableKey,
            .volumeNameKey, .volumeURLKey, .volumeIsRemovableKey, .volumeSupportsFileCloningKey,
            .fileResourceIdentifierKey, .documentIdentifierKey, .isExcludedFromBackupKey,
            .isUbiquitousItemKey, .mayShareFileContentKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            return InfoSection("Fichero", symbol: "doc", rows: rows)
        }

        if let size = values.fileSize {
            rows.append(InfoRow("Tamaño", Fmt.bytes(size), rawKey: "fileSize", highlighted: true))
        }
        if let allocated = values.totalFileAllocatedSize, allocated != values.fileSize {
            rows.append(InfoRow("Espacio ocupado en disco", Fmt.bytes(allocated),
                                rawKey: "totalFileAllocatedSize",
                                note: "Difiere del tamaño lógico por el tamaño de bloque o por compresión del sistema de ficheros."))
        }
        if let type = values.contentType {
            rows.append(InfoRow("Tipo (UTI)", "\(type.localizedDescription ?? type.identifier)\n\(type.identifier)",
                                rawKey: "contentType"))
            if let mime = type.preferredMIMEType {
                rows.append(InfoRow("Tipo MIME", mime, rawKey: "preferredMIMEType"))
            }
        }
        if let date = values.creationDate {
            rows.append(InfoRow("Creado", Fmt.date(date), rawKey: "creationDate"))
        }
        if let date = values.contentModificationDate {
            rows.append(InfoRow("Modificado", Fmt.date(date), rawKey: "contentModificationDate"))
        }
        if let date = values.addedToDirectoryDate {
            rows.append(InfoRow("Añadido a la carpeta", Fmt.date(date), rawKey: "addedToDirectoryDate"))
        }
        if let date = values.contentAccessDate {
            rows.append(InfoRow("Último acceso", Fmt.date(date), rawKey: "contentAccessDate"))
        }
        if let volume = values.volumeName {
            rows.append(InfoRow("Volumen", volume, rawKey: "volumeName"))
        }
        if values.isAliasFile == true { rows.append(InfoRow("Es un alias", "Sí", rawKey: "isAliasFile")) }
        if values.isSymbolicLink == true { rows.append(InfoRow("Es un enlace simbólico", "Sí", rawKey: "isSymbolicLink")) }
        if values.isUbiquitousItem == true {
            rows.append(InfoRow("En iCloud Drive", "Sí", rawKey: "isUbiquitousItem",
                                note: "El fichero puede estar descargado sólo parcialmente."))
        }
        if let writable = values.isWritable {
            rows.append(InfoRow("Permisos", writable ? "Lectura y escritura" : "Sólo lectura", rawKey: "isWritable"))
        }
        if let identifier = values.documentIdentifier {
            rows.append(InfoRow("Document ID", "\(identifier)", rawKey: "documentIdentifier"))
        }

        return InfoSection("Fichero", subtitle: url.path, symbol: "doc", rows: rows)
    }

    // MARK: - Extended attributes

    /// Where a download came from, quarantine state, Finder tags — all live in xattrs.
    private static func xattrSection(url: URL) -> InfoSection? {
        let path = url.path
        let length = listxattr(path, nil, 0, 0)
        guard length > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: length)
        guard listxattr(path, &buffer, length, 0) > 0 else { return nil }

        let names = buffer.split(separator: 0).compactMap { chunk -> String? in
            chunk.withUnsafeBufferPointer { pointer in
                pointer.baseAddress.flatMap { String(cString: $0) }
            }
        }

        var rows: [InfoRow] = []
        for name in names {
            let size = getxattr(path, name, nil, 0, 0, 0)
            guard size > 0 else { continue }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { raw in
                getxattr(path, name, raw.baseAddress, size, 0, 0)
            }
            guard read > 0 else { continue }
            rows.append(InfoRow(friendlyXattrName(name), describe(xattr: name, data: data),
                                rawKey: name, note: xattrNote(name)))
        }
        return rows.isEmpty ? nil : InfoSection(
            "Atributos extendidos",
            subtitle: "Metadatos que macOS adjunta al fichero",
            symbol: "paperclip",
            rows: rows.sorted { $0.label < $1.label }
        )
    }

    private static func describe(xattr name: String, data: Data) -> String {
        // Most Apple xattrs are binary plists; a few are plain text.
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) {
            if let array = plist as? [Any] {
                return array.map { String(describing: $0) }.joined(separator: "\n")
            }
            if let dictionary = plist as? [String: Any] {
                return dictionary.sorted { $0.key < $1.key }
                    .map { "\($0.key): \($0.value)" }
                    .joined(separator: "\n")
            }
            return String(describing: plist)
        }
        if let text = String(data: data, encoding: .utf8),
           text.allSatisfy({ !$0.isNewline || $0 == "\n" }), !text.isEmpty {
            return text
        }
        return "\(Fmt.bytesShort(data.count)) de datos binarios"
    }

    private static func friendlyXattrName(_ name: String) -> String {
        switch name {
        case "com.apple.quarantine": return "Cuarentena (Gatekeeper)"
        case "com.apple.metadata:kMDItemWhereFroms": return "Origen de la descarga"
        case "com.apple.metadata:_kMDItemUserTags": return "Etiquetas del Finder"
        case "com.apple.FinderInfo": return "Finder info"
        case "com.apple.lastuseddate#PS": return "Última fecha de uso"
        case "com.apple.provenance": return "Procedencia"
        default: return name
        }
    }

    private static func xattrNote(_ name: String) -> String? {
        switch name {
        case "com.apple.quarantine":
            return "Presente en ficheros descargados. Provoca el aviso «descargado de internet» al abrirlos."
        case "com.apple.metadata:kMDItemWhereFroms":
            return "URL o aplicación de la que procede el fichero."
        default:
            return nil
        }
    }

    // MARK: - Spotlight

    /// Spotlight indexes its own media summary; useful as a cross-check against ffprobe.
    private static func spotlightSection(url: URL) -> InfoSection? {
        guard let item = MDItemCreate(nil, url.path as CFString),
              let names = MDItemCopyAttributeNames(item) as? [String]
        else { return nil }

        // kMDItemFS* only restates what the file-system section already shows.
        let interesting = names.filter { $0.hasPrefix("kMDItem") && !$0.hasPrefix("kMDItemFS") }
        var rows: [InfoRow] = []
        for name in interesting.sorted() {
            guard let value = MDItemCopyAttribute(item, name as CFString) else { continue }
            let text = describe(spotlight: value)
            guard !text.isEmpty, text != "—" else { continue }
            rows.append(InfoRow(friendlySpotlightName(name), text, rawKey: name))
        }
        return rows.isEmpty ? nil : InfoSection(
            "Spotlight",
            subtitle: "Índice de metadatos de macOS",
            symbol: "magnifyingglass",
            rows: rows
        )
    }

    private static func describe(spotlight value: CFTypeRef) -> String {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        case let date as Date: return Fmt.date(date)
        case let array as [Any]: return array.map { String(describing: $0) }.joined(separator: ", ")
        case let data as Data: return "\(Fmt.bytesShort(data.count)) de datos binarios"
        default: return String(describing: value)
        }
    }

    private static func friendlySpotlightName(_ name: String) -> String {
        var label = name.replacingOccurrences(of: "kMDItem", with: "")
        // Split the CamelCase identifier into words.
        label = label.replacingOccurrences(
            of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        return label
    }

    // MARK: - Checksums

    /// Hashing is opt-in: it reads the whole file, which is slow on large media.
    static func checksums(url: URL, progress: (@Sendable (Double) -> Void)? = nil) throws -> InfoSection {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let totalBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var md5 = Insecure.MD5()
        var sha256 = SHA256()
        var processed = 0
        let chunkSize = 4 * 1024 * 1024

        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            md5.update(data: chunk)
            sha256.update(data: chunk)
            processed += chunk.count
            if totalBytes > 0 { progress?(Double(processed) / Double(totalBytes)) }
        }

        let md5Hex = md5.finalize().map { String(format: "%02x", $0) }.joined()
        let shaHex = sha256.finalize().map { String(format: "%02x", $0) }.joined()

        return InfoSection("Sumas de verificación", symbol: "number", rows: [
            InfoRow("MD5", md5Hex, rawKey: "md5"),
            InfoRow("SHA-256", shaHex, rawKey: "sha256"),
        ])
    }
}
