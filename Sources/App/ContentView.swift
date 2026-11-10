import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var controller: SandboxVMController
    @State private var isDropTargeted = false
    @State private var showConsole = false

    var body: some View {
        VStack(spacing: 0) {
            topSecurityToolbar
            Divider()
            HSplitView {
                sidebarView
                    .frame(minWidth: 320, idealWidth: 350, maxWidth: 420)
                mainVMViewport
                    .frame(minWidth: 760, maxWidth: .infinity, maxHeight: .infinity)
            }
            if showConsole {
                Divider()
                consoleDrawer
                    .frame(height: 140)
            }
            bottomStatusBar
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleFileDrop(providers: providers)
        }
    }

    // MARK: - Top Security Toolbar

    private var topSecurityToolbar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(LinearGradient(
                            colors: [.blue, .indigo],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 32, height: 32)
                    Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("SafeSpace 轻量级隔离虚拟机")
                        .font(.system(size: 14, weight: .bold))
                    HStack(spacing: 5) {
                        Circle()
                            .fill(statusDotColor)
                            .frame(width: 7, height: 7)
                        Text(controller.state.label)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text("· 宿主机单向只读保护")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.green)
                    }
                }
            }

            Spacer()

            // Network Isolation Switch
            Button {
                controller.setNetworkIsolation(enabled: !controller.networkEnabled)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: controller.networkEnabled ? "network" : "wifi.slash")
                        .foregroundColor(controller.networkEnabled ? .orange : .green)
                    Text(controller.networkEnabled ? "当前：允许联网" : "当前：断网隔离")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(controller.networkEnabled ? Color.orange.opacity(0.14) : Color.green.opacity(0.14))
                )
            }
            .buttonStyle(.plain)
            .help("点击一键切换虚拟机断网隔离 / 允许联网")

            // Ephemeral Mode Toggle
            Toggle(isOn: $controller.ephemeralOnQuit) {
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .foregroundColor(controller.ephemeralOnQuit ? .red : .secondary)
                    Text("关闭即销毁")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .toggleStyle(.checkbox)
            .help("勾选后，退出软件时自动清空所有上传文件与沙盒磁盘")

            Divider()
                .frame(height: 20)

            // Reset VM Only
            Button {
                controller.resetSandbox(clearUploadedFiles: false)
            } label: {
                Label("重置系统", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .help("保留左侧已上传文件，但将虚拟机系统盘瞬间恢复至初始无毒状态")

            // Full Destroy & Reset
            Button(role: .destructive) {
                controller.resetSandbox(clearUploadedFiles: true)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "trash.slash.fill")
                    Text("一键销毁重置沙盒")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.red.opacity(0.88)))
                .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .help("清空所有上传文件，并将虚拟机瞬间还原为全新纯净状态")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var statusDotColor: Color {
        switch controller.state {
        case .running: return .green
        case .booting, .resetting: return .orange
        case .stopped: return .gray
        case .error: return .red
        }
    }

    // MARK: - Left Sidebar (File Upload & List)

    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Upload Drop Zone
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            isDropTargeted ? Color.blue : Color.secondary.opacity(0.35),
                            style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(isDropTargeted ? Color.blue.opacity(0.10) : Color(NSColor.controlBackgroundColor).opacity(0.6))
                        )

                    VStack(spacing: 8) {
                        Image(systemName: "arrow.up.doc.on.clipboard")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundColor(.blue)
                        Text("拖拽文件到此处，或点击下方按钮上传")
                            .font(.system(size: 12, weight: .semibold))
                        Text("支持 PDF / PPT / Word / Excel / 压缩包 / 脚本软件")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        HStack(spacing: 8) {
                            Button {
                                controller.promptAndUploadFiles()
                            } label: {
                                Label("选择文件上传", systemImage: "plus.circle.fill")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                controller.createDemoSampleFiles()
                            } label: {
                                Label("生成测试文件", systemImage: "sparkles")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.top, 2)
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 10)
                }
                .frame(height: 145)

                HStack {
                    Toggle("上传后立即在虚拟机中打开", isOn: $controller.autoOpenOnUpload)
                        .font(.system(size: 11))
                        .toggleStyle(.checkbox)
                    Spacer()
                    Text("共 \(controller.uploadedFiles.count) 个文件")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)

            Divider()

            // Uploaded Files Header
            HStack {
                Text("已上传至沙盒的文件")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                if !controller.uploadedFiles.isEmpty {
                    Button("清空列表") {
                        controller.clearAllFiles()
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.link)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            // File List
            if controller.uploadedFiles.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("暂未上传任何文件")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                    Text("上传的文件会自动出现在右侧虚拟机桌面上，\n点击“打开”即可在隔离环境中安全预览。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.8))
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(controller.uploadedFiles) { item in
                            fileRowCard(item)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
            }

            Divider()

            // Quick VM Desktop Controls
            HStack(spacing: 8) {
                Button {
                    controller.sendGuestCommand("__SAFESPACE_CMD__:FILEMANAGER")
                } label: {
                    Label("沙盒文件管理器", systemImage: "folder.fill")
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    controller.sendGuestCommand("__SAFESPACE_CMD__:TERMINAL")
                } label: {
                    Label("沙盒终端", systemImage: "terminal.fill")
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        }
    }

    private func fileRowCard(_ item: SandboxFileItem) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(item.category.badgeColor.opacity(0.15))
                    .frame(width: 38, height: 38)
                Image(systemName: item.category.iconName)
                    .font(.system(size: 18))
                    .foregroundColor(item.category.badgeColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Text(item.category.rawValue)
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(item.category.badgeColor.opacity(0.18)))
                        .foregroundColor(item.category.badgeColor)

                    Text(item.formattedSize)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)

                    Text("SHA:\(item.shortHash)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.8))
                }
            }

            Spacer(minLength: 4)

            Button {
                controller.openFileInVM(item)
            } label: {
                Text("打开")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .help("在右侧隔离虚拟机桌面中打开此文件")

            Button {
                controller.deleteFile(item)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("从沙盒移除此文件")
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.05), radius: 1, x: 0, y: 1)
        )
    }

    // MARK: - Right Main VM Viewport

    private var mainVMViewport: some View {
        ZStack {
            Color.black

            if let vm = controller.virtualMachine, controller.state.isRunning {
                VMDisplayView(virtualMachine: vm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 14) {
                    ProgressView()
                        .scaleEffect(1.2)
                        .tint(.white)
                    Text(controller.state.label)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    Text("基于 Apple Virtualization.framework 极速隔离内核")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)

                    if controller.isProvisioningImage {
                        Text(controller.provisionProgressText)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.cyan)
                            .padding(.top, 4)
                    } else if case .error = controller.state {
                        HStack(spacing: 12) {
                            Button {
                                controller.downloadAndInitializeBaseImage()
                            } label: {
                                Label("一键下载并初始化沙盒系统镜像 (69MB)", systemImage: "arrow.down.circle.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)

                            Button("重新尝试启动") {
                                controller.startSandbox(freshClone: true)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.top, 6)
                    }
                }
            }
        }
    }

    // MARK: - Bottom Console & Status Bar

    private var consoleDrawer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("沙盒内核与安全审计日志", systemImage: "text.alignleft")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button("清空日志") {
                    controller.consoleLogs.removeAll()
                }
                .font(.system(size: 10))
                .buttonStyle(.link)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(controller.consoleLogs.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.primary.opacity(0.85))
                                .id(idx)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                }
                .onChange(of: controller.consoleLogs.count) {
                    if let last = controller.consoleLogs.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    private var bottomStatusBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(.blue)
                .font(.system(size: 12))
            Text(controller.statusBanner)
                .font(.system(size: 11))
                .lineLimit(1)

            Spacer()

            Button {
                withAnimation {
                    showConsole.toggle()
                }
            } label: {
                Label(showConsole ? "隐藏安全日志" : "查看安全日志", systemImage: "terminal")
                    .font(.system(size: 11))
            }
            .buttonStyle(.link)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Drag and Drop Handler

    private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        var collectedURLs: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        DispatchQueue.main.async {
                            collectedURLs.append(url)
                        }
                    } else if let url = item as? URL {
                        DispatchQueue.main.async {
                            collectedURLs.append(url)
                        }
                    }
                }
            }
        }

        group.notify(queue: .main) {
            if !collectedURLs.isEmpty {
                controller.uploadFiles(urls: collectedURLs)
            }
        }
        return true
    }
}
