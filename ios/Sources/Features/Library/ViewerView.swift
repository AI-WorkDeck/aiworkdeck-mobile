import AVKit
import SwiftUI

/// 记录预览。深色底，左右滑切换同一天的其他件；照片可缩放，录像/录音走系统播放器。
/// 顶部只放核对要用的：日期时间、类型、状态。哈希放在详情里（质证要用时可复制）。不做编辑、不做分享——取证件不该从这里流出去。
struct ViewerView: View {
    let items: [CaptureItem]
    @State private var index: Int
    private let requestedIndex: Int
    var onClose: () -> Void
    var onSelect: ((Int) -> Void)?
    var onToggleFocus: (() -> Void)?
    var isFocused: Bool
    @State private var showingDetails = false
    @State private var playback = RecordPlayback()
#if DEBUG
    var playbackForTesting: ((RecordPlayback) -> Void)?
#endif

    init(items: [CaptureItem], index: Int, onClose: @escaping () -> Void,
         onSelect: ((Int) -> Void)? = nil, onToggleFocus: (() -> Void)? = nil,
         isFocused: Bool = false) {
        self.items = items
        self.requestedIndex = index
        self._index = State(initialValue: index)
        self.onClose = onClose
        self.onSelect = onSelect
        self.onToggleFocus = onToggleFocus
        self.isFocused = isFocused
    }

    private var selectedIndex: Int { min(max(index, 0), items.count - 1) }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    page(item).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

        }
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showingDetails { details }
        }
        .onAppear {
#if DEBUG
            playbackForTesting?(playback)
#endif
        }
        .onChange(of: requestedIndex) { _, value in index = value }
        .onChange(of: index) { _, value in onSelect?(value) }
        .onChange(of: items[selectedIndex].id) { _, id in
            if playback.itemID != id { playback.stop() }
        }
        .onChange(of: AudioRecorderService.shared.isRecording) { _, recording in
            if recording { playback.blockRecording() }
        }
        .onChange(of: CameraService.shared.isRecording) { _, recording in
            if recording { playback.blockRecording() }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func page(_ item: CaptureItem) -> some View {
        switch item.kind {
        case .photo:
            ZoomablePhoto(item: item)
        case .video, .audio:
            MediaPlayerPage(item: item, selected: items[selectedIndex].id == item.id, playback: playback)
        }
    }

    private var topBar: some View {
        let item = items[selectedIndex]
        return HStack(spacing: T.Sp.s3) {
            Button {
                playback.stop()
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: T.touchMin, height: T.touchMin)
            }
            .accessibilityLabel(tr("common.close"))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: T.Sp.s1) {
                    StatusDot(state: item.state, size: 5, onDark: true)
                    Text(item.state.caption)
                        .font(T.F.small())
                        .foregroundStyle(.white)
                    Text(RelativeTime.clock(item.capturedAt))
                        .font(T.F.mono(11))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Text(item.capturedAt.formatted(.dateTime.month().day().locale(L10n.formatLocale)) + " · " + kindLabel(item.kind))
                    .font(T.F.nano())
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 0)
            Button { showingDetails.toggle() } label: {
                Image(systemName: "info.circle")
                    .frame(width: T.touchMin, height: T.touchMin)
            }
            .accessibilityLabel(tr("viewer.details"))
            .accessibilityIdentifier("viewer.details")
            if let onToggleFocus {
                Button(action: onToggleFocus) {
                    Image(systemName: isFocused ? "sidebar.left" : "arrow.up.left.and.arrow.down.right")
                        .frame(width: T.touchMin, height: T.touchMin)
                }
                .accessibilityLabel(tr(isFocused ? "viewer.showList" : "viewer.focus"))
                .accessibilityIdentifier("viewer.focus")
            }
            Text("\(index + 1) / \(items.count)")
                .font(T.F.mono(11))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.trailing, T.Sp.s3)
        }
        .padding(.leading, T.Sp.s2)
        .padding(.bottom, T.Sp.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(colors: [.black.opacity(0.7), .black.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        }
    }

    private var details: some View {
        let item = items[selectedIndex]
        return ScrollView {
            VStack(alignment: .leading, spacing: T.Sp.s2) {
                Text(item.project?.name ?? tr("library.unknownProject")).font(T.F.heading())
                Text(item.state.detail + " · " + item.state.whereItIs).foregroundStyle(.secondary)
                detailRow(tr("details.capturedAt"),
                          item.capturedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(L10n.formatLocale)))
                if let lat = item.manifest.latitude, let lon = item.manifest.longitude {
                    detailRow(tr("details.location"), String(format: "%.5f, %.5f", lat, lon)
                              + (item.manifest.horizontalAccuracy.map { " ±\(Int($0.rounded()))m" } ?? ""))
                }
                detailRow(tr("details.device"), item.manifest.deviceModel)
                // 文件指纹：质证时证明文件未被改动；平时用不到，所以只放在详情里、可选中复制。
                detailRow(tr("details.fingerprint"), item.manifest.sha256, mono: true)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(T.Sp.gutter)
        }
        .frame(maxHeight: 260)
        .background(T.D.bg)
    }

    private func detailRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(T.F.nano()).foregroundStyle(.white.opacity(0.5))
            if mono {
                // 哈希保持 LTR（RTL 语言下也不翻转）
                Text(value).font(T.F.mono(10)).textSelection(.enabled)
                    .environment(\.layoutDirection, .leftToRight)
            } else {
                Text(value).font(T.F.small()).textSelection(.enabled)
            }
        }
    }

    private func kindLabel(_ kind: MediaKind) -> String {
        switch kind {
        case .photo: tr("home.mode.photo")
        case .video: tr("home.mode.video")
        case .audio: tr("home.mode.audio")
        }
    }

}

/// 照片页：双指缩放、双击 1x / 2.5x 切换、放大后可拖。
/// 图按 2048pt 降采样：全尺寸 JPEG 进内存在连续左右滑时会被系统杀掉。
private struct ZoomablePhoto: View {
    let item: CaptureItem

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(magnify.simultaneously(with: drag))
                        .onTapGesture(count: 2) { toggleZoom() }
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .task(id: item.id) {
            image = await ThumbLoader.shared.thumbnail(
                id: item.id, url: item.localURL, kind: .photo,
                maxPixel: 2048 * displayScale
            )
        }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                scale = min(max(lastScale * v.magnification, 1), 5)
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1.01 { reset() }
            }
    }

    /// 只在放大后接管拖动，否则会抢掉 TabView 的翻页手势
    private var drag: some Gesture {
        DragGesture(minimumDistance: scale > 1 ? 0 : 1000)
            .onChanged { v in
                offset = CGSize(width: lastOffset.width + v.translation.width,
                                height: lastOffset.height + v.translation.height)
            }
            .onEnded { _ in lastOffset = offset }
    }

    private func toggleZoom() {
        withAnimation(T.A.base) {
            if scale > 1 { reset() } else { scale = 2.5; lastScale = 2.5 }
        }
    }

    private func reset() {
        scale = 1; lastScale = 1
        offset = .zero; lastOffset = .zero
    }
}

/// The player belongs to the selected record, not to either navigation column.
/// Resizing and collapsing the split view therefore do not recreate playback.
@MainActor
@Observable
final class RecordPlayback {
    private(set) var player: AVPlayer?
    private(set) var itemID: UUID?
    private(set) var playing = false
    private(set) var message: String?
    /// 当前位置与总长（秒），供录音进度条拖动定位。
    private(set) var time: Double = 0
    private(set) var duration: Double = 0
    private var timeObserver: Any?
    private var generation = UUID()
    private let isRecording: () -> Bool

    init(isRecording: @escaping () -> Bool = {
        AudioRecorderService.shared.isRecording || AudioRecorderService.shared.isBusy ||
            CameraService.shared.isRecording || CameraService.shared.isStartingRecording
    }) {
        self.isRecording = isRecording
    }

    private var recording: Bool { isRecording() }

    func prepare(_ item: CaptureItem) async {
        guard !recording else { blockRecording(); return }
        if itemID == item.id, player != nil { return }
        stop()
        itemID = item.id
        let request = UUID()
        generation = request
        guard FileManager.default.fileExists(atPath: item.localURL.path) else {
            message = tr("player.unavailable"); return
        }
        let asset = AVURLAsset(url: item.localURL)
        guard (try? await asset.load(.isPlayable)) == true else {
            if generation == request { message = tr("player.unavailable") }
            return
        }
        guard !Task.isCancelled, generation == request else { return }
        guard !recording else { blockRecording(); return }
        guard await configureAudioSession(active: true, playback: true) else {
            if generation == request { message = tr("player.unavailable") }
            return
        }
        guard !Task.isCancelled, generation == request, !recording else { return }
        let loadedDuration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        guard !Task.isCancelled, generation == request else { return }
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        duration = loadedDuration.isFinite ? loadedDuration : 0
        time = 0
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.time = CMTimeGetSeconds(t) }
        }
        self.player = player
        message = nil
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        let target = min(max(seconds, 0), duration)
        time = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(_ delta: Double) { seek(to: time + delta) }

    func toggle() {
        guard !recording else { blockRecording(); return }
        guard let player else { return }
        if playing { player.pause() }
        else {
            if player.currentTime() >= (player.currentItem?.duration ?? .positiveInfinity) {
                player.seek(to: .zero)
            }
            player.play()
        }
        playing.toggle()
    }

    func didEnd(_ ended: AVPlayerItem) {
        guard ended === player?.currentItem else { return }
        playing = false
        player?.seek(to: .zero)
    }

    func blockRecording() {
        stop()
        message = tr("player.stopRecordingFirst")
    }

    func stop() {
        generation = UUID()
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        time = 0
        duration = 0
        player = nil
        itemID = nil
        playing = false
        message = nil
    }
}

private struct MediaPlayerPage: View {
    let item: CaptureItem
    let selected: Bool
    let playback: RecordPlayback

    private var playbackActive: Bool {
        selected && !AudioRecorderService.shared.isRecording && !AudioRecorderService.shared.isBusy &&
            !CameraService.shared.isRecording && !CameraService.shared.isStartingRecording
    }

    var body: some View {
        Group {
            if selected, let message = playback.message {
                Text(message).foregroundStyle(.white).padding(T.Sp.gutter)
            } else if item.kind == .audio {
                VStack(spacing: T.Sp.s4) {
                    Image(systemName: "waveform").font(.system(size: 44, weight: .light))
                    Text(tr("home.mode.audio")).font(T.F.heading())
                    AudioScrubber(playback: playback, enabled: selected && playback.player != nil)
                    HStack(spacing: T.Sp.s8) {
                        Button { playback.skip(-15) } label: {
                            Image(systemName: "gobackward.15").font(.system(size: 24)).frame(width: T.touchMin, height: T.touchMin)
                        }
                        .accessibilityLabel(tr("player.back15"))
                        Button(action: playback.toggle) {
                            Image(systemName: playback.playing ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 56))
                                .frame(minWidth: T.touchMin, minHeight: T.touchMin)
                        }
                        .accessibilityLabel(tr(playback.playing ? "player.pause" : "player.play"))
                        .accessibilityIdentifier("media.playback")
                        Button { playback.skip(15) } label: {
                            Image(systemName: "goforward.15").font(.system(size: 24)).frame(width: T.touchMin, height: T.touchMin)
                        }
                        .accessibilityLabel(tr("player.forward15"))
                    }
                    .disabled(!selected || playback.player == nil)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, T.Sp.gutter)
                .frame(maxWidth: 560)
            } else if selected, let player = playback.player {
                VideoPlayer(player: player)
            }
        }
        .task(id: playbackActive) {
            if selected { await playback.prepare(item) }
            else if playback.itemID == item.id { playback.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { note in
            if let ended = note.object as? AVPlayerItem { playback.didEnd(ended) }
        }
    }
}

/// 录音进度条：拖到任意位置，左右显示已播 / 总长。
/// 录像用系统 VideoPlayer，自带进度条，不重复做。
private struct AudioScrubber: View {
    let playback: RecordPlayback
    let enabled: Bool
    @State private var dragging: Double?

    var body: some View {
        VStack(spacing: T.Sp.s1) {
            Slider(value: Binding(
                get: { dragging ?? playback.time },
                set: { dragging = $0 }
            ), in: 0...max(playback.duration, 1)) { editing in
                if !editing, let d = dragging { playback.seek(to: d); dragging = nil }
            }
            .tint(.white)
            HStack {
                Text(Self.clock(dragging ?? playback.time))
                Spacer()
                Text(Self.clock(playback.duration))
            }
            .font(T.F.mono(11))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.6))
            .environment(\.layoutDirection, .leftToRight)
        }
        .disabled(!enabled)
        .accessibilityIdentifier("media.scrubber")
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.isFinite ? max(seconds, 0) : 0)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
