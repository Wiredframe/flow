import CryptoKit
import Foundation
import UniformTypeIdentifiers

struct MediaItem: Hashable {
    let url: URL
    let date: Date
    let isVideo: Bool
    /// Schlüssel im Vorschau-Cache, ändert sich mit Pfad, Änderungsdatum und Größe.
    let cacheKey: String

    var name: String { url.lastPathComponent }
    /// Dateiname unter der Kachel, Videos mit Play-Zeichen davor.
    var label: String { isVideo ? "▶\u{FE0E} " + name : name }
}

enum FolderScanner {
    private static let keys: Set<URLResourceKey> = [
        .isRegularFileKey, .contentTypeKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey,
    ]

    /// Alle Fotos und Videos direkt im Ordner, neueste zuerst. RAW-Dateien bleiben außen vor.
    static func scan(_ folder: URL) -> [MediaItem] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        var items: [MediaItem] = []
        items.reserveCapacity(urls.count)
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let type = values.contentType else { continue }
            let isVideo = type.conforms(to: .movie)
            guard isVideo || (type.conforms(to: .image) && !type.conforms(to: .rawImage)) else { continue }
            let modified = values.contentModificationDate ?? .distantPast
            let raw = "\(url.path)|\(modified.timeIntervalSince1970)|\(values.fileSize ?? 0)"
            let key = SHA256.hash(data: Data(raw.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
            items.append(MediaItem(url: url, date: values.creationDate ?? modified, isVideo: isVideo, cacheKey: key))
        }
        items.sort {
            $0.date != $1.date ? $0.date > $1.date : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return items
    }
}

/// Meldet, wenn im Ordner Dateien dazukommen, verschwinden oder umbenannt werden.
final class FolderWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(_ folder: URL, onChange: @escaping () -> Void) {
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}
