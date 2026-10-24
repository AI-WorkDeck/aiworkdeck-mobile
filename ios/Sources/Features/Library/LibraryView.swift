import SwiftUI

/// 影像浏览 —— 方向 B「影像优先」。
///
/// 深色，影像铺满，玻璃条压在影像上。这是全局唯一真正用得上毛玻璃的地方：
/// 玻璃需要下面有东西可透，压在纯色背景上等于白做。
///
/// 只看一个项目：默认当前项目，顶栏可切换看别的项目（只切看的对象，不切拍摄目标）。
/// 项目内按自然日分段。列数、网格/列表、多选删除都在这一页。
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    var onClose: () -> Void
    var fixedProject: RelayProject? = nil
    var embedded = false

    @State private var audioOnly = false
    @State private var viewingID: String?
    @AppStorage("libraryColumns") private var columns = 3
    @AppStorage("libraryViewMode") private var viewMode = "grid"
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var confirmDelete = false
    @State private var viewer: ViewerTarget?
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var focusPreview = false
    @State private var scrollID: UUID?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var appeared = false
    @State private var movingItem: CaptureItem?
    @State private var moveError: String?

    /// 预览目标：同一天的件 + 当前下标。
    private struct ViewerTarget: Identifiable {
        let dayID: Date
        var items: [CaptureItem]
        var index: Int
        var id: Date { dayID }
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - 派生

    private var projects: [LibraryProject] {
        LibraryGrouping.projects(in: model.items, current: model.selectedProject)
    }
    private var viewing: LibraryProject {
        if let fixedProject { return LibraryProject(fixedProject) }
        let id = viewingID ?? model.currentProjectID
        return projects.first { $0.id == id } ?? projects.first ?? .unknown
    }
    private var items: [CaptureItem] {
        LibraryGrouping.items(model.items, in: viewing.id, project: fixedProject ?? (model.selectedProject?.id == viewing.id ? model.selectedProject : nil)).filter { !audioOnly || $0.kind == .audio }
    }
    private var days: [LibraryGrouping.DaySection] { LibraryGrouping.days(items) }
    private var tally: TransferTally { TransferTally.of(items) }
    private var selectedItems: [CaptureItem] { items.filter { selected.contains($0.id) } }
    private var isGrid: Bool { viewMode == "grid" }

    private func gridColumns(width: CGFloat) -> [GridItem] {
        let minimumWidth: CGFloat = dynamicTypeSize.isAccessibilitySize ? 156 : 104
        let count = max(1, min(columns, Int(width / minimumWidth)))
        return Array(repeating: GridItem(.flexible(), spacing: 1.5), count: count)
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = horizontalSizeClass == .regular && geometry.size.width >= 700 &&
                geometry.size.width > geometry.size.height && !dynamicTypeSize.isAccessibilitySize
            Group {
                if embedded {
                    // The workspace already owns split navigation. Keep its record
                    // browser mounted while a record is being inspected.
                    ZStack {
                        browser
                            .opacity(viewer == nil ? 1 : 0)
                            .allowsHitTesting(viewer == nil)
                            .accessibilityHidden(viewer != nil)
                        if viewer != nil { detail(wide: false) }
                    }
                } else {
                    NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
                        browser
                            .foldAwareSidebarWidth(in: geometry, minimum: 280, ideal: 320)
                            .toolbar(.hidden, for: .navigationBar)
                    } detail: {
                        detail(wide: wide)
                            .toolbar(.hidden, for: .navigationBar)
                    }
                    .navigationSplitViewStyle(.automatic)
                    .environment(\.horizontalSizeClass, wide ? .regular : .compact)
                }
            }
            .onChange(of: wide, initial: true) { _, wide in
                columnVisibility = focusPreview || (!wide && viewer != nil) ? .detailOnly : .all
            }
            .onChange(of: viewer?.id) { _, _ in
                columnVisibility = focusPreview || (!wide && viewer != nil) ? .detailOnly : .all
            }
        }
        .onAppear { appeared = true }
        .onChange(of: fixedProject?.id) { _, _ in selected = []; selecting = false; closePreview() }
        .onChange(of: audioOnly) { _, _ in selected = []; selecting = false; closePreview() }
        .onChange(of: items.map(\.id)) { _, validIDs in
            guard var target = viewer else { return }
            let selectedID = target.items[target.index].id
            target.items.removeAll { !validIDs.contains($0.id) }
            if let index = target.items.firstIndex(where: { $0.id == selectedID }) {
                target.index = index
                viewer = target
            } else { closePreview() }
        }
        .sheet(item: $movingItem) { item in
            ProjectPickerView(onClose: { movingItem = nil }, onSelect: { target in
                try await model.move(item, to: target)
                selected = []
                selecting = false
                if fixedProject == nil { viewingID = target.id }
            }).environment(model).preferredColorScheme(.light)
        }
        .alert(tr("library.move"), isPresented: Binding(get: { moveError != nil }, set: { if !$0 { moveError = nil } })) {
            Button(tr("common.ok"), role: .cancel) { moveError = nil }
        } message: { Text(moveError ?? "") }
        // 用 alert 不用 confirmationDialog：后者在 iOS 26 模拟器上把「取消」画丢了，
        // 删除这种事两个按钮必须都看得见
        .alert(tr("delete.title", ["n": String(selected.count)]), isPresented: $confirmDelete) {
            Button(tr("library.delete"), role: .destructive) {
                let ids = Array(selected)
                selected = []
                selecting = false
                Task { await model.delete(ids: ids) }
            }
            Button(tr("common.cancel"), role: .cancel) {}
        } message: {
            Text(LibraryGrouping.deleteWarning(for: selectedItems))
        }
    }

    private var browser: some View {
        GeometryReader { geometry in
            ScrollView {
                if items.isEmpty { emptyState }
                else if isGrid { grid(width: geometry.size.width) }
                else { list }
            }
            .scrollPosition(id: $scrollID)
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: T.Sp.s2) {
                    topBar
                    Picker(tr("library.open"), selection: $audioOnly) {
                        Text(tr("library.all")).tag(false)
                        Text(tr("library.audio")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, T.Sp.gutter)
                    .padding(.bottom, T.Sp.s2)
                }.background(T.D.bg)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if selecting { deleteDock } else { dock }
            }
        }
        .background(T.D.bg)
        .accessibilityIdentifier("library.browser")
    }

    @ViewBuilder
    private func detail(wide: Bool) -> some View {
        if let target = viewer {
            let currentItems = target.items.map { original in items.first(where: { $0.id == original.id }) ?? original }
            ViewerView(items: currentItems, index: target.index, onClose: closePreview,
                       onSelect: { viewer?.index = $0 },
                       onToggleFocus: wide ? {
                           focusPreview.toggle()
                           columnVisibility = focusPreview ? .detailOnly : .all
                       } : nil,
                       isFocused: focusPreview)
                .id(target.id)
        } else {
            ContentUnavailableView(tr("library.chooseRecord"), systemImage: "photo.on.rectangle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(T.D.bg)
        }
    }

    private func closePreview() {
        viewer = nil
        focusPreview = false
        compactColumn = .sidebar
        columnVisibility = .all
    }

    // MARK: - 网格

    private func grid(width: CGFloat) -> some View {
        LazyVGrid(columns: gridColumns(width: width), spacing: 1.5, pinnedViews: [.sectionHeaders]) {
            ForEach(days) { day in
                Section {
                    ForEach(Array(day.items.enumerated()), id: \.element.id) { index, item in
                        cell(item, in: day)
                            .id(item.id)
                            .opacity(appeared || reduceMotion ? 1 : 0)
                            .offset(y: appeared || reduceMotion ? 0 : 10)
                            .animation(
                                T.A.rise.delay(Double(min(index, 12)) * 0.045),
                                value: appeared
                            )
                    }
                } header: {
                    dayHeader(day)
                }
            }
        }
        .scrollTargetLayout()
    }

    /// 非选择态点一件 = 预览，左右滑同一天的其他件
    private func open(_ item: CaptureItem, in day: LibraryGrouping.DaySection) {
        guard let i = day.items.firstIndex(where: { $0.id == item.id }) else { return }
        viewer = ViewerTarget(dayID: day.id, items: day.items, index: i)
        compactColumn = .detail
    }

    private func cell(_ item: CaptureItem, in day: LibraryGrouping.DaySection) -> some View {
        let checked = selected.contains(item.id)
        return Button {
            if selecting { toggle(item.id) } else { open(item, in: day) }
        } label: {
            EvidenceThumb(item: item, onDark: true)
                .aspectRatio(1, contentMode: .fill)
                .overlay(alignment: .topTrailing) {
                    StatusDot(state: item.state, onDark: true)
                        .padding(8)
                }
                .overlay(alignment: .bottomLeading) {
                    Text(RelativeTime.clock(item.capturedAt))
                        .font(T.F.mono(10))
                        .tracking(0.4)
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(8)
                }
                .overlay(alignment: .bottom) {
                    if item.state == .uploading {
                        // 进度直接画在图上。单独开一栏进度条会把注意力从影像上拉走。
                        GeometryReader { geo in
                            Rectangle()
                                .fill(T.S.movingOnDark)
                                .frame(width: geo.size.width * item.progress, height: 2)
                        }
                        .frame(height: 2)
                    }
                }
                .overlay { if selecting { selectionMark(checked) } }
                .overlay {
                    if !selecting, viewer?.items[viewer?.index ?? 0].id == item.id {
                        Rectangle().stroke(T.L.accent, lineWidth: 3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { moveButton(item) }
        .accessibilityElement()
        .accessibilityIdentifier("library.item.\(item.id)")
        .accessibilityLabel(
            "\(kindLabel(item.kind))，\(RelativeTime.clock(item.capturedAt))，\(item.state.caption)"
        )
        .accessibilityAddTraits(selecting && checked ? [.isButton, .isSelected] : .isButton)
    }

    private func selectionMark(_ checked: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(checked ? 0.35 : 0)
            Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(checked ? T.S.movingOnDark : .white.opacity(0.8))
                .padding(8)
        }
    }

    private func dayHeader(_ day: LibraryGrouping.DaySection) -> some View {
        HStack {
            Eyebrow(text: day.title, color: .white.opacity(0.6))
            Spacer()
        }
        .padding(.horizontal, T.Sp.gutter)
        .padding(.vertical, T.Sp.s2)
        .background(T.D.bg.opacity(0.92))
    }

    // MARK: - 列表

    private var list: some View {
        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(days) { day in
                Section {
                    ForEach(day.items) { item in
                        row(item, in: day).id(item.id)
                        Hairline(color: T.D.rule)
                    }
                } header: {
                    dayHeader(day)
                }
            }
        }
        .scrollTargetLayout()
    }

    private func row(_ item: CaptureItem, in day: LibraryGrouping.DaySection) -> some View {
        let checked = selected.contains(item.id)
        return HStack(alignment: .top, spacing: T.Sp.s3) {
            if selecting {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(checked ? T.S.movingOnDark : .white.opacity(0.5))
                    .frame(width: 24, height: 44)
            }
            EvidenceThumb(item: item, onDark: true)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: T.Sp.s1) {
                    StatusDot(state: item.state, size: 5, onDark: true)
                    Text(item.state.caption)
                        .font(T.F.small())
                        .foregroundStyle(T.D.fg)
                    Text(RelativeTime.clock(item.capturedAt))
                        .font(T.F.mono(11))
                        .foregroundStyle(T.D.fgMuted)
                }
                if let err = item.lastError, item.state == .failed {
                    Text(err)
                        .font(T.F.nano())
                        .foregroundStyle(T.S.failed)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(item.manifest.sha256.prefix(12))
                    .font(T.F.mono(10))
                    .foregroundStyle(T.D.fgMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, T.Sp.gutter)
        .padding(.vertical, T.Sp.s3)
        .contentShape(Rectangle())
        .onTapGesture { if selecting { toggle(item.id) } else { open(item, in: day) } }
        .contextMenu { moveButton(item) }
        .accessibilityIdentifier("library.item.\(item.id)")
    }

    private func moveButton(_ item: CaptureItem) -> some View {
        Button {
            if item.canMoveToProject { movingItem = item }
            else { moveError = tr("library.moveSynced") }
        } label: { Label(tr("library.move"), systemImage: "folder") }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: T.Sp.s2) {
            Text(tr("library.empty"))
                .font(T.F.body())
                .foregroundStyle(T.D.fg)
            Text(tr("library.emptyHint"))
                .font(T.F.micro())
                .foregroundStyle(T.D.fgMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, T.Sp.gutter)
        .padding(.top, T.Sp.s10)
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func kindLabel(_ kind: MediaKind) -> String {
        switch kind {
        case .photo: tr("home.mode.photo")
        case .video: tr("home.mode.video")
        case .audio: tr("home.mode.audio")
        }
    }

    // MARK: - 顶栏（玻璃压在影像上）

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: T.Sp.s2) {
                if !embedded {
                    Button(action: onClose) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(T.D.fg)
                            .frame(width: T.touchMin, height: T.touchMin)
                    }
                    .accessibilityLabel(tr("common.back"))
                }
                if let fixedProject { Text(fixedProject.name).lineLimit(1) }
                else { projectMenu }
                Spacer(minLength: 0)
                selectButton
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    tallyRow.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    tools
                }
                VStack(alignment: .leading, spacing: 0) {
                    tallyRow
                    tools
                }
            }
            .padding(.leading, T.Sp.s2)
        }
        .padding(.leading, T.Sp.s2)
        .padding(.trailing, T.Sp.s3)
        .padding(.bottom, T.Sp.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .overlay(alignment: .bottom) { Hairline(color: T.D.rule) }
                .ignoresSafeArea(edges: .top)
        }
    }

    /// 项目名就是切换入口。只切看的对象，不动拍摄目标。
    private var projectMenu: some View {
        Menu {
            ForEach(projects) { p in
                Button {
                    viewingID = p.id
                    selected = []
                    closePreview()
                } label: {
                    if p.id == viewing.id {
                        Label(p.name, systemImage: "checkmark")
                    } else {
                        Text(p.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(viewing.name)
                    .font(T.F.heading())
                    .kerning(-0.2)
                    .foregroundStyle(T.D.fg)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(T.D.fgMuted)
            }
        }
        .accessibilityLabel(tr("library.viewing.a11y", ["name": viewing.name]))
    }

    private var tallyRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            pill(tally.uploading, TransferPhase.uploading.caption, T.S.waitingOnDark)
            if tally.failed > 0 {
                Text(tr("tally.failedSuffix", ["m": String(tally.failed)]))
                    .font(T.F.nano())
                    .foregroundStyle(T.S.failed)
                    .padding(.trailing, T.Sp.s2)
            }
            pill(tally.staged, TransferPhase.staged.caption, T.S.movingOnDark)
            pill(tally.landed, TransferPhase.landed.caption, T.S.arrivedOnDark)
        }
        .accessibilityElement(children: .combine)
    }

    private func pill(_ n: Int, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 2) {
            Text("\(n)")
                .font(T.F.mono(13, .medium))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label)
                .font(T.F.nano())
                .foregroundStyle(T.D.fgMuted)
        }
        .padding(.trailing, T.Sp.s2)
    }

    /// 列数和视图工具。
    private var tools: some View {
        HStack(spacing: 0) {
            if isGrid && !selecting {
                toolButton(
                    columns == 2 ? "square.grid.2x2" : columns == 3 ? "square.grid.3x3" : "square.grid.4x3.fill",
                    label: tr("library.columns.a11y", ["n": String(columns)])
                ) {
                    columns = columns >= 4 ? 2 : columns + 1
                }
            }
            if !selecting {
                toolButton(isGrid ? "list.bullet" : "square.grid.2x2",
                           label: isGrid ? tr("library.toList.a11y") : tr("library.toGrid.a11y")) {
                    viewMode = isGrid ? "list" : "grid"
                }
            }
        }
    }

    private var selectButton: some View {
        Button(selecting ? tr("common.cancel") : tr("library.select")) {
            selecting.toggle()
            selected = []
        }
        .font(T.F.small())
        .foregroundStyle(T.D.fg)
        .frame(minWidth: T.touchMin, minHeight: T.touchMin)
        .disabled(items.isEmpty)
    }

    private func toolButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(T.D.fg)
                .frame(width: T.touchMin, height: T.touchMin)
        }
        .accessibilityLabel(label)
    }

    // MARK: - 底座与快门

    private var dock: some View {
        HStack {
            HStack(spacing: T.Sp.s1) {
                BreathingDot(isOn: model.link.isOnline, color: T.S.arrivedOnDark)
                Text(model.link.isOnline ? tr("home.desktop.online") : tr("home.desktop.offline"))
                    .font(T.F.nano())
                    .tracking(0.6)
                    .foregroundStyle(T.D.fgMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 首页现在就是取景器：这里的快门收回浏览页即回到镜头
            ShutterButton(action: onClose)

            Text(model.project.archivePath)
                .font(T.F.nano())
                .tracking(0.6)
                .foregroundStyle(T.D.fgMuted)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, T.Sp.gutter)
        .padding(.top, T.Sp.s3)
        .padding(.bottom, T.Sp.s2)
        .background { dockBackground }
    }

    private var deleteDock: some View {
        HStack {
            Text(selected.isEmpty ? tr("library.selectHint") : tr("library.selectedCount", ["n": String(selected.count)]))
                .font(T.F.small())
                .foregroundStyle(T.D.fgMuted)
            Spacer()
            Button {
                confirmDelete = true
            } label: {
                Text(tr("delete.title", ["n": String(selected.count)]))
                    .font(T.F.small())
                    .foregroundStyle(.white)
                    .padding(.horizontal, T.Sp.s4)
                    .frame(minHeight: T.touchMin)
                    .background(T.S.failed, in: RoundedRectangle(cornerRadius: 2, style: .continuous))
            }
            .disabled(selected.isEmpty)
            .opacity(selected.isEmpty ? 0.4 : 1)
        }
        .padding(.horizontal, T.Sp.gutter)
        .padding(.top, T.Sp.s3)
        .padding(.bottom, T.Sp.s2)
        .background { dockBackground }
    }

    private var dockBackground: some View {
        LinearGradient(
            colors: [T.D.bg.opacity(0), T.D.bg.opacity(0.94)],
            startPoint: .top, endPoint: .bottom
        )
        .background(.ultraThinMaterial.opacity(0.6))
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea(edges: .bottom)
    }
}

/// 物理相机的快门语汇：外环加内芯，按下内芯收缩。不用图标。
private struct ShutterButton: View {
    let action: () -> Void

    @State private var pressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.85), lineWidth: 1.5)
            Circle()
                .fill(.white)
                .frame(width: 52, height: 52)
                .scaleEffect(pressed && !reduceMotion ? 0.86 : 1)
                .animation(T.A.fast, value: pressed)
        }
        .frame(width: 66, height: 66)
        .contentShape(Circle())
        .onLongPressGesture(minimumDuration: 0, pressing: { pressed = $0 }) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        }
        .accessibilityLabel(tr("library.capture.a11y"))
        .accessibilityAddTraits(.isButton)
    }
}

#Preview {
    LibraryView(onClose: {})
        .environment(AppModel())
}
