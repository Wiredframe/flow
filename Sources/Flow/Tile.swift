import AppKit
import AVFoundation

final class TileItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("Tile")

    private(set) var media: MediaItem?
    var loading: Operation?
    private var tile: TileView { view as! TileView }

    override func loadView() { view = TileView() }

    override var isSelected: Bool {
        didSet { tile.isSelected = isSelected }
    }

    var hasImage: Bool { tile.image != nil }
    var isPlaying: Bool { tile.isPlaying }

    func show(_ media: MediaItem, image: CGImage?, showName: Bool) {
        self.media = media
        tile.image = image
        tile.name = showName ? media.label : nil
    }

    func setImage(_ image: CGImage?) { tile.image = image }
    func showName(_ show: Bool) { tile.name = show ? media?.label : nil }
    func playVideo(_ player: AVPlayer) { tile.playVideo(player) }
    func stopVideo() { tile.stopVideo() }

    override func prepareForReuse() {
        super.prepareForReuse()
        loading?.cancel()
        loading = nil
        tile.stopVideo()
        tile.image = nil
        media = nil
    }
}

final class TileView: NSView {
    static let radius: CGFloat = 15
    static let nameHeight: CGFloat = 21

    private let imageLayer = CALayer()
    private let playerLayer = AVPlayerLayer()
    private let ringLayer = CALayer()
    private let label = PassiveLabel(labelWithString: "")
    private var readyObservation: NSKeyValueObservation?

    var image: CGImage? {
        didSet { imageLayer.contents = image }
    }
    var name: String? {
        didSet {
            label.stringValue = name ?? ""
            label.isHidden = name == nil
        }
    }
    var isSelected = false {
        didSet { updateColors() }
    }
    var isPlaying: Bool { playerLayer.player != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        for layer in [imageLayer, playerLayer] as [CALayer] {
            layer.masksToBounds = true
            layer.cornerRadius = Self.radius
            layer.cornerCurve = .continuous
        }
        imageLayer.contentsGravity = .resizeAspectFill
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.isHidden = true
        ringLayer.borderWidth = 4
        ringLayer.cornerRadius = Self.radius
        ringLayer.cornerCurve = .continuous
        ringLayer.isHidden = true
        layer?.addSublayer(imageLayer)
        layer?.addSublayer(playerLayer)
        layer?.addSublayer(ringLayer)

        label.font = .systemFont(ofSize: 12, weight: .light)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.isHidden = true
        addSubview(label)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let square = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.width)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = square
        playerLayer.frame = square
        ringLayer.frame = square
        CATransaction.commit()
        label.frame = CGRect(x: 0, y: square.maxY + 3, width: bounds.width, height: Self.nameHeight - 3)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            imageLayer.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            ringLayer.borderColor = NSColor.controlAccentColor.cgColor
        }
        ringLayer.isHidden = !isSelected
        label.textColor = isSelected ? .controlAccentColor : .secondaryLabelColor
    }

    /// Zeigt das Video erst, wenn das erste Bild da ist, damit nichts schwarz aufblitzt.
    func playVideo(_ player: AVPlayer) {
        playerLayer.player = player
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            DispatchQueue.main.async {
                guard let self, self.playerLayer.player != nil else { return }
                self.playerLayer.isHidden = !layer.isReadyForDisplay
            }
        }
    }

    func stopVideo() {
        readyObservation = nil
        playerLayer.player = nil
        playerLayer.isHidden = true
    }
}

/// Beschriftung, die Klicks an die Kachel durchreicht.
final class PassiveLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
