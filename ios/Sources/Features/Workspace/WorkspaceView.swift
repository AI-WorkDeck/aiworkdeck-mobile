import SwiftUI
import QuickLook
import SafariServices

/// One navigation hierarchy survives compact/regular transitions. Browsing never
/// changes the destination of an in-flight capture.
struct WorkspaceView: View {
    @Environment(AppModel.self) private var model
    @State private var projects: [RelayProject] = []
    @State private var selected: RelayProject?
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?
    @State private var client: (any ProjectFilesServing)?
    @State private var route: Route?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private enum Route: String, Identifiable {
        case capture, library, queue, settings, probe, dueDiligence
        var id: String { rawValue }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selected) {
                if loading { ProgressView().accessibilityIdentifier("workspace.loading") }
                if let error {
                    Text(error).foregroundStyle(T.S.failed)
                    Button(tr("project.retry")) { Task { await load() } }
                }
                if AccountRegion.current == .cn {
                    Button { route = .dueDiligence } label: {
                        Label(tr("dd.title"), systemImage: "checklist")
                    }
                    .accessibilityIdentifier("workspace.dueDiligence")
                }
                ForEach(projects.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { project in
                    NavigationLink(value: project) {
                        VStack(alignment: .leading) {
                            Text(project.name)
                            if let device = project.deviceName {
                                Text(device).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(project.identityCaption).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("workspace.project.\(project.key)")
                }
                if !loading, error == nil, projects.isEmpty {
                    Text(tr("project.emptyHint")).foregroundStyle(.secondary)
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: tr("workspace.searchProjects"))
            .navigationTitle(tr("workspace.title"))
            // The large title disappears when iPhone split navigation collapses
            // back to portrait, shifting the list. Keep one title style.
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await load() }
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        if !AudioRecorderService.shared.isRecording && !AudioRecorderService.shared.isBusy { model.captureWithoutProject() }
                        route = .capture
                    } label: { Label(tr("workspace.quickCapture"), systemImage: "mic") }
                    .accessibilityIdentifier("workspace.quickCapture")
                    Spacer()
                    Button { route = .library } label: { Label(tr("library.open"), systemImage: "photo.on.rectangle") }
                        .accessibilityIdentifier("workspace.library")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { route = .settings } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel(tr("home.settings"))
                }
            }
        } detail: {
            if let selected, let client {
                ProjectContentsView(project: selected, client: client)
                    .environment(model)
                    .navigationTitle(selected.name)
                    .toolbar {
                        ToolbarItemGroup(placement: .primaryAction) {
                            Button { openCapture(selected) } label: {
                                Label(tr(AudioRecorderService.shared.isRecording ? "workspace.resumeRecording" : "workspace.capture"), systemImage: "camera")
                            }
                            .accessibilityIdentifier("workspace.capture")
                            Button { route = .queue } label: { Label(tr("queue.title"), systemImage: "arrow.up.circle") }
                            #if DEBUG
                            Menu {
                                Button(tr("dual.prototype.title")) { route = .probe }
                            } label: { Image(systemName: "wrench.and.screwdriver") }
                            #endif
                        }
                    }
            } else {
                ContentUnavailableView(tr("workspace.choose"), systemImage: "folder", description: Text(tr("workspace.unassignedHint")))
            }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(T.L.accent)
        .task {
            client = model.workspaceFiles()
            await load()
        }
        .fullScreenCover(item: $route) { route in
            switch route {
            case .capture:
                CaptureFlowView(onClose: { self.route = nil }).environment(model)
            case .library:
                LibraryView(onClose: { self.route = nil }).environment(model)
            case .queue:
                QueueView(onClose: { self.route = nil }).environment(model)
            case .settings:
                SettingsView(onClose: { self.route = nil }).environment(model)
            case .dueDiligence:
                DdClientPortalView()
                    .ignoresSafeArea()
            case .probe:
                #if DEBUG
                DualCapturePrototypeView(project: selected, onClose: { self.route = nil })
                #else
                EmptyView()
                #endif
            }
        }
    }

    private func load() async {
        guard let client else { return }
        loading = true; error = nil
        do {
            let loaded = try await client.projects()
            try Task.checkCancellation()
            // A restored capture destination remains usable offline, even when
            // the desktop no longer advertises it in the current directory.
            projects = loaded
            if let current = model.selectedProject, !projects.contains(where: { $0.matches(current) }) {
                projects.append(current)
            }
            if selected == nil { selected = model.selectedProject }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
            if projects.isEmpty, let current = model.selectedProject {
                projects = [current]; selected = current
            }
        }
        loading = false
    }

    private func openCapture(_ project: RelayProject) {
        Task {
            if !AudioRecorderService.shared.isRecording && !AudioRecorderService.shared.isBusy {
                await model.selectProject(project)
            }
            route = .capture
        }
    }
}

private struct ProjectContentsView: View {
    @Environment(AppModel.self) private var model
    let project: RelayProject
    let client: any ProjectFilesServing
    @State private var tab = "files"
    @State private var query = ""
    @State private var listing: ProjectFileListing?
    @State private var loadedProjectID: String?
    @State private var loading = false
    @State private var error: String?
    @State private var generation = UUID()
    @State private var scrollID: String?
    @State private var download: DownloadSelection?
    @State private var locationID: String?
    @State private var directory = ""

    private var storageProject: RelayProject {
        let preferred = project.locations?.first(where: { $0.kind == "desktop" && $0.online == true })?.alias ?? project.legacyID
        guard let location = project.locations?.first(where: { $0.alias == (locationID ?? preferred) }) else { return project }
        return RelayProject(deviceId: location.deviceId, deviceName: location.deviceName, key: location.key,
                            name: project.name, projectUid: project.projectUid, locations: project.locations)
    }
    private var storageKey: String { project.id + ":" + storageProject.legacyID }

    private struct DownloadSelection: Identifiable {
        let file: RemoteProjectFile
        let project: RelayProject
        var id: String { project.id + ":" + file.rowID }
    }

    private var directoryListing: ProjectFileDirectory {
        ProjectFileDirectory(files: loadedProjectID == storageKey ? (listing?.files ?? []) : [])
    }
    private var visibleFiles: [RemoteProjectFile] { directoryListing.files(in: directory, matching: query) }
    private var visibleFolders: [ProjectFileDirectory.Folder] { query.isEmpty ? directoryListing.folders(in: directory) : [] }

    var body: some View {
        VStack(spacing: 0) {
            Picker(tr("workspace.fileDetails"), selection: $tab) {
                Text(tr("workspace.files")).tag("files")
                Text(tr("workspace.records")).tag("records")
            }
            .pickerStyle(.segmented)
            .padding()
            if tab == "records" {
                LibraryView(onClose: { tab = "files" }, fixedProject: project, embedded: true)
                    .environment(model)
                    .preferredColorScheme(.dark)
            } else {
                files
            }
        }
        .task(id: storageKey) {
            if loadedProjectID != storageKey {
                query = ""; scrollID = nil; directory = ""
                await load()
            }
        }
        .sheet(item: $download) { target in
            FileDownloadView(project: target.project, file: target.file, client: client)
        }
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let locations = project.locations, locations.count > 1 {
                Picker(tr("workspace.storageLocation"), selection: Binding(
                    get: { storageProject.legacyID }, set: { locationID = $0 }
                )) {
                    ForEach(locations, id: \.alias) { location in
                        Text(location.kind == "cloud" ? tr("project.cloud") : (location.deviceName ?? location.deviceId))
                            .tag(location.alias)
                    }
                }
                .padding(.horizontal)
                .accessibilityIdentifier("workspace.storageLocation")
            }
            TextField(tr("workspace.searchFiles"), text: $query)
                .textFieldStyle(.roundedBorder).padding(.horizontal)
                .accessibilityIdentifier("workspace.fileSearch")
            if query.isEmpty {
                HStack {
                    Button(tr("workspace.folderRoot")) { directory = ""; scrollID = nil }
                        .accessibilityIdentifier("workspace.folderRoot")
                    if !directory.isEmpty {
                        Text("/ " + directory).lineLimit(2).font(.caption)
                        Spacer()
                        Button {
                            directory = directory.split(separator: "/").dropLast().joined(separator: "/")
                            scrollID = nil
                        } label: { Image(systemName: "arrow.up") }
                        .accessibilityLabel(tr("workspace.folderUp"))
                        .accessibilityIdentifier("workspace.folderUp")
                    }
                }.padding()
            }
            if listing?.truncated == true, loadedProjectID == storageKey {
                Text(tr("workspace.limit")).font(.caption).foregroundStyle(.secondary).padding()
            }
            if loading { ProgressView(tr("workspace.loading")).padding() }
            if let error {
                Text(error).foregroundStyle(T.S.failed).padding()
                Button(tr("project.retry")) { Task { await load() } }.padding(.horizontal)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleFolders) { folder in
                        Button { directory = folder.path; scrollID = nil } label: {
                            HStack {
                                Image(systemName: "folder")
                                Text(folder.name)
                                Spacer()
                                Image(systemName: "chevron.right")
                            }.padding().frame(maxWidth: .infinity, minHeight: T.touchMin, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("workspace.folder.\(folder.path)")
                        Divider()
                    }
                    ForEach(visibleFiles, id: \.rowID) { file in
                        Button { download = DownloadSelection(file: file, project: storageProject) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "doc")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(file.name).foregroundStyle(.primary)
                                    Text(file.path).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding().frame(maxWidth: .infinity, minHeight: T.touchMin, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(file.rowID)
                        .accessibilityIdentifier("workspace.file.\(file.id)")
                        Divider()
                    }
                    if !loading, error == nil, visibleFiles.isEmpty, visibleFolders.isEmpty {
                        ContentUnavailableView(tr(query.isEmpty ? "workspace.noFiles" : "workspace.noMatches"), systemImage: "doc", description: Text(tr(storageProject.isCloud ? "workspace.cloudHint" : "workspace.desktopHint")))
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $scrollID)
            .refreshable { await load() }
        }
    }

    private func load() async {
        let request = UUID()
        let target = storageProject
        let targetKey = storageKey
        generation = request
        loading = true; error = nil
        if loadedProjectID != targetKey { listing = nil }
        do {
            let result = try await client.files(in: target)
            try Task.checkCancellation()
            guard generation == request else { return }
            listing = result; loadedProjectID = targetKey
        } catch is CancellationError {
            guard generation == request else { return }
        } catch {
            guard generation == request else { return }
            self.error = error.localizedDescription
        }
        loading = false
    }
}

private struct FileDownloadView: View {
    @Environment(\.dismiss) private var dismiss
    let project: RelayProject
    let file: RemoteProjectFile
    let client: any ProjectFilesServing
    @State private var pull: ProjectFilePull?
    @State private var quote: ProjectFileQuote?
    @State private var url: URL?
    @State private var busy = false
    @State private var approved = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let url {
                    FileQuickLook(url: url)
                        .accessibilityIdentifier("workspace.preview")
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(file.path).font(.subheadline).foregroundStyle(.secondary)
                        if !file.supportsPreview { Text(tr("workspace.unsupportedPreview")).accessibilityIdentifier("workspace.unsupported") }
                        if busy { ProgressView(tr((project.isCloud || file.source == "backup" || file.source == "cloud") ? "workspace.cloudDownload" : "workspace.downloading")) }
                        if let error { Text(error).foregroundStyle(T.S.failed) }
                        if let quote, !approved {
                            Text((project.isCloud || file.source == "backup" || file.source == "cloud") ? tr("workspace.cloudHint") : tr("workspace.quote", ["name": file.name, "credits": String(quote.credits)]))
                            Button(tr((project.isCloud || file.source == "backup" || file.source == "cloud") ? "workspace.cloudOpen" : "workspace.download")) { approved = true; Task { await download() } }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("workspace.confirmDownload")
                                .disabled(busy)
                        } else if approved, !busy {
                            Text(tr("workspace.downloadRetryHint"))
                            Button(tr("workspace.retryDownload")) { Task { await download() } }
                                .accessibilityIdentifier("workspace.retryDownload")
                        } else if !busy, error != nil {
                            Button(tr("project.retry")) { Task { await loadQuote() } }
                        }
                        Spacer()
                    }.padding()
                }
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("common.close")) { dismiss() }.disabled(busy)
                }
            }
        }
        .interactiveDismissDisabled(busy)
        .task { await loadQuote() }
        .onDisappear {
            if let url { Task { await client.removePreview(url) } }
        }
    }

    private func loadQuote() async {
        guard file.supportsPreview else { return }
        busy = true; error = nil
        do { quote = try await client.quote(for: file, in: project) }
        catch { self.error = error.localizedDescription }
        busy = false
    }

    private func download() async {
        guard file.supportsPreview else { return }
        busy = true; error = nil
        do {
            if pull == nil { pull = try await client.preparePull(project: project, file: file) }
            guard let pull else { return }
            url = try await client.download(pull)
        } catch let error as ProjectFileTerminalError {
            self.error = error.localizedDescription
            pull = nil; approved = false; quote = nil
        } catch { self.error = error.localizedDescription }
        busy = false
    }
}

private struct FileQuickLook: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let view = QLPreviewController()
        view.dataSource = context.coordinator
        return view
    }
    func updateUIViewController(_ view: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
}

/// An invitation opens within the full app and cannot overwrite SessionStore or the selected capture project.
private struct DdClientPortalView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: URL(string: ContractCapabilities.ddClientPortalURL)!)
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
