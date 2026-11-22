import AppKit

/// Zeilen gleicher Höhe aus Kacheln in 4:3 und 3:4, jede Zeile füllt die Breite. Die Reihenfolge
/// bleibt die des Ordners, nur die letzte Zeile wird nicht gestreckt.
final class CollageLayout: NSCollectionViewLayout {
    var rowHeight: CGFloat = 200 { didSet { if rowHeight != oldValue { invalidateLayout() } } }
    var nameHeight: CGFloat = 0 { didSet { if nameHeight != oldValue { invalidateLayout() } } }
    var spacing: CGFloat = 10
    /// Seitenverhältnis (Breite durch Höhe) der Kachel an dieser Stelle.
    var aspect: (Int) -> CGFloat = { _ in 4 / 3 }

    private var frames: [NSRect] = []
    private var size = NSSize.zero

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let width = collectionView.enclosingScrollView?.contentSize.width ?? collectionView.bounds.width
        let count = collectionView.numberOfSections > 0 ? collectionView.numberOfItems(inSection: 0) : 0
        frames = Array(repeating: .zero, count: count)
        let inner = width - 2 * spacing
        guard inner > 0 else { size = NSSize(width: width, height: 0); return }

        var y = spacing
        var row: [Int] = []
        var sum: CGFloat = 0

        func place(last: Bool) {
            let gaps = CGFloat(row.count - 1) * spacing
            var height = (inner - gaps) / sum
            if last { height = min(height, rowHeight) }
            height = height.rounded()
            var x = spacing
            for (n, index) in row.enumerated() {
                var w = (aspect(index) * height).rounded()
                // Rundungsreste schluckt die letzte Kachel, damit der rechte Rand bündig ist.
                if !last, n == row.count - 1 { w = width - spacing - x }
                frames[index] = NSRect(x: x, y: y, width: w, height: height + nameHeight)
                x += w + spacing
            }
            y += height + nameHeight + spacing
            row = []
            sum = 0
        }

        for index in 0..<count {
            let a = aspect(index)
            row.append(index)
            sum += a
            guard sum * rowHeight + CGFloat(row.count - 1) * spacing >= inner else { continue }
            // Voll: mit oder ohne die letzte Kachel, je nachdem, was näher an der Wunschhöhe liegt.
            let with = (inner - CGFloat(row.count - 1) * spacing) / sum
            if row.count > 1 {
                let without = (inner - CGFloat(row.count - 2) * spacing) / (sum - a)
                if abs(without - rowHeight) < abs(with - rowHeight) {
                    row.removeLast()
                    sum -= a
                    place(last: false)
                    row = [index]
                    sum = a
                    if a * rowHeight >= inner { place(last: false) }
                    continue
                }
            }
            place(last: false)
        }
        if !row.isEmpty { place(last: true) }
        size = NSSize(width: width, height: y)
    }

    override var collectionViewContentSize: NSSize { size }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        // Die Frames sind nach y sortiert: per Binärsuche zur ersten Zeile im Ausschnitt.
        var low = 0, high = frames.count
        while low < high {
            let mid = (low + high) / 2
            if frames[mid].maxY < rect.minY { low = mid + 1 } else { high = mid }
        }
        var result: [NSCollectionViewLayoutAttributes] = []
        var index = low
        while index < frames.count, frames[index].minY <= rect.maxY {
            if frames[index].intersects(rect) { result.append(attributes(index)) }
            index += 1
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        frames.indices.contains(indexPath.item) ? attributes(indexPath.item) : nil
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != size.width
    }

    private func attributes(_ index: Int) -> NSCollectionViewLayoutAttributes {
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: index, section: 0))
        attributes.frame = frames[index]
        return attributes
    }
}
