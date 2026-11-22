import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Vorschaubilder im Format 4:3 oder 3:4 je nach Ausrichtung: erst aus dem Speicher, dann von der
/// Platte, sonst neu erzeugt. Das quadratische Raster schneidet sie beim Anzeigen mittig zu.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    /// Kurze Seite in Pixeln, reicht für die größte Kachel auf Retina.
    static let side = 640
    /// Kommt, sobald von weiteren Dateien bekannt ist, ob sie hoch- oder querformatig sind.
    static let orientationsChanged = Notification.Name("ThumbnailCacheOrientationsChanged")

    private let memory = NSCache<NSString, CGImage>()
    private let folder: URL
    private let visibleQueue = OperationQueue()
    private let prewarmQueue = OperationQueue()

    /// Hochformat ja oder nein je Cache-Schlüssel, damit die Collage gleich richtig steht. Der
    /// Schlüssel ist ein gekürzter SHA-256 aus Pfad, Datum und Größe: keine Namen, keine Bilddaten.
    private var portrait: [String: Bool] = [:]
    private let portraitLock = NSLock()
    private let portraitFile: URL
    private var portraitPending = false

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("de.wiredframe.Flow", isDirectory: true)
        folder = base.appendingPathComponent("Previews", isDirectory: true)
        portraitFile = base.appendingPathComponent("Orientations.plist")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: portraitFile),
           let stored = try? PropertyListDecoder().decode([String: Bool].self, from: data) {
            portrait = stored
        }
        // Die quadratischen Vorschaubilder bis Version 1.0.3 taugen nicht für die Collage.
        let old = base.appendingPathComponent("Thumbnails", isDirectory: true)
        DispatchQueue.global(qos: .background).async { try? FileManager.default.removeItem(at: old) }
        memory.totalCostLimit = 512 << 20
        let cores = ProcessInfo.processInfo.activeProcessorCount
        visibleQueue.maxConcurrentOperationCount = cores
        visibleQueue.qualityOfService = .userInitiated
        prewarmQueue.maxConcurrentOperationCount = max(1, cores / 2)
        prewarmQueue.qualityOfService = .utility
    }

    func cached(_ item: MediaItem) -> CGImage? {
        memory.object(forKey: item.cacheKey as NSString)
    }

    /// Hochformat, Querformat oder nil, solange es noch kein Vorschaubild gab.
    func isPortrait(_ item: MediaItem) -> Bool? {
        portraitLock.withLock { portrait[item.cacheKey] }
    }

    private func learn(_ item: MediaItem, from image: CGImage) {
        let value = image.height > image.width
        let changed = portraitLock.withLock {
            guard portrait[item.cacheKey] != value else { return false }
            portrait[item.cacheKey] = value
            return true
        }
        guard changed else { return }
        DispatchQueue.main.async { [self] in
            guard !portraitPending else { return }
            portraitPending = true
            // Gesammelt melden und speichern, nicht für jede Datei einzeln.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                portraitPending = false
                NotificationCenter.default.post(name: Self.orientationsChanged, object: self)
                savePortraits()
            }
        }
    }

    private func savePortraits() {
        let snapshot = portraitLock.withLock { portrait }
        let file = portraitFile
        DispatchQueue.global(qos: .utility).async {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try? encoder.encode(snapshot).write(to: file, options: .atomic)
        }
    }

    /// Löscht alle Vorschaubilder und Ausrichtungen, auf der Platte und im Speicher.
    func clear() {
        visibleQueue.cancelAllOperations()
        prewarmQueue.cancelAllOperations()
        memory.removeAllObjects()
        portraitLock.withLock { portrait = [:] }
        let fm = FileManager.default
        for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: file)
        }
        try? fm.removeItem(at: portraitFile)
    }

    /// Lädt ein Vorschaubild für eine sichtbare Kachel. Abbrechen über die zurückgegebene Operation.
    /// Fehlt es im Cache, kommt zuerst das in der Datei eingebettete Vorschau-JPEG (nur wenige KB
    /// zu lesen, auch übers Netz schnell), danach die scharfe Fassung: `completion` läuft dann zweimal.
    func load(_ item: MediaItem, completion: @escaping (CGImage?) -> Void) -> Operation {
        let file = fileURL(item)
        let op = BlockOperation()
        op.addExecutionBlock { [weak self, weak op, memory] in
            guard op?.isCancelled == false else { return }
            var image = Self.read(file)
            if image == nil, !item.isVideo, let quick = Self.embedded(item.url) {
                DispatchQueue.main.async {
                    if op?.isCancelled != true { completion(quick) }
                }
                // Weggescrollt: die scharfe Fassung erzeugt später der Hintergrundlauf.
                guard op?.isCancelled == false else { return }
            }
            if image == nil, let made = Self.make(item) {
                Self.write(made, to: file)
                image = made
            }
            if let image { self?.learn(item, from: image) }
            DispatchQueue.main.async {
                if let image {
                    memory.setObject(image, forKey: item.cacheKey as NSString, cost: image.bytesPerRow * image.height)
                }
                if op?.isCancelled != true { completion(image) }
            }
        }
        visibleQueue.addOperation(op)
        return op
    }

    /// Erzeugt im Hintergrund alle fehlenden Vorschaubilder eines Ordners, neueste zuerst.
    func prewarm(_ items: [MediaItem]) {
        prewarmQueue.cancelAllOperations()
        for item in items {
            let file = fileURL(item)
            let known = isPortrait(item) != nil
            prewarmQueue.addOperation { [weak self] in
                if FileManager.default.fileExists(atPath: file.path) {
                    if !known, let image = Self.read(file) { self?.learn(item, from: image) }
                    return
                }
                guard let image = Self.make(item) else { return }
                Self.write(image, to: file)
                self?.learn(item, from: image)
            }
        }
    }

    /// Hält den Cache auf der Platte unter `maxBytes`, die ältesten Bilder gehen zuerst.
    /// Ausrichtungen ohne Vorschaubild fallen dabei mit heraus.
    func prune(maxBytes: Int = 2 << 30) {
        let folder = folder
        DispatchQueue.global(qos: .background).async { [self] in
            defer { dropOrphanedPortraits() }
            let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: Array(keys)) else { return }
            var entries = files.map { url -> (url: URL, size: Int, date: Date) in
                let values = try? url.resourceValues(forKeys: keys)
                return (url, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast)
            }
            var total = entries.reduce(0) { $0 + $1.size }
            guard total > maxBytes else { return }
            entries.sort { $0.date < $1.date }
            for entry in entries where total > maxBytes / 4 * 3 {
                try? FileManager.default.removeItem(at: entry.url)
                total -= entry.size
            }
        }
    }

    private func dropOrphanedPortraits() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let present = Set(names.map { ($0 as NSString).deletingPathExtension })
        let dropped = portraitLock.withLock {
            let before = portrait.count
            portrait = portrait.filter { present.contains($0.key) }
            return portrait.count != before
        }
        if dropped { DispatchQueue.main.async { self.savePortraits() } }
    }

    private func fileURL(_ item: MediaItem) -> URL {
        folder.appendingPathComponent(item.cacheKey + ".jpg")
    }

    // MARK: Erzeugen, Lesen, Schreiben

    private static func make(_ item: MediaItem) -> CGImage? {
        (item.isVideo ? videoFrame(item.url) : photo(item.url)).flatMap(crop)
    }

    private static func photo(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        // Die kurze Seite soll nach dem Zuschnitt auf 4:3 noch `side` Pixel haben.
        var maxPixel = side * 4 / 3
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int, min(w, h) > 0 {
            let long = Double(max(w, h)), short = Double(min(w, h))
            let croppedShort = min(short, long * 3 / 4)
            maxPixel = Int((Double(side) * long / croppedShort).rounded(.up))
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Das eingebettete Vorschaubild der Kamera, oder nil, wenn die Datei keins hat.
    private static func embedded(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).flatMap(crop)
    }

    private static func videoFrame(_ url: URL) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        let done = DispatchSemaphore(value: 0)
        var result: CGImage?
        generator.generateCGImageAsynchronously(for: CMTime(seconds: 0.5, preferredTimescale: 600)) { image, _, _ in
            result = image
            done.signal()
        }
        done.wait()
        return result
    }

    /// Mittiger Ausschnitt in 4:3 (quer und quadratisch) oder 3:4 (hoch), die kurze Seite
    /// auf höchstens `side` Pixel verkleinert.
    private static func crop(_ image: CGImage) -> CGImage? {
        let landscape = image.width >= image.height
        let (aw, ah) = landscape ? (4, 3) : (3, 4)
        var w = image.width, h = image.height
        if w * ah > h * aw { w = h * aw / ah } else { h = w * ah / aw }
        guard w > 0, h > 0,
              let cropped = image.cropping(to: CGRect(x: (image.width - w) / 2, y: (image.height - h) / 2,
                                                      width: w, height: h)) else { return nil }
        let short = min(min(w, h), side)
        let tw = landscape ? short * 4 / 3 : short, th = landscape ? short : short * 4 / 3
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return cropped }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: tw, height: th))
        return context.makeImage()
    }

    private static func read(_ file: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    private static func write(_ image: CGImage, to file: URL) {
        guard let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}
