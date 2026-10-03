import SwiftUI

struct QuarantineView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedFiles: Set<UUID> = []
    @State private var showingRestoreConfirmation = false
    @State private var showingDeleteConfirmation = false
    @State private var fileToRestore: QuarantinedFile?
    @State private var fileToDelete: QuarantinedFile?
    @State private var searchText = ""
    @State private var actionError: QuarantineActionError?

    var filteredFiles: [QuarantinedFile] {
        if searchText.isEmpty {
            return appState.quarantinedFiles
        }
        return appState.quarantinedFiles.filter {
            $0.originalPath.localizedCaseInsensitiveContains(searchText) ||
            $0.threatName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            if let error = appState.quarantineLoadError {
                VStack(spacing: 12) {
                    Label("Quarantine Couldn’t Be Loaded", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry") { appState.loadQuarantinedFiles() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("quarantine-load-error")
            } else if appState.quarantinedFiles.isEmpty {
                EmptyQuarantineView()
            } else {
                Text("Quarantined files are isolated. You can leave them here; restore a file only if you trust it and believe the detection was a mistake.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                QuarantineToolbar(
                    searchText: $searchText,
                    selectedCount: selectedFiles.count,
                    onRestoreSelected: { showingRestoreConfirmation = true },
                    onDeleteSelected: { showingDeleteConfirmation = true }
                )
                .disabled(appState.isManagingQuarantine)

                if appState.isManagingQuarantine {
                    ProgressView("Updating quarantine…")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if filteredFiles.isEmpty {
                    VStack(spacing: 12) {
                        Text("No matching files").font(.headline)
                        Text("Try another filename or threat name.").foregroundStyle(.secondary)
                        Button("Clear Search") { searchText = "" }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    QuarantineList(
                        files: filteredFiles,
                        selectedFiles: Binding(
                            get: { selectedFiles },
                            set: { if !appState.isManagingQuarantine { selectedFiles = $0 } }
                        ),
                        onRestore: { file in
                            guard !appState.isManagingQuarantine else { return }
                            fileToRestore = file
                            showingRestoreConfirmation = true
                        },
                        onDelete: { file in
                            guard !appState.isManagingQuarantine else { return }
                            fileToDelete = file
                            showingDeleteConfirmation = true
                        }
                    )
                    .disabled(appState.isManagingQuarantine)
                }
            }
        }
        .padding(.horizontal, GlassDesign.contentPadding)
        .padding(.bottom, 16)
        .accessibilityIdentifier("quarantine-content")
        .alert("Restore File?", isPresented: $showingRestoreConfirmation) {
            Button("Cancel", role: .cancel) {
                fileToRestore = nil
            }
            Button("Restore", role: .destructive) {
                guard !appState.isManagingQuarantine else { return }
                let files = filesTargetedForRestore
                fileToRestore = nil
                appState.isManagingQuarantine = true
                Task {
                    await restore(files)
                    appState.isManagingQuarantine = false
                }
            }
        } message: {
            if let file = fileToRestore {
                Text("Are you sure you want to restore \"\(file.originalFileName)\" to its original location? This file was quarantined because it contained: \(file.threatName)")
            } else {
                Text("Are you sure you want to restore \(selectedFiles.count) file(s)? These files were quarantined because they may contain threats.")
            }
        }
        .alert("Delete Permanently?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                fileToDelete = nil
            }
            Button("Delete", role: .destructive) {
                guard !appState.isManagingQuarantine else { return }
                let files = filesTargetedForDeletion
                fileToDelete = nil
                appState.isManagingQuarantine = true
                delete(files)
                appState.isManagingQuarantine = false
            }
        } message: {
            if let file = fileToDelete {
                Text("Are you sure you want to permanently delete \"\(file.originalFileName)\"? This action cannot be undone.")
            } else {
                Text("Are you sure you want to permanently delete \(selectedFiles.count) file(s)? This action cannot be undone.")
            }
        }
        .alert(item: $actionError) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var filesTargetedForRestore: [QuarantinedFile] {
        if let fileToRestore {
            return [fileToRestore]
        }
        return appState.quarantinedFiles.filter { selectedFiles.contains($0.id) }
    }

    private var filesTargetedForDeletion: [QuarantinedFile] {
        if let fileToDelete {
            return [fileToDelete]
        }
        return appState.quarantinedFiles.filter { selectedFiles.contains($0.id) }
    }

    private func restore(_ files: [QuarantinedFile]) async {
        var successfulIDs = Set<UUID>()
        var failedFiles: [QuarantinedFile] = []

        for file in files {
            do {
                try await appState.restoreFromQuarantine(file)
                successfulIDs.insert(file.id)
            } catch {
                failedFiles.append(file)
            }
        }

        selectedFiles.subtract(successfulIDs)
        if !failedFiles.isEmpty {
            actionError = QuarantineActionError(
                title: "Restore Incomplete",
                message: failureMessage(
                    failedFiles: failedFiles,
                    totalCount: files.count,
                    action: "restored"
                )
            )
        }
    }

    private func delete(_ files: [QuarantinedFile]) {
        var successfulIDs = Set<UUID>()
        var failedFiles: [QuarantinedFile] = []

        for file in files {
            do {
                try appState.deleteFromQuarantine(file)
                successfulIDs.insert(file.id)
            } catch {
                failedFiles.append(file)
            }
        }

        selectedFiles.subtract(successfulIDs)
        if !failedFiles.isEmpty {
            actionError = QuarantineActionError(
                title: "Deletion Incomplete",
                message: failureMessage(
                    failedFiles: failedFiles,
                    totalCount: files.count,
                    action: "deleted"
                )
            )
        }
    }

    private func failureMessage(
        failedFiles: [QuarantinedFile],
        totalCount: Int,
        action: String
    ) -> String {
        let names = failedFiles.prefix(3).map(\.originalFileName).joined(separator: ", ")
        let remainingCount = failedFiles.count - min(failedFiles.count, 3)
        let remaining = remainingCount > 0 ? " and \(remainingCount) more" : ""
        let selectionNote = totalCount > 1 ? " Only successful items were removed from the selection." : ""
        return "\(failedFiles.count) of \(totalCount) file(s) could not be \(action): \(names)\(remaining). Review the listed item(s) before retrying.\(selectionNote)"
    }
}

private struct QuarantineActionError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct EmptyQuarantineView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 64))
                .foregroundColor(.green)

            Text("Quarantine is Empty")
                .font(.title2)
                .fontWeight(.semibold)

            Text("No threats have been quarantined.")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct QuarantineToolbar: View {
    @Binding var searchText: String
    let selectedCount: Int
    let onRestoreSelected: () -> Void
    let onDeleteSelected: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                searchField
                Spacer()
                selectionActions
            }
            VStack(alignment: .leading, spacing: 12) {
                searchField
                selectionActions
            }
        }
        .padding(14)
        .adaptiveGlassSurface(cornerRadius: GlassDesign.compactCornerRadius)
    }

    private var searchField: some View {
        TextField("Search quarantine...", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 140, idealWidth: 200, maxWidth: .infinity)
            .accessibilityLabel("Search quarantined files")
    }

    private var selectionActions: some View {
        HStack {
            if selectedCount > 0 {
                Text("\(selectedCount) selected")
                    .foregroundColor(.secondary)

                Button("Restore Selected") {
                    onRestoreSelected()
                }
                .buttonStyle(.bordered)

                Button("Delete Selected") {
                    onDeleteSelected()
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
            }
        }
    }
}

struct QuarantineList: View {
    let files: [QuarantinedFile]
    @Binding var selectedFiles: Set<UUID>
    let onRestore: (QuarantinedFile) -> Void
    let onDelete: (QuarantinedFile) -> Void

    var body: some View {
        List(files, selection: $selectedFiles) { file in
            QuarantinedFileRow(
                file: file,
                isSelected: selectedFiles.contains(file.id),
                onRestore: { onRestore(file) },
                onDelete: { onDelete(file) }
            )
            .tag(file.id)
        }
        .scrollContentBackground(.hidden)
    }
}

struct QuarantinedFileRow: View {
    let file: QuarantinedFile
    let isSelected: Bool
    let onRestore: () -> Void
    let onDelete: () -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)

                VStack(alignment: .leading) {
                    Text(file.originalFileName)
                        .fontWeight(.medium)
                    Text(file.threatName)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                Spacer()

                Text(file.formattedSize)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(file.formattedDate)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(isExpanded ? "Hide" : "Show") details for \(file.originalFileName)")
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Original Path:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(file.originalPath)
                            .font(.caption)
                            .textSelection(.enabled)
                    }

                    DisclosureGroup("Technical details") {
                        Text(file.sha256Hash)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .accessibilityLabel("SHA256: \(file.sha256Hash)")
                        Button("Copy SHA256") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(file.sha256Hash, forType: .string)
                        }
                        .buttonStyle(.bordered)
                    }

                    HStack(spacing: 12) {
                        Button("Restore", action: onRestore)
                            .buttonStyle(.bordered)

                        Button("Delete", action: onDelete)
                            .buttonStyle(.bordered)
                            .foregroundColor(.red)
                    }
                    .padding(.top, 4)
                }
                .padding(.leading, 24)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    QuarantineView()
        .environmentObject(AppState())
        .frame(width: 800, height: 600)
}
