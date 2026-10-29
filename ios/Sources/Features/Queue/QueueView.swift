import SwiftUI

/// 上传队列。存在的理由只有一个：**出事的时候能看懂、能自救。**
/// 只给一个红点，用户既不知道该重试还是该找人，也不知道是自己网络的问题还是我们的问题。
///
/// 汇总全部项目和未归类资料；切换采集目标不改变这里的范围。
struct QueueView: View {
    @Environment(AppModel.self) private var model
    var onClose: () -> Void
    @State private var selectedID: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var projectAction: ProjectAction?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private struct ProjectAction: Identifiable {
        let item: CaptureItem
        let copy: Bool
        var id: UUID { item.id }
    }

    private var scoped: [CaptureItem] { model.items }
    private var unassigned: [CaptureItem] { scoped.filter { $0.project == nil && $0.state == .waiting } }
    private var failed: [CaptureItem] { scoped.filter { $0.state == .failed } }
    private var active: [CaptureItem] { scoped.filter { ($0.state == .waiting && $0.project != nil) || $0.state == .uploading } }
    private var staged: [CaptureItem] { scoped.filter { $0.state == .uploaded } }
    private var landed: [CaptureItem] { scoped.filter { $0.state == .arrived } }

    var body: some View {
        GeometryReader { geometry in
            let wide = horizontalSizeClass == .regular && geometry.size.width >= 700 &&
                geometry.size.width > geometry.size.height && !dynamicTypeSize.isAccessibilitySize
            NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if !failed.isEmpty { section(tr("queue.section.failed"), failed, tint: T.S.failed) }
                        if !unassigned.isEmpty { section(tr("library.unknownProject"), unassigned, tint: T.L.fgMuted) }
                        if !active.isEmpty { section(tr("queue.section.uploading"), active, tint: T.S.waiting) }
                        if !staged.isEmpty { section(tr("queue.section.staged"), staged, tint: T.S.moving) }
                        if !landed.isEmpty { section(tr("queue.section.landed"), landed, tint: T.S.arrived) }
                        if scoped.isEmpty { empty }
                    }.padding(.horizontal, T.Sp.gutter)
                }
                .background(T.L.bg)
                .foldAwareSidebarWidth(in: geometry, minimum: 280, ideal: 340)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 1) {
                            Text(tr("queue.title")).font(T.F.heading()).foregroundStyle(T.L.fg)
                            Text(tr("queue.allProjects")).font(T.F.nano()).foregroundStyle(T.L.fgFaint)
                                .accessibilityIdentifier("queue.scope")
                        }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button(tr("common.close"), action: onClose).accessibilityIdentifier("queue.close")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if !failed.isEmpty {
                            Button(tr("queue.retryAll")) { model.retryFailedUploads() }.font(T.F.small())
                        }
                    }
                }
            } detail: {
                Group {
                    if let item = scoped.first(where: { $0.id == selectedID }) {
                        details(item)
                    } else {
                        ContentUnavailableView(tr("queue.chooseItem"), systemImage: "arrow.up.circle")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(T.L.bg)
                .navigationBarBackButtonHidden()
                .navigationTitle(tr("queue.details"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(tr("common.back")) {
                            selectedID = nil
                            compactColumn = .sidebar
                            columnVisibility = .all
                        }.accessibilityIdentifier("queue.back")
                    }
                }
            }
            .navigationSplitViewStyle(.automatic)
            .environment(\.horizontalSizeClass, wide ? .regular : .compact)
            // Compact navigation uses compactColumn. Hiding the sidebar there
            // can be written back by UIKit after the window expands again.
            .onChange(of: wide, initial: true) { _, _ in
                columnVisibility = .all
            }
        }
        .sheet(item: $projectAction) { action in
            ProjectPickerView(onClose: { projectAction = nil }, onSelect: { target in
                if action.copy {
                    let copy = try await model.copy(action.item, to: target)
                    selectedID = copy.id
                } else {
                    try await model.move(action.item, to: target)
                }
                compactColumn = .detail
            }, titleKey: action.copy ? "queue.copy" : "library.move",
               hintKey: action.copy ? "queue.copyHint" : "library.moveHint")
                .environment(model).preferredColorScheme(.light)
        }
        .task {
            while !Task.isCancelled {
                model.checkDelivered()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    private func details(_ item: CaptureItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: T.Sp.s4) {
                EvidenceThumb(item: item)
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .clipped()
                Text(item.state.detail).font(T.F.heading()).accessibilityIdentifier("queue.selectedStatus")
                Text(item.project == nil ? tr("queue.unassigned") : item.state.whereItIs).foregroundStyle(T.L.fgMuted)
                Text(item.project?.name ?? tr("library.unknownProject")).font(T.F.body())
                projectActions(item).buttonStyle(.bordered)
                if !item.canMoveToProject { Text(tr("library.moveSynced")).font(T.F.micro()).foregroundStyle(T.L.fgMuted) }
                Text(item.capturedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(L10n.formatLocale)))
                if item.state == .uploading { ProgressView(value: max(item.progress, 0.05)) }
                if let error = item.lastError, item.state == .failed {
                    Text(error).foregroundStyle(T.S.failed)
                    Button(tr("project.retry")) { model.retry(item) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("queue.retrySelected")
                }
                if item.state == .uploaded,
                   let expiry = model.cloudExpiry[item.manifest.clientMediaId.uuidString.lowercased()] {
                    Text(tr("queue.expiresOn", ["date": Self.monthDay(expiry)]))
                }
                Text(item.manifest.sha256).font(T.F.mono(11)).textSelection(.enabled)
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(T.Sp.gutter)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityIdentifier("queue.detail." + item.id.uuidString)
    }

    private func section(_ title: String, _ items: [CaptureItem], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Eyebrow(text: title)
                Spacer()
                Text("\(items.count)")
                    .font(T.F.mono(11, .medium))
                    .foregroundStyle(tint)
            }
            .padding(.top, T.Sp.s6)
            .padding(.bottom, T.Sp.s2)

            ForEach(items) { item in
                HStack(spacing: T.Sp.s2) {
                    Button {
                        selectedID = item.id
                        compactColumn = .detail
                    } label: { row(item) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("queue.item." + item.id.uuidString)
                    .accessibilityAddTraits(selectedID == item.id ? .isSelected : [])
                    if item.state == .failed {
                        Button(tr("project.retry")) { model.retry(item) }
                            .font(T.F.micro()).foregroundStyle(T.L.accent)
                    }
                }
                .background(selectedID == item.id ? T.L.accent.opacity(0.08) : Color.clear)
                .contextMenu { projectActions(item) }
                Hairline()
            }
        }
    }

    private func row(_ item: CaptureItem) -> some View {
        HStack(alignment: .top, spacing: T.Sp.s3) {
            EvidenceThumb(item: item)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: T.Sp.s1) {
                    StatusDot(state: item.state, size: 5)
                    Text(item.state.caption)
                        .font(T.F.small())
                        .foregroundStyle(T.L.fg)
                    Text(RelativeTime.clock(item.capturedAt))
                        .font(T.F.mono(11))
                        .foregroundStyle(T.L.fgFaint)
                }

                Text(item.project?.name ?? tr("library.unknownProject"))
                    .font(T.F.nano()).foregroundStyle(T.L.fgMuted)
                    .accessibilityIdentifier("queue.project." + item.id.uuidString)

                if item.state == .uploading {
                    ProgressView(value: max(item.progress, 0.05))
                        .tint(T.S.moving)
                        .padding(.top, 2)
                }

                // 失败原因照实显示。区分「你的网络」与「我们这边」，
                // 用户才知道是该换个地方重试还是该找人。
                if let err = item.lastError, item.state == .failed {
                    Text(err)
                        .font(T.F.nano())
                        .foregroundStyle(T.S.failed)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 1)
                }

                // 中转区不是网盘：到期未被桌面端取走就会被清理。
                // 只在还剩不到 3 天时说话，平时不打扰。
                if item.state == .uploaded,
                   let exp = model.cloudExpiry[item.manifest.clientMediaId.uuidString.lowercased()],
                   exp.timeIntervalSinceNow < 3 * 86_400 {
                    Text(tr("queue.expiresOn", ["date": Self.monthDay(exp)]))
                        .font(T.F.nano())
                        .foregroundStyle(T.S.waiting)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 1)
                }

                // 哈希前 12 位。要核对时不用进详情页。
                Text(item.manifest.sha256.prefix(12))
                    .font(T.F.mono(10))
                    .foregroundStyle(T.L.fgFaint)
                    .padding(.top, 1)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right").font(.caption).foregroundStyle(T.L.fgFaint)
        }
        .padding(.vertical, T.Sp.s3)
        .contentShape(Rectangle())
    }

    private static func monthDay(_ d: Date) -> String {
        // 模板而不是写死「M月d日」：中文出「9月12日」，英文出「Sep 12」，跟着界面语言走。
        let f = DateFormatter()
        f.locale = L10n.formatLocale
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: d)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: T.Sp.s2) {
            Text(tr("library.empty"))
                .font(T.F.body())
                .foregroundStyle(T.L.fg)
            Text(tr("queue.emptyHint"))
                .font(T.F.micro())
                .foregroundStyle(T.L.fgFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, T.Sp.s16)
    }

    @ViewBuilder
    private func projectActions(_ item: CaptureItem) -> some View {
        if item.canMoveToProject {
            Button { projectAction = ProjectAction(item: item, copy: false) } label: {
                Label(tr("library.move"), systemImage: "folder")
            }.accessibilityIdentifier("queue.move")
        }
        Button { projectAction = ProjectAction(item: item, copy: true) } label: {
            Label(tr("queue.copy"), systemImage: "doc.on.doc")
        }.accessibilityIdentifier("queue.copy")
    }
}
