import SwiftUI

/// Select a capture destination or explicitly assign an existing local item.
struct ProjectPickerView: View {
    @Environment(AppModel.self) private var model

    var onClose: () -> Void = {}
    var onSelect: ((RelayProject) async throws -> Void)? = nil
    var titleKey: String? = nil
    var hintKey: String? = nil
    var onBrowse: (() -> Void)? = nil
    var projectFilter: ((RelayProject) -> Bool)? = nil
    @State private var choosing = false

    @State private var projects: [RelayProject] = []
    @State private var loading = true
    @State private var error: String?
    @State private var query = ""

    private var captureInProgress: Bool {
        onSelect == nil && (AudioRecorderService.shared.isRecording || AudioRecorderService.shared.isBusy ||
            CameraService.shared.isRecording || CameraService.shared.isStartingRecording || CameraService.shared.isCapturingPhoto)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                if let hint = hintText {
                    Text(hint)
                        .font(T.F.micro())
                        .foregroundStyle(T.L.fgFaint)
                        .padding(.vertical, T.Sp.s2)
                }
                if captureInProgress {
                    Text(tr("project.captureInProgress"))
                        .font(T.F.micro()).foregroundStyle(T.L.fgMuted)
                        .padding(.bottom, T.Sp.s3)
                }

                if loading {
                    loadingRow
                } else if let error {
                    errorBlock(error)
                } else if projects.isEmpty {
                    emptyBlock
                } else {
                    list
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, T.Sp.gutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(T.L.bg)
            .task { await load() }
            .navigationTitle(tr(titleKey ?? (onSelect == nil ? "project.title" : "library.move")))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: tr("workspace.searchProjects"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(tr("common.back"), action: onClose)
                        .accessibilityIdentifier("projectPicker.back")
                }
            }
            .disabled(choosing)
            .overlay { if choosing { ProgressView(tr("common.loading")).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }

        }
    }

    private var hintText: String? {
        hintKey.map { tr($0) } ?? (onSelect == nil ? tr("project.hint", ["date": AppModel.today]) : tr("library.moveHint"))
    }

    /// 选择页只做一件事：尽快点到要的项目。
    /// 顺序：临时项目（仅采集目标）→ 最近用过 → 全部；有搜索词时只显示匹配。
    private var candidates: [RelayProject] { projects.filter { onSelect != nil || $0.isDefault != true } }
    private var matches: [RelayProject] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? candidates : candidates.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }
    private var recent: [RelayProject] {
        guard query.isEmpty, candidates.count > 6 else { return [] }
        return RecentProjects.ids.compactMap { id in candidates.first { $0.id == id } }
    }
    /// 只有项目分布在多台电脑上时，电脑名才帮得上忙。
    private var showsDevice: Bool { Set(candidates.compactMap(\.deviceName)).count > 1 }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if onSelect == nil, query.isEmpty { noneRow }
                if !recent.isEmpty {
                    sectionTitle(tr("project.recent"))
                    ForEach(recent) { row($0) }
                    sectionTitle(tr("personal.allProjects"))
                }
                ForEach(matches) { row($0) }
                if matches.isEmpty {
                    Text(tr("project.noMatch"))
                        .font(T.F.small()).foregroundStyle(T.L.fgMuted)
                        .frame(minHeight: T.touchMin)
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private func sectionTitle(_ text: String) -> some View {
        Eyebrow(text: text).padding(.top, T.Sp.s4).padding(.bottom, T.Sp.s1)
    }

    private var noneRow: some View {
        VStack(spacing: 0) {
            Button {
                Task {
                    choosing = true
                    do {
                        try await model.selectDefaultProject()
                        if let onBrowse { onBrowse() } else { onClose() }
                    }
                    catch { self.error = error.localizedDescription }
                    choosing = false
                }
            } label: {
                rowLabel(title: tr("project.none"), subtitle: tr("project.noneHint"),
                         icon: "tray", current: model.selectedProject?.isDefault == true)
            }
            .buttonStyle(.plain)
            .disabled(captureInProgress)
            .accessibilityIdentifier("projectPicker.none")
            Hairline()
        }
    }

    private func row(_ p: RelayProject) -> some View {
        VStack(spacing: 0) {
            Button {
                Task {
                    choosing = true
                    do {
                        if let onSelect { try await onSelect(p) }
                        else { await model.selectProject(p) }
                        RecentProjects.use(p.id)
                        onClose()
                    } catch { self.error = error.localizedDescription }
                    choosing = false
                }
            } label: {
                rowLabel(title: p.name, subtitle: showsDevice ? p.deviceName : nil,
                         icon: nil, current: onSelect == nil && model.selectedProject?.id == p.id)
            }
            .buttonStyle(.plain)
            .disabled(captureInProgress)
            .accessibilityIdentifier("projectPicker.project.\(p.key)")
            Hairline()
        }
    }

    private func rowLabel(title: String, subtitle: String?, icon: String?, current: Bool) -> some View {
        HStack(spacing: T.Sp.s3) {
            if let icon {
                Image(systemName: icon).foregroundStyle(T.L.accent).frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(T.F.body()).foregroundStyle(T.L.fg).lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(T.F.nano()).foregroundStyle(T.L.fgFaint).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if current {
                Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(T.L.accent)
            }
        }
        .frame(minHeight: T.touchMin)
        .contentShape(Rectangle())
    }

    private var loadingRow: some View {
        HStack(spacing: T.Sp.s2) {
            ProgressView().controlSize(.small)
            Text(tr("project.loading")).font(T.F.small()).foregroundStyle(T.L.fgMuted)
        }
        .frame(minHeight: T.touchMin)
    }

    private func errorBlock(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: T.Sp.s3) {
            Text(msg).font(T.F.small()).foregroundStyle(T.S.failed)
            Button(tr("project.retry")) { Task { await load() } }
                .font(T.F.small())
                .foregroundStyle(T.L.accent)
        }
        .frame(minHeight: T.touchMin, alignment: .leading)
    }

    private var emptyBlock: some View {
        VStack(alignment: .leading, spacing: T.Sp.s2) {
            Text(tr("project.emptyTitle"))
                .font(T.F.body())
                .foregroundStyle(T.L.fg)
            Text(tr("project.emptyHint"))
                .font(T.F.micro())
                .foregroundStyle(T.L.fgFaint)
            Button(tr("project.reload")) { Task { await load() } }
                .font(T.F.small())
                .foregroundStyle(T.L.accent)
                .padding(.top, T.Sp.s2)
        }
        .frame(minHeight: T.touchMin, alignment: .leading)
    }

    private func load() async {
        loading = true; error = nil
#if DEBUG
        // 截图模式不打网络请求：等超时会截到一屏「正在读取」
        if Shot.isOn {
            projects = Shot.projects
            loading = false
            return
        }
#endif
        do {
            let loaded = try await model.workspaceFiles().projects()
            projects = projectFilter.map { filter in loaded.filter(filter) } ?? loaded
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

/// 最近用过的项目（只存 id，最多 5 个）。项目条目不是凭据，存 UserDefaults 即可。
enum RecentProjects {
    private static let key = "recentProjectIDs"
    static var ids: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func use(_ id: String) {
        UserDefaults.standard.set(Array(([id] + ids.filter { $0 != id }).prefix(5)), forKey: key)
    }
}
