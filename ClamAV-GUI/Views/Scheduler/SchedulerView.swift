import SwiftUI

struct SchedulerView: View {
    @EnvironmentObject var appState: AppState
    @State private var scheduledJobs: [ScanJob] = []
    @State private var showingAddJob = false
    @State private var editingJob: ScanJob?
    @State private var actionError: SchedulerActionError?

    var body: some View {
        VStack(spacing: 0) {
            if scheduledJobs.isEmpty {
                EmptySchedulerView {
                    showingAddJob = true
                }
            } else {
                HStack {
                    Text("\(scheduledJobs.count) scheduled scan\(scheduledJobs.count == 1 ? "" : "s")")
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        showingAddJob = true
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }
                .padding()

                ScheduledJobsList(
                    jobs: $scheduledJobs,
                    onEdit: { editingJob = $0 },
                    onDelete: deleteJob,
                    onToggle: toggleJob
                )
            }
        }
        .onAppear {
            scheduledJobs = appState.scanScheduler.listScheduledScans()
        }
        .sheet(isPresented: $showingAddJob) {
            ScheduleJobEditor(job: nil) { newJob in
                addJob(newJob)
            }
        }
        .sheet(item: $editingJob) { job in
            ScheduleJobEditor(job: job) { updatedJob in
                updateJob(updatedJob)
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

    @discardableResult
    private func addJob(_ job: ScanJob) -> Bool {
        do {
            try appState.scanScheduler.createScheduledScan(job)
            scheduledJobs = appState.scanScheduler.listScheduledScans()
            return true
        } catch {
            actionError = SchedulerActionError(
                title: "Schedule Couldn’t Be Created",
                message: "\"\(job.name)\" could not be saved. Check that the app can access your user scheduling settings, then try again."
            )
            scheduledJobs = appState.scanScheduler.listScheduledScans()
            return false
        }
    }

    @discardableResult
    private func updateJob(_ job: ScanJob) -> Bool {
        do {
            try appState.scanScheduler.updateScheduledScan(job)
            scheduledJobs = appState.scanScheduler.listScheduledScans()
            return true
        } catch {
            actionError = SchedulerActionError(
                title: "Schedule Couldn’t Be Updated",
                message: "\"\(job.name)\" could not be updated. Its current state has been reloaded. Check your user scheduling settings, then try again."
            )
            scheduledJobs = appState.scanScheduler.listScheduledScans()
            return false
        }
    }

    private func deleteJob(_ job: ScanJob) {
        do {
            try appState.scanScheduler.removeScheduledScan(job)
        } catch {
            actionError = SchedulerActionError(
                title: "Schedule Couldn’t Be Deleted",
                message: "\"\(job.name)\" could not be deleted. Check your user scheduling settings, then try again."
            )
        }
        scheduledJobs = appState.scanScheduler.listScheduledScans()
    }

    private func toggleJob(_ job: ScanJob) {
        var updatedJob = job
        updatedJob.isEnabled.toggle()
        do {
            try appState.scanScheduler.updateScheduledScan(updatedJob)
        } catch {
            actionError = SchedulerActionError(
                title: "Schedule Couldn’t Be Changed",
                message: "\"\(job.name)\" could not be \(updatedJob.isEnabled ? "enabled" : "disabled"). Its current state has been reloaded."
            )
        }
        scheduledJobs = appState.scanScheduler.listScheduledScans()
    }
}

private struct SchedulerActionError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct EmptySchedulerView: View {
    let onAddJob: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 64))
                .foregroundColor(.secondary)

            Text("No Scheduled Scans")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Schedule automatic scans to keep your system protected.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Create Scheduled Scan", action: onAddJob)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct ScheduledJobsList: View {
    @Binding var jobs: [ScanJob]
    let onEdit: (ScanJob) -> Void
    let onDelete: (ScanJob) -> Void
    let onToggle: (ScanJob) -> Void

    var body: some View {
        List {
            ForEach(jobs) { job in
                ScheduledJobRow(
                    job: job,
                    onEdit: { onEdit(job) },
                    onDelete: { onDelete(job) },
                    onToggle: { onToggle(job) }
                )
            }
        }
    }
}

struct ScheduledJobRow: View {
    let job: ScanJob
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggle: () -> Void

    var body: some View {
        HStack {
            Toggle("", isOn: Binding(
                get: { job.isEnabled },
                set: { _ in onToggle() }
            ))
            .labelsHidden()

            VStack(alignment: .leading, spacing: 4) {
                Text(job.name)
                    .fontWeight(.medium)
                    .foregroundColor(job.isEnabled ? .primary : .secondary)

                HStack {
                    Image(systemName: "clock")
                        .font(.caption)
                    Text(scheduleDescription)
                        .font(.caption)
                }
                .foregroundColor(.secondary)

                HStack {
                    Image(systemName: "folder")
                        .font(.caption)
                    Text(pathsDescription)
                        .font(.caption)
                        .lineLimit(1)
                }
                .foregroundColor(.secondary)
            }

            Spacer()

            if let lastRun = job.lastRun {
                VStack(alignment: .trailing) {
                    Text("Last run:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(lastRun, style: .relative)
                        .font(.caption)
                }
            }

            Menu {
                Button("Edit", action: onEdit)
                Button("Run Now") {
                    // Trigger immediate scan
                }
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .padding(.vertical, 8)
        .opacity(job.isEnabled ? 1 : 0.6)
    }

    private var scheduleDescription: String {
        let time = formatTime(job.schedule.time)
        switch job.schedule.frequency {
        case .daily:
            return "Daily at \(time)"
        case .weekly:
            let day = dayName(job.schedule.dayOfWeek ?? 1)
            return "Every \(day) at \(time)"
        case .monthly:
            let day = job.schedule.dayOfMonth ?? 1
            return "Monthly on day \(day) at \(time)"
        }
    }

    private var pathsDescription: String {
        if job.paths.count == 1 {
            return job.paths[0]
        }
        return "\(job.paths.count) locations"
    }

    private func formatTime(_ components: DateComponents) -> String {
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        return String(format: "%d:%02d", hour, minute)
    }

    private func dayName(_ day: Int) -> String {
        let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return days[(day - 1) % 7]
    }
}

struct ScheduleJobEditor: View {
    let existingJob: ScanJob?
    let onSave: (ScanJob) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var paths: [String] = []
    @State private var frequency: ScheduleFrequency = .daily
    @State private var hour: Int = 9
    @State private var minute: Int = 0
    @State private var dayOfWeek: Int = 2
    @State private var dayOfMonth: Int = 1
    @State private var showingFolderPicker = false

    init(job: ScanJob?, onSave: @escaping (ScanJob) -> Bool) {
        self.existingJob = job
        self.onSave = onSave

        if let job = job {
            _name = State(initialValue: job.name)
            _paths = State(initialValue: job.paths)
            _frequency = State(initialValue: job.schedule.frequency)
            _hour = State(initialValue: job.schedule.time.hour ?? 9)
            _minute = State(initialValue: job.schedule.time.minute ?? 0)
            _dayOfWeek = State(initialValue: job.schedule.dayOfWeek ?? 2)
            _dayOfMonth = State(initialValue: job.schedule.dayOfMonth ?? 1)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Schedule Details") {
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)

                    Picker("Frequency", selection: $frequency) {
                        Text("Daily").tag(ScheduleFrequency.daily)
                        Text("Weekly").tag(ScheduleFrequency.weekly)
                        Text("Monthly").tag(ScheduleFrequency.monthly)
                    }

                    if frequency == .weekly {
                        Picker("Day", selection: $dayOfWeek) {
                            Text("Sunday").tag(1)
                            Text("Monday").tag(2)
                            Text("Tuesday").tag(3)
                            Text("Wednesday").tag(4)
                            Text("Thursday").tag(5)
                            Text("Friday").tag(6)
                            Text("Saturday").tag(7)
                        }
                    }

                    if frequency == .monthly {
                        Picker("Day of Month", selection: $dayOfMonth) {
                            ForEach(1...28, id: \.self) { day in
                                Text("\(day)").tag(day)
                            }
                        }
                    }

                    HStack {
                        Picker("Hour", selection: $hour) {
                            ForEach(0..<24, id: \.self) { h in
                                Text(String(format: "%02d", h)).tag(h)
                            }
                        }
                        .frame(width: 80)

                        Text(":")

                        Picker("Minute", selection: $minute) {
                            ForEach([0, 15, 30, 45], id: \.self) { m in
                                Text(String(format: "%02d", m)).tag(m)
                            }
                        }
                        .frame(width: 80)
                    }
                }

                Section("Scan Locations") {
                    ForEach(paths, id: \.self) { path in
                        HStack {
                            Image(systemName: "folder")
                            Text(path)
                            Spacer()
                            Button {
                                paths.removeAll { $0 == path }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Button("Add Folder...") {
                        showingFolderPicker = true
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button("Save") {
                    saveJob()
                }
                .keyboardShortcut(.return)
                .disabled(name.isEmpty || paths.isEmpty)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 450, height: 500)
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                paths.append(contentsOf: urls.map { $0.path })
            }
        }
    }

    private func saveJob() {
        let schedule = ScanSchedule(
            frequency: frequency,
            time: DateComponents(hour: hour, minute: minute),
            dayOfWeek: frequency == .weekly ? dayOfWeek : nil,
            dayOfMonth: frequency == .monthly ? dayOfMonth : nil
        )

        var job: ScanJob
        if let existing = existingJob {
            job = existing
            job.name = name
            job.paths = paths
            job.schedule = schedule
        } else {
            job = ScanJob(name: name, paths: paths, schedule: schedule)
        }

        if onSave(job) {
            dismiss()
        }
    }
}

#Preview {
    SchedulerView()
        .environmentObject(AppState())
        .frame(width: 800, height: 600)
}
