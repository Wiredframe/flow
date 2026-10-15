import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Quadratische Vorschaubilder: erst aus dem Speicher, dann von der Platte, sonst neu erzeugt.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    /// Kantenlänge in Pixeln, reicht für die größte Kachel auf Retina.
    static let side = 640

    private let memory = NSCache<NSString, CGImage>()
    private let folder: URL
    private let visibleQueue = OperationQueue()
    private let prewarmQueue = OperationQueue()

    private init() {
        folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("de.wiredframe.Flow/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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

    /// Lädt ein Vorschaubild für eine sichtbare Kachel. Abbrechen über die zurückgegebene Operation.
    /// Fehlt es im Cache, kommt zuerst das in der Datei eingebettete Vorschau-JPEG (nur wenige KB
    /// zu lesen, auch übers Netz schnell), danach die scharfe Fassung: `completion` läuft dann zweimal.
    func load(_ item: MediaItem, completion: @escaping (CGImage?) -> Void) -> Operation {
        let file = fileURL(item)
        let op = BlockOperation()
        op.addExecutionBlock { [weak op, memory] in
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
            prewarmQueue.addOperation {
                guard !FileManager.default.fileExists(atPath: file.path), let image = Self.make(item) else { return }
                Self.write(image, to: file)
            }
        }
    }

    /// Hält den Cache auf der Platte unter `maxBytes`, die ältesten Bilder gehen zuerst.
    func prune(maxBytes: Int = 2 << 30) {
        let folder = folder
        DispatchQueue.global(qos: .background).async {
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

    private func fileURL(_ item: MediaItem) -> URL {
        folder.appendingPathComponent(item.cacheKey + ".jpg")
    }

    // MARK: Erzeugen, Lesen, Schreiben

    private static func make(_ item: MediaItem) -> CGImage? {
        (item.isVideo ? videoFrame(item.url) : photo(item.url)).flatMap(square)
    }

    private static func photo(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        // Die kurze Seite soll nach dem Zuschnitt noch `side` Pixel haben.
        var maxPixel = side
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int, min(w, h) > 0 {
            maxPixel = Int((Double(side) * Double(max(w, h)) / Double(min(w, h))).rounded(.up))
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
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).flatMap(square)
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

    /// Mittiger quadratischer Ausschnitt, auf höchstens `side` Pixel verkleinert.
    private static func square(_ image: CGImage) -> CGImage? {
        let s = min(image.width, image.height)
        let crop = CGRect(x: (image.width - s) / 2, y: (image.height - s) / 2, width: s, height: s)
        guard let cropped = image.cropping(to: crop) else { return nil }
        let target = min(s, side)
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: nil, width: target, height: target, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return cropped }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: target, height: target))
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
