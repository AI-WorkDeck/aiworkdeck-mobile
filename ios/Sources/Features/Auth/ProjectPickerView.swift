import SwiftUI

/// Select a capture destination or explicitly assign an existing local item.
struct ProjectPickerView: View {
    @Environment(AppModel.self) private var model

    var onClose: () -> Void = {}
    var onSelect: ((RelayProject) async throws -> Void)? = nil
    var titleKey: String? = nil
    var hintKey: String? = nil
    var onBrowse: (() -> Void)? = nil
    @State private var choosing = false

    @State private var projects: [RelayProject] = []
    @State private var loading = true
    @State private var error: String?

    private var captureInProgress: Bool {
        onSelect == nil && (AudioRecorderService.shared.isRecording || AudioRecorderService.shared.isBusy ||
            CameraService.shared.isRecording || CameraService.shared.isStartingRecording || CameraService.shared.isCapturingPhoto)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                header
                if onSelect == nil {
                    Button {
                        model.captureWithoutProject()
                        onClose()
                    } label: { Label(tr("project.none"), systemImage: "tray") }
                    .frame(minHeight: T.touchMin)
                    .disabled(captureInProgress)
                    .accessibilityIdentifier("projectPicker.none")
                    if let onBrowse {
                        Button(action: onBrowse) { Label(tr("workspace.title"), systemImage: "folder") }
                            .frame(minHeight: T.touchMin)
                            .accessibilityIdentifier("projectPicker.browse")
                    }
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

    private var header: some View {
        VStack(alignment: .leading, spacing: T.Sp.s2) {
            Eyebrow(text: tr("project.eyebrow"))
            Text(tr(titleKey ?? (onSelect == nil ? "project.title" : "library.move")))
                .font(T.F.display())
                .foregroundStyle(T.L.fg)
            Text(hintKey.map { tr($0) } ?? (onSelect == nil ? tr("project.hint", ["date": AppModel.today]) : tr("library.moveHint")))
                .font(T.F.micro())
                .foregroundStyle(T.L.fgFaint)
                .padding(.top, T.Sp.s1)
        }
        .padding(.top, T.Sp.s3)
        .padding(.bottom, T.Sp.s3)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(projects) { p in
                    Button {
                        Task {
                            choosing = true
                            do {
                                if let onSelect { try await onSelect(p) }
                                else { await model.selectProject(p) }
                                onClose()
                            } catch { self.error = error.localizedDescription }
                            choosing = false
                        }
                    } label: {
                        HStack(spacing: T.Sp.s3) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name)
                                    .font(T.F.body())
                                    .foregroundStyle(T.L.fg)
                                    .lineLimit(1)
                                if let d = p.deviceName, !d.isEmpty {
                                    Text(d)
                                        .font(T.F.nano())
                                        .foregroundStyle(T.L.fgFaint)
                                }
                                Text(p.identityCaption)
                                    .font(T.F.nano())
                                    .foregroundStyle(T.L.fgFaint)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(T.L.fgFaint)
                        }
                        .frame(minHeight: T.touchMin)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(captureInProgress)
                    .accessibilityIdentifier("projectPicker.project.\(p.key)")
                    Hairline()
                }
            }
        }
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
            projects = try await model.workspaceFiles().projects()
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
