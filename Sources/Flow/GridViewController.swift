import AppKit
import AVFoundation
import Quartz

final class GridViewController: NSViewController {
    static let tileSizes: [Double] = [120, 160, 200, 260, 320]
    private let spacing: CGFloat = 10

    private let scrollView = PullScrollView()
    private let pullSpinner = NSProgressIndicator()
    private let collectionView = GridCollectionView()
    private let layout = NSCollectionViewFlowLayout()
    private let collageLayout = CollageLayout()
    private let emptyLabel = NSTextField(labelWithString: "Ordner hierher ziehen oder mit ⌘O öffnen")

    /// Laufende Videos: das ausgewählte, bei „Alle Videos abspielen“ auch alle sichtbaren.
    private var players: [URL: LoopPlayer] = [:]
    private var playbackPending = false
    private var quickLookOpen = false

    private(set) var folder: URL?
    private var items: [MediaItem] = []
    private var watcher: FolderWatcher?
    private var rescanPending = false
    private var mountObserver: NSObjectProtocol?

    private let defaults = UserDefaults.standard
    private var showNames: Bool {
        get { defaults.object(forKey: "showNames") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showNames") }
    }
    private var tileSize: Double {
        get { let value = defaults.double(forKey: "tileSize"); return value > 0 ? value : 200 }
        set { defaults.set(newValue, forKey: "tileSize") }
    }
    private var muted: Bool {
        get { defaults.object(forKey: "muted") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "muted") }
    }
    private var collage: Bool {
        get { defaults.bool(forKey: "collage") }
        set { defaults.set(newValue, forKey: "collage") }
    }
    private var autoplay: Bool {
        get { defaults.bool(forKey: "autoplay") }
        set { defaults.set(newValue, forKey: "autoplay") }
    }

    override func loadView() {
        let root = DropView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        root.onDrop = { [weak self] url in self?.open(url) }

        layout.minimumInteritemSpacing = spacing
        layout.minimumLineSpacing = spacing
        layout.sectionInset = NSEdgeInsets(top: spacing, left: spacing, bottom: spacing, right: spacing)
        collageLayout.spacing = spacing
        collageLayout.aspect = { [weak self] index in
            guard let self, self.items.indices.contains(index),
                  ThumbnailCache.shared.isPortrait(self.items[index]) == true else { return 4 / 3 }
            return 3 / 4
        }
        collectionView.collectionViewLayout = collage ? collageLayout : layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsEmptySelection = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(TileItem.self, forItemWithIdentifier: TileItem.id)
        collectionView.onSpace = { [weak self] in self?.toggleQuickLook() }
        collectionView.onDoubleClick = { [weak self] in self?.toggleQuickLook() }

        scrollView.frame = root.bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.postsFrameChangedNotifications = true
        scrollView.verticalScrollElasticity = .allowed
        scrollView.onPull = { [weak self] in self?.pullToRefresh() }
        scrollView.onOverscroll = { [weak self] in self?.updatePullSpinner() }
        scrollView.contentView.postsBoundsChangedNotifications = true
        root.addSubview(scrollView)

        pullSpinner.style = .spinning
        pullSpinner.isHidden = true
        pullSpinner.sizeToFit()
        root.addSubview(pullSpinner)
        NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main
        ) { [weak self] _ in self?.updateItemSize() }
        // Beim Scrollen kommen Videos ins Bild, die mitlaufen sollen.
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in if self?.autoplay == true { self?.schedulePlayback() } }
        NotificationCenter.default.addObserver(
            forName: ThumbnailCache.orientationsChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.orientationsChanged() }

        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])

        view = root

        // Im Dock oder ausgeblendet läuft kein Video weiter, schon gar nicht mit Ton.
        let center = NotificationCenter.default
        for name in [NSApplication.didHideNotification, NSWindow.didMiniaturizeNotification,
                     NSApplication.didUnhideNotification, NSWindow.didDeminiaturizeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.updateRunning() }
        }
    }

    private var mayPlay: Bool {
        !NSApp.isHidden && view.window?.isMiniaturized != true && !quickLookOpen
    }

    private func updateRunning() {
        let play = mayPlay
        for loop in players.values { if play { loop.player.play() } else { loop.player.pause() } }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateItemSize()
    }

    /// So viele Spalten, wie in Wunschgröße passen, die Kacheln füllen dann die Breite.
    /// In der Collage ist die Wunschgröße die Zeilenhöhe.
    private func updateItemSize() {
        collageLayout.rowHeight = CGFloat(tileSize)
        collageLayout.nameHeight = showNames ? TileView.nameHeight : 0
        let width = scrollView.contentSize.width - layout.sectionInset.left - layout.sectionInset.right
        guard width > 0 else { return }
        let columns = max(1, Int((width + spacing) / (CGFloat(tileSize) + spacing)))
        let side = floor((width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        let size = NSSize(width: side, height: side + (showNames ? TileView.nameHeight : 0))
        if layout.itemSize != size { layout.itemSize = size }
    }

    // MARK: Ordner

    func open(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            waitForVolume(of: url)
            return
        }
        mountObserver.map(NSWorkspace.shared.notificationCenter.removeObserver)
        mountObserver = nil
        let folder = isDir.boolValue ? url : url.deletingLastPathComponent()
        self.folder = folder
        defaults.set(folder.path, forKey: "lastFolder")
        watcher = FolderWatcher(folder) { [weak self] in self?.scheduleRescan() }
        stopAllVideos()
        items = []
        collectionView.reloadData()
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        reload(selecting: isDir.boolValue ? nil : url)
    }

    /// Liegt der Ordner auf einem Laufwerk, das gerade fehlt (etwa das Netzlaufwerk nach dem
    /// Aufwachen), öffnet Flow ihn, sobald irgendein Laufwerk eingehängt wird und er wieder da ist.
    private func waitForVolume(of url: URL) {
        emptyLabel.stringValue = "Warte auf \((url.path as NSString).abbreviatingWithTildeInPath) …"
        emptyLabel.isHidden = false
        guard mountObserver == nil else { return }
        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            self?.open(url)
        }
    }

    private func scheduleRescan() {
        guard !rescanPending else { return }
        rescanPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.rescanPending = false
            self?.reload(selecting: nil)
        }
    }

    // MARK: Ziehen zum Aktualisieren

    private var refreshing = false

    /// Ganz oben über den Rand hinaus ziehen und loslassen liest den Ordner neu ein, falls der
    /// Watcher etwas verpasst hat (Netzlaufwerke melden nicht jede Änderung).
    private func pullToRefresh() {
        guard folder != nil, !refreshing else { return }
        refreshing = true
        pullSpinner.startAnimation(nil)
        updatePullSpinner()
        let started = Date()
        reload(selecting: nil) { [weak self] in
            // Kurz stehen lassen, sonst sieht man bei schnellen Ordnern gar nichts.
            let rest = max(0, 0.5 - Date().timeIntervalSince(started))
            DispatchQueue.main.asyncAfter(deadline: .now() + rest) {
                guard let self else { return }
                self.refreshing = false
                self.pullSpinner.stopAnimation(nil)
                self.updatePullSpinner()
            }
        }
    }

    /// Der Spinner sitzt im Spalt, den das Ziehen über dem Raster öffnet, und wird dabei deutlicher.
    private func updatePullSpinner() {
        let overscroll = scrollView.overscroll
        let visible = refreshing || (folder != nil && overscroll > 4)
        pullSpinner.isHidden = !visible
        guard visible else { return }
        pullSpinner.alphaValue = refreshing ? 1 : min(1, overscroll / PullScrollView.threshold)
        let size = pullSpinner.frame.size
        let gap = refreshing ? max(overscroll, 48) : overscroll
        let top = view.bounds.maxY - scrollView.contentInsets.top
        pullSpinner.setFrameOrigin(NSPoint(x: round(view.bounds.midX - size.width / 2),
                                           y: round(top - gap / 2 - size.height / 2)))
    }

    private func reload(selecting target: URL?, completion: (() -> Void)? = nil) {
        guard let folder else { completion?(); return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scanned = FolderScanner.scan(folder)
            DispatchQueue.main.async { [weak self] in
                defer { completion?() }
                guard let self, self.folder == folder else { return }
                // Netzlaufwerke melden auch Änderungen, wo keine sind: dann nichts anfassen.
                if target == nil, scanned == self.items { return }
                let keep = target ?? self.selectedItem?.url
                let anchor = self.scrollAnchor()
                self.items = scanned
                self.collectionView.reloadData()
                if target == nil, let anchor { self.restore(anchor) }
                ThumbnailCache.shared.prewarm(scanned)
                if let keep, let index = scanned.firstIndex(where: { $0.url == keep }) {
                    self.select(index, scroll: target != nil)
                } else {
                    self.updatePlayback()
                }
                self.emptyLabel.stringValue = "Keine Fotos oder Videos in diesem Ordner"
                self.emptyLabel.isHidden = !scanned.isEmpty
                self.updateTitle()
                self.view.window?.makeFirstResponder(self.collectionView)
            }
        }
    }

    /// Oberste sichtbare Kachel und ihr Abstand zum oberen Rand. Ganz oben gibt es keinen Anker,
    /// dann dürfen neue Fotos dort einfach erscheinen.
    private func scrollAnchor() -> (url: URL, offset: CGFloat)? {
        let visible = scrollView.contentView.bounds
        guard visible.minY > -scrollView.contentInsets.top + 1,
              let path = collectionView.indexPathsForVisibleItems().min(),
              items.indices.contains(path.item),
              let frame = collectionView.layoutAttributesForItem(at: path)?.frame else { return nil }
        return (items[path.item].url, frame.minY - visible.minY)
    }

    private func restore(_ anchor: (url: URL, offset: CGFloat)) {
        guard let index = items.firstIndex(where: { $0.url == anchor.url }) else { return }
        collectionView.layoutSubtreeIfNeeded()
        guard let frame = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame
        else { return }
        let y = max(-scrollView.contentInsets.top, frame.minY - anchor.offset)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func updateTitle() {
        guard let window = view.window, let folder else { return }
        window.title = folder.lastPathComponent
        window.representedURL = folder
        let videos = items.filter(\.isVideo).count
        let photos = items.count - videos
        window.subtitle = "\(photos) \(photos == 1 ? "Foto" : "Fotos") · \(videos) \(videos == 1 ? "Video" : "Videos")"
    }

    // MARK: Auswahl und Video

    private var selectedIndex: Int? {
        collectionView.selectionIndexPaths.first.map(\.item).flatMap { items.indices.contains($0) ? $0 : nil }
    }
    private var selectedItem: MediaItem? { selectedIndex.map { items[$0] } }

    private func select(_ index: Int, scroll: Bool) {
        let path = IndexPath(item: index, section: 0)
        collectionView.selectionIndexPaths = [path]
        if scroll {
            collectionView.layoutSubtreeIfNeeded()
            collectionView.scrollToItems(at: [path], scrollPosition: .centeredVertically)
        }
        updatePlayback()
    }

    /// Ein ausgewähltes Video läuft in Schleife in seiner Kachel, mit Ton. Bei „Alle Videos
    /// abspielen“ laufen stattdessen alle Videos im sichtbaren Bereich, ebenfalls mit Ton.
    private func updatePlayback() {
        let selected = selectedItem.flatMap { $0.isVideo ? $0.url : nil }
        var wanted = Set<URL>()
        if autoplay {
            // Ohne den Streifen unter der Titelleiste, dort ist nichts zu sehen.
            var visible = scrollView.documentVisibleRect
            let hidden = scrollView.contentInsets.top
            visible.origin.y += hidden
            visible.size.height -= hidden
            for path in collectionView.indexPathsForVisibleItems()
            where items.indices.contains(path.item) && items[path.item].isVideo {
                if let frame = collectionView.layoutAttributesForItem(at: path)?.frame, frame.intersects(visible) {
                    wanted.insert(items[path.item].url)
                }
            }
        } else if let selected {
            wanted.insert(selected)
        }
        for url in players.keys where !wanted.contains(url) {
            players.removeValue(forKey: url)?.stop()
        }
        let play = mayPlay
        for url in wanted where players[url] == nil {
            let loop = LoopPlayer(url)
            players[url] = loop
            if play { loop.player.play() }
        }
        for loop in players.values { loop.player.isMuted = muted }
        for case let tile as TileItem in collectionView.visibleItems() {
            if let url = tile.media?.url, let loop = players[url] { tile.playVideo(loop.player) } else { tile.stopVideo() }
        }
    }

    /// Fasst die vielen Anlässe beim Scrollen zu einem Durchlauf zusammen.
    private func schedulePlayback() {
        guard !playbackPending else { return }
        playbackPending = true
        DispatchQueue.main.async { [weak self] in
            self?.playbackPending = false
            self?.updatePlayback()
        }
    }

    private func stopAllVideos() {
        for case let tile as TileItem in collectionView.visibleItems() { tile.stopVideo() }
        for loop in players.values { loop.stop() }
        players = [:]
    }

    /// In der Collage verschieben neu bekannte Ausrichtungen die Kacheln, der Blick bleibt stehen.
    private func orientationsChanged() {
        guard collage else { return }
        let anchor = scrollAnchor()
        collageLayout.invalidateLayout()
        if let anchor { restore(anchor) }
        if autoplay { schedulePlayback() }
    }

    // MARK: Befehle

    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = folder
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.open(url) }
        }
    }

    @objc func showInFinder(_ sender: Any?) {
        guard let url = selectedItem?.url ?? folder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func clearCaches(_ sender: Any?) {
        ThumbnailCache.shared.clear()
        let keep = selectedIndex
        for case let tile as TileItem in collectionView.visibleItems() { tile.setImage(nil) }
        collectionView.reloadData()
        if let keep { collectionView.selectionIndexPaths = [IndexPath(item: keep, section: 0)] }
        ThumbnailCache.shared.prewarm(items)
        updatePlayback()
    }

    @objc func toggleNames(_ sender: Any?) {
        showNames.toggle()
        for case let tile as TileItem in collectionView.visibleItems() { tile.showName(showNames) }
        updateItemSize()
    }

    @objc func toggleSound(_ sender: Any?) {
        muted.toggle()
        updatePlayback()
    }

    @objc func toggleCollage(_ sender: Any?) {
        collage.toggle()
        collectionView.collectionViewLayout = collage ? collageLayout : layout
        updateItemSize()
        collectionView.layoutSubtreeIfNeeded()
        if let index = selectedIndex {
            collectionView.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .centeredVertically)
        }
        schedulePlayback()
    }

    @objc func toggleAutoplay(_ sender: Any?) {
        autoplay.toggle()
        updatePlayback()
    }

    @objc func zoomIn(_ sender: Any?) {
        guard let size = Self.tileSizes.first(where: { $0 > tileSize }) else { return }
        setTileSize(size)
    }

    @objc func zoomOut(_ sender: Any?) {
        guard let size = Self.tileSizes.last(where: { $0 < tileSize }) else { return }
        setTileSize(size)
    }

    private func setTileSize(_ size: Double) {
        tileSize = size
        updateItemSize()
        if let index = selectedIndex {
            collectionView.layoutSubtreeIfNeeded()
            collectionView.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .centeredVertically)
        }
    }

    // MARK: Quick Look

    private func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else if selectedItem != nil {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func refreshQuickLook() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible
        else { return }
        panel.reloadData()
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
        quickLookOpen = true
        updateRunning()
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        quickLookOpen = false
        updateRunning()
    }
}

// MARK: - Collection View

extension GridViewController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let tile = collectionView.makeItem(withIdentifier: TileItem.id, for: indexPath) as! TileItem
        let media = items[indexPath.item]
        let cache = ThumbnailCache.shared
        tile.show(media, image: cache.cached(media), showName: showNames)
        if !tile.hasImage {
            tile.loading = cache.load(media) { [weak tile] image in
                guard let tile, tile.media == media else { return }
                tile.setImage(image)
            }
        }
        return tile
    }

    func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        if let tile = item as? TileItem, let url = tile.media?.url, let loop = players[url] {
            tile.playVideo(loop.player)
        }
        if autoplay { schedulePlayback() }
    }

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        guard let tile = item as? TileItem else { return }
        tile.loading?.cancel()
        tile.loading = nil
        tile.stopVideo()
        if autoplay { schedulePlayback() }
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        updatePlayback()
        refreshQuickLook()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        updatePlayback()
        refreshQuickLook()
    }
}

extension GridViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleNames(_:)): menuItem.state = showNames ? .on : .off
        case #selector(toggleSound(_:)): menuItem.state = muted ? .off : .on
        case #selector(toggleCollage(_:)): menuItem.state = collage ? .on : .off
        case #selector(toggleAutoplay(_:)): menuItem.state = autoplay ? .on : .off
        case #selector(zoomIn(_:)): return tileSize < Self.tileSizes.last!
        case #selector(zoomOut(_:)): return tileSize > Self.tileSizes.first!
        case #selector(showInFinder(_:)): return folder != nil
        default: break
        }
        return true
    }
}

extension GridViewController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedItem == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard let url = selectedItem?.url else { return nil }
        return url as NSURL
    }

    /// Pfeiltasten blättern auch bei offener Vorschau durch das Raster.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, (123...126).contains(event.keyCode) else { return false }
        collectionView.keyDown(with: event)
        return true
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let index = selectedIndex, let window = view.window,
              let tile = collectionView.item(at: IndexPath(item: index, section: 0)) as? TileItem else { return .zero }
        return window.convertToScreen(tile.view.convert(tile.mediaRect, to: nil))
    }
}

// MARK: - Views

/// Ein Video in Endlosschleife.
final class LoopPlayer {
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?

    init(_ url: URL) {
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
    }

    func stop() {
        looper?.disableLooping()
        looper = nil
        player.pause()
        player.removeAllItems()
    }
}

final class GridCollectionView: NSCollectionView {
    var onSpace: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { onSpace?() } else { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        let hit = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        if event.clickCount == 2, hit != nil { onDoubleClick?() }
    }
}

/// Meldet, wie weit oben über den Rand hinaus gezogen wird, und ob beim Loslassen weit genug.
final class PullScrollView: NSScrollView {
    static let threshold: CGFloat = 70
    var onPull: (() -> Void)?
    var onOverscroll: (() -> Void)?
    private var armed = false

    /// Wie weit der Inhalt gerade über seinen oberen Rand hinaus gezogen ist.
    var overscroll: CGFloat { max(0, -(contentView.bounds.minY + contentInsets.top)) }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        // Nur die Geste mit den Fingern zählt, nicht der Schwung danach.
        switch event.phase {
        case .began, .changed: armed = overscroll >= Self.threshold
        case .ended: if armed { onPull?() }
        default: break
        }
    }

    /// Läuft bei jeder Bewegung, auch beim Zurückfedern ohne Finger.
    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        onOverscroll?()
    }
}

/// Nimmt einen Ordner oder eine Datei per Drag & Drop an.
final class DropView: NSView {
    var onDrop: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        url(from: sender) == nil ? [] : .generic
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = url(from: sender) else { return false }
        onDrop?(url)
        return true
    }

    private func url(from info: NSDraggingInfo) -> URL? {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?
            .first as? URL
    }
}
