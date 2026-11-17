import SwiftUI

struct DownloadCenterView: View {
    @EnvironmentObject private var manager: DownloadManager
    @State private var selection = 0
    @State private var shareURL: URL?
    @State private var taskToDelete: DownloadTask?

    private var tasks: [DownloadTask] {
        manager.tasks.sorted { $0.createdAt > $1.createdAt }.filter { task in
            switch selection {
            case 1: return task.state.isActive || task.state == .paused
            case 2: return task.state == .completed
            case 3: return task.state == .failed || task.state == .cancelled
            default: return true
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("状态", selection: $selection) {
                    Text("全部").tag(0)
                    Text("进行中").tag(1)
                    Text("已完成").tag(2)
                    Text("失败").tag(3)
                }
                .pickerStyle(.segmented)
                ForEach(tasks) { task in
                    DownloadTaskRow(
                        task: task,
                        pause: { manager.pause(id: task.id) },
                        resume: { manager.resume(id: task.id) },
                        cancel: { taskToDelete = task },
                        retry: { manager.retry(id: task.id) },
                        open: {
                            if let url = manager.fileURL(for: task.id) { shareURL = url }
                        }
                    )
                }
            }
            .overlay {
                if tasks.isEmpty {
                    EmptyStateView(
                        title: selection == 0 ? "暂无下载任务" : "此状态下没有任务",
                        systemImage: "arrow.down.circle",
                        description: "在作品详情的资源页选择直链或网盘资源即可开始。"
                    )
                }
            }
            .navigationTitle("下载中心")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("清除已完成与失败任务", role: .destructive) {
                            manager.clearFinished()
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(item: Binding<URL?>(get: { shareURL }, set: { shareURL = $0 })) { url in
                ActivityView(items: [url])
            }
            .alert("移除下载任务？", isPresented: Binding(get: { taskToDelete != nil }, set: { if !$0 { taskToDelete = nil } })) {
                Button("取消", role: .cancel) {}
                Button("移除并删除文件", role: .destructive) {
                    if let taskToDelete { manager.remove(id: taskToDelete.id) }
                    taskToDelete = nil
                }
            } message: {
                Text("会同时删除该任务对应的未完成或已下载文件。")
            }
        }
    }
}

private struct DownloadTaskRow: View {
    let task: DownloadTask
    let pause: () -> Void
    let resume: () -> Void
    let cancel: () -> Void
    let retry: () -> Void
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.fileName).font(.headline).lineLimit(2)
                    Text(task.resource.sourceName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                statusLabel
            }
            if task.state == .downloading || task.state == .paused || task.state == .extracting {
                ProgressView(value: task.progress ?? 0) {
                    HStack {
                        Text(task.progress.map { "\(Int($0 * 100))%" } ?? "未知大小")
                        Spacer()
                        if task.totalBytes > 0 {
                            Text("\(GalFormatters.bytes(task.downloadedBytes)) / \(GalFormatters.bytes(task.totalBytes))")
                        }
                    }
                    .font(.caption)
                }
                if task.state == .downloading {
                    HStack {
                        Text(GalFormatters.speed(task.bytesPerSecond))
                        if let remaining = task.remainingSeconds { Text("剩余 \(GalFormatters.duration(remaining))") }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            if let error = task.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                switch task.state {
                case .downloading, .resolving, .waiting:
                    Button("暂停", action: pause)
                case .paused:
                    Button("继续", action: resume).buttonStyle(.borderedProminent)
                case .failed:
                    Button("重试", action: retry).buttonStyle(.borderedProminent)
                case .completed:
                    Button("打开 / 分享", action: open).buttonStyle(.borderedProminent)
                case .extracting:
                    EmptyView()
                case .cancelled:
                    Button("重新下载", action: retry)
                }
                if task.state != .completed {
                    Spacer()
                    Button("移除", role: .destructive, action: cancel)
                } else {
                    Spacer()
                    Button("删除", role: .destructive, action: cancel)
                }
            }
            .font(.subheadline)
        }
        .padding(.vertical, 6)
    }

    private var statusLabel: some View {
        let text: String
        switch task.state {
        case .resolving: text = "解析中"
        case .waiting: text = "等待中"
        case .downloading: text = "下载中"
        case .paused: text = "已暂停"
        case .extracting: text = "解压中"
        case .completed: text = "已完成"
        case .failed: text = "失败"
        case .cancelled: text = "已取消"
        }
        return Text(text)
            .font(.caption2)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.1), in: Capsule())
    }
}
