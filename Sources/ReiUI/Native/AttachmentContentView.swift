import AVKit
import AppKit
import Quartz
import ReiCore

final class AttachmentContentView: NSView {
    enum Kind {
        case image
        case audio(TimeInterval?)
        case video, file
    }
    let asset: Asset
    private let environment: AppEnvironment
    private let kind: Kind
    private let column = NativeUI.column(spacing: 6)
    private let status = NativeUI.label("", style: .caption1, secondary: true)
    private var work: Task<Void, Never>?
    private var imageView: NSImageView?
    private var playerView: AVPlayerView?
    private var preview: AttachmentPreviewController?
    var onAccess: (() async throws -> Void)?
    var onSizeChange: (() -> Void)?

    init(asset: Asset, environment: AppEnvironment, kind: Kind) {
        self.asset = asset
        self.environment = environment
        self.kind = kind
        super.init(frame: .zero)
        NativeUI.embed(column, in: self)
        status.isHidden = true
        switch kind {
        case .image:
            let image = NSImageView()
            image.imageScaling = .scaleProportionallyUpOrDown
            image.animates = false
            image.setAccessibilityLabel(asset.name)
            image.widthAnchor.constraint(equalToConstant: 220).isActive = true
            image.heightAnchor.constraint(equalToConstant: 180).isActive = true
            imageView = image
            column.addArrangedSubview(image)
            setStatus("Loading image…")
        case .audio(let duration):
            let suffix = duration.map { " · \(Int($0))s" } ?? ""
            addPlaybackHeader("Voice Message" + suffix)
        case .video:
            addPlaybackHeader(asset.name)
        case .file:
            column.addArrangedSubview(NativeUI.label(asset.name))
            column.addArrangedSubview(
                NativeUI.label(
                    ByteCountFormatter.string(fromByteCount: Int64(asset.byteCount), countStyle: .file),
                    style: .caption1, secondary: true))
        }
        let open = ActionButton("Preview", symbol: "eye") { [weak self] in self?.open() }
        let save = ActionButton("Save As…", symbol: "square.and.arrow.down") { [weak self] in self?.save() }
        for button in [open, save] {
            button.bezelStyle = .inline
            button.controlSize = .small
            button.font = .preferredFont(forTextStyle: .caption1)
        }
        column.addArrangedSubview(NativeUI.row([open, save]))
        column.addArrangedSubview(status)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            work?.cancel()
            work = nil
            playerView?.player?.pause()
        } else if case .image = kind, imageView?.image == nil, work == nil {
            work = Task { [weak self] in await self?.loadImage() }
        }
    }

    private func loadImage() async {
        defer { work = nil }
        do {
            let url = try await environment.attachmentURL(for: asset)
            let thumbnail = try await AttachmentImages.thumbnail(at: url)
            try Task.checkCancellation()
            let image: NSImage
            if asset.mimeType == "image/gif" || asset.name.lowercased().hasSuffix(".gif") {
                let data = try await Task.detached { try Data(contentsOf: url) }.value
                guard let loaded = NSImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
                image = loaded
            } else {
                image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
            }
            try Task.checkCancellation()
            imageView?.image = image
            accessibilityChanged()
            setStatus("")
            onSizeChange?()
        } catch is CancellationError {
        } catch { setStatus(error.localizedDescription) }
    }

    @objc private func accessibilityChanged() {
        imageView?.animates =
            imageView?.image != nil
            && (asset.mimeType == "image/gif" || asset.name.lowercased().hasSuffix(".gif"))
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func addPlaybackHeader(_ title: String) {
        let play = ActionButton("", symbol: "play.fill") { [weak self] in self?.play() }
        play.bezelStyle = .circular
        play.imagePosition = .imageOnly
        play.setAccessibilityLabel(
            {
                if case .video = kind { return "Play video" }
                return "Play voice message"
            }())
        column.addArrangedSubview(NativeUI.row([play, NativeUI.label(title)]))
    }

    private func setStatus(_ message: String) {
        status.stringValue = message
        status.isHidden = message.isEmpty
    }

    private func play() {
        guard work == nil else { return }
        if let player = playerView?.player {
            player.play()
            return
        }
        setStatus("Preparing playback…")
        work = Task { [weak self] in
            guard let self else { return }
            defer { work = nil }
            do {
                let isVideo: Bool = {
                    if case .video = kind { return true }
                    return false
                }()
                let source = try await environment.attachmentURL(for: asset)
                let player: AVPlayer
                do {
                    player = try await AttachmentPlayback.load(from: source, mimeType: asset.mimeType)
                } catch is CancellationError { throw CancellationError() } catch {
                    let converted = try await environment.convertedMediaURL(for: asset, isVideo: isVideo)
                    player = try await AttachmentPlayback.load(
                        from: converted, mimeType: isVideo ? "video/mp4" : "audio/wav")
                }
                try Task.checkCancellation()
                let controls = AVPlayerView()
                controls.player = player
                controls.controlsStyle = .inline
                controls.showsFullScreenToggleButton = isVideo
                controls.widthAnchor.constraint(equalToConstant: isVideo ? 300 : 250).isActive = true
                controls.heightAnchor.constraint(equalToConstant: isVideo ? 200 : 60).isActive = true
                column.insertArrangedSubview(controls, at: 1)
                playerView = controls
                setStatus("")
                onSizeChange?()
                player.play()
            } catch is CancellationError {
            } catch { setStatus(error.localizedDescription) }
        }
    }

    private func open() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await onAccess?()
                let source = try await environment.attachmentURL(for: asset)
                let copy = try await AttachmentFiles.previewCopy(of: asset, from: source)
                preview?.close()
                preview = AttachmentPreviewController(url: copy, title: asset.name)
                preview?.showWindow(nil)
            } catch { NativeUI.error(error, on: window) }
        }
    }

    private func save() {
        Task { [weak self] in
            guard let self, let destination = await AttachmentSavePanel.destination(for: asset) else { return }
            do {
                try await onAccess?()
                let source = try await environment.attachmentURL(for: asset)
                try await AttachmentFiles.save(from: source, to: destination)
            } catch { NativeUI.error(error, on: window) }
        }
    }
}

private final class AttachmentPreviewController: NSWindowController, NSWindowDelegate {
    private let url: URL

    init(url: URL, title: String) {
        self.url = url
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        let preview = QLPreviewView(frame: window.contentView!.bounds, style: .normal)!
        preview.previewItem = url as NSURL
        window.contentView = preview
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        // QLPreviewView closes automatically with its window. Its preview must
        // finish closing before the temporary file is removed.
        let directory = url.deletingLastPathComponent()
        Task { try? FileManager.default.removeItem(at: directory) }
    }
}
