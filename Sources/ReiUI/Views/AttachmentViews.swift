import AVKit
import AppKit
import QuickLook
import ReiCore
import SwiftUI

/// Opens files with Quick Look and saves them through the standard macOS panel.
/// The preview owns its temporary named copy until its view leaves the hierarchy.
struct AttachmentActionsView: View {
    let asset: Asset
    let environment: AppEnvironment
    var openTitle = "Open"
    var onAccess: (@MainActor () async throws -> Void)?
    var onError: (@MainActor (any Error) -> Void)?
    @State private var previewURL: URL?
    @State private var previewCopy: URL?
    @State private var isWorking = false
    @State private var previewTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 12) {
            Button(openTitle, systemImage: "eye") {
                previewTask?.cancel()
                previewTask = Task { await open() }
            }
            .help("Preview \(asset.name)")
            Button("Save As…", systemImage: "square.and.arrow.down") {
                Task { await save() }
            }
            .help("Save \(asset.name)")
            if isWorking { ProgressView().controlSize(.small) }
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .disabled(isWorking)
        .quickLookPreview($previewURL)
        .onDisappear {
            previewTask?.cancel()
            removePreview()
        }
    }

    private func open() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await onAccess?()
            let source = try await environment.attachmentURL(for: asset)
            try Task.checkCancellation()
            if previewCopy == nil {
                let copy = try await AttachmentFiles.previewCopy(of: asset, from: source)
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
                    return
                }
                previewCopy = copy
            }
            previewURL = previewCopy
        } catch is CancellationError {
            // A preview is no longer needed after its attachment leaves the view.
        } catch {
            report(error)
        }
    }

    private func save() async {
        guard let destination = await AttachmentSavePanel.destination(for: asset) else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await onAccess?()
            let source = try await environment.attachmentURL(for: asset)
            try await AttachmentFiles.save(from: source, to: destination)
        } catch {
            report(error)
        }
    }

    private func report(_ error: any Error) {
        if let onError { onError(error) } else { environment.lastError = error.localizedDescription }
    }

    private func removePreview() {
        previewURL = nil
        if let previewCopy {
            try? FileManager.default.removeItem(at: previewCopy.deletingLastPathComponent())
        }
        previewCopy = nil
    }
}

/// A sampled thumbnail avoids decoding a full-resolution image in every row.
struct ImageSegmentView: View {
    let asset: Asset
    let environment: AppEnvironment
    @State private var thumbnail: CGImage?
    @State private var animation: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var failure: String?
    @State private var previewURL: URL?
    @State private var previewCopy: URL?
    @State private var previewTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let thumbnail {
                Button {
                    previewTask?.cancel()
                    previewTask = Task { await showImage() }
                } label: {
                    Group {
                        if let animation, !reduceMotion {
                            let scale = min(240.0 / Double(thumbnail.width), 240.0 / Double(thumbnail.height))
                            AnimatedAttachmentImage(image: animation, animates: true)
                                .frame(width: Double(thumbnail.width) * scale, height: Double(thumbnail.height) * scale)
                                .allowsHitTesting(false)
                        } else {
                            Image(decorative: thumbnail, scale: 1)
                                .resizable().scaledToFit().frame(maxWidth: 240, maxHeight: 240)
                        }
                    }
                    .clipShape(.rect(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View image: \(asset.name)")
                .help("View full-size image")
            } else if let failure {
                Label(failure, systemImage: "photo.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView("Loading image…").controlSize(.small)
            }
            AttachmentActionsView(asset: asset, environment: environment, openTitle: "View Image")
        }
        .quickLookPreview($previewURL)
        .task(id: asset.id) {
            thumbnail = nil
            animation = nil
            failure = nil
            do {
                let url = try await environment.attachmentURL(for: asset)
                let image = try await AttachmentImages.thumbnail(at: url)
                try Task.checkCancellation()
                thumbnail = image
                if asset.mimeType == "image/gif" || asset.name.lowercased().hasSuffix(".gif") {
                    let data = try await Task.detached { try Data(contentsOf: url, options: .mappedIfSafe) }.value
                    try Task.checkCancellation()
                    guard let loaded = NSImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
                    animation = loaded
                }
            } catch is CancellationError {
                // A thumbnail is no longer needed after its message leaves the view.
            } catch {
                failure = error.localizedDescription
            }
        }
        .onDisappear {
            animation = nil
            previewTask?.cancel()
            previewURL = nil
            if let previewCopy {
                try? FileManager.default.removeItem(at: previewCopy.deletingLastPathComponent())
            }
            previewCopy = nil
        }
    }

    private func showImage() async {
        do {
            if previewCopy == nil {
                let source = try await environment.attachmentURL(for: asset)
                try Task.checkCancellation()
                let copy = try await AttachmentFiles.previewCopy(of: asset, from: source)
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
                    return
                }
                previewCopy = copy
            }
            previewURL = previewCopy
        } catch is CancellationError {
            // A preview is no longer needed after its image leaves the view.
        } catch {
            environment.lastError = error.localizedDescription
        }
    }
}

struct MediaSegmentView: View {
    let asset: Asset
    let environment: AppEnvironment
    var isVideo = false
    var duration: TimeInterval?
    @State private var player: AVPlayer?
    @State private var playbackRequested = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(isVideo ? asset.name : voiceTitle, systemImage: isVideo ? "film" : "waveform")
                    .lineLimit(2)
                Spacer(minLength: 8)
                if player == nil {
                    Button(failure == nil ? "Play" : "Retry", systemImage: "play.fill") {
                        playbackRequested = true
                    }
                    .disabled(playbackRequested)
                    .accessibilityLabel(isVideo ? "Play video" : "Play voice message")
                }
            }
            if let player {
                AttachmentPlayerView(player: player, isVideo: isVideo)
                    .frame(height: isVideo ? 220 : 60)
                    .accessibilityLabel(isVideo ? "Video playback controls" : "Voice playback controls")
            } else if playbackRequested {
                ProgressView("Preparing playback…").controlSize(.small)
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.secondary)
            }
            AttachmentActionsView(asset: asset, environment: environment)
        }
        .font(.callout)
        .padding(10)
        .frame(width: isVideo ? 360 : 300)
        .background(.quinary, in: .rect(cornerRadius: 8))
        .task(id: playbackRequested) {
            guard playbackRequested else { return }
            failure = nil
            do {
                let url = try await environment.attachmentURL(for: asset)
                let loaded: AVPlayer
                do {
                    loaded = try await AttachmentPlayback.load(
                        from: url, mimeType: asset.mimeType ?? AssetStore.mimeType(forFileName: asset.name)
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let converted = try await environment.convertedMediaURL(for: asset, isVideo: isVideo)
                    loaded = try await AttachmentPlayback.load(
                        from: converted, mimeType: isVideo ? "video/mp4" : "audio/wav"
                    )
                }
                try Task.checkCancellation()
                player = loaded
                loaded.play()
            } catch is CancellationError {
                // Leaving the transcript cancels preparation and pauses playback.
            } catch {
                failure = error.localizedDescription
            }
            playbackRequested = false
        }
        .onDisappear { player?.pause() }
    }

    private var voiceTitle: String {
        guard let duration, duration.isFinite, duration > 0 else { return "Voice Message" }
        return "Voice Message · \(duration.formatted(.number.precision(.fractionLength(0))))s"
    }
}

/// AVPlayerView supplies native seek, volume, duration, and fullscreen controls.
private struct AttachmentPlayerView: NSViewRepresentable {
    let player: AVPlayer
    let isVideo: Bool

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = isVideo
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

struct FileSegmentView: View {
    let asset: Asset
    let environment: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(asset.name, systemImage: "doc")
                .font(.callout)
                .textSelection(.enabled)
            Text(ByteCountFormatter.string(fromByteCount: Int64(asset.byteCount), countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)
            AttachmentActionsView(asset: asset, environment: environment)
        }
        .padding(10)
        .background(.quinary, in: .rect(cornerRadius: 8))
    }
}
