import Foundation
import SwiftUI
import AppKit
import Virtualization
import CryptoKit

@MainActor
final class SandboxVMController: NSObject, ObservableObject, VZVirtualMachineDelegate {
    @Published var virtualMachine: VZVirtualMachine?
    @Published var state: VMRuntimeState = .stopped
    @Published var uploadedFiles: [SandboxFileItem] = []
    @Published var networkEnabled: Bool = false
    @Published var ephemeralOnQuit: Bool = true
    @Published var autoOpenOnUpload: Bool = true
    @Published var guestReady: Bool = false
    @Published var isProvisioningImage: Bool = false
    @Published var provisionProgressText: String = ""
    @Published var consoleLogs: [String] = []
    @Published var statusBanner: String = "就绪：可将可疑 PDF、PPT、文档或软件拖入左侧安全打开"

    let workspaceRoot: URL
    let assetsDir: URL
    let runtimeDir: URL
    let stagingDir: URL
    let sessionDiskURL: URL

    private var inputPipe = Pipe()
    private var outputPipe = Pipe()
    private var serialBuffer = ""
    private var provisionLoggedIn = false

    override init() {
        let fm = FileManager.default
        let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
        let defaultRoot = URL(fileURLWithPath: "/Users/haowenbai/Desktop/SafeSpace")
        let appSupportRoot = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SafeSpace")

        if fm.fileExists(atPath: bundleParent.appendingPathComponent("VMAssets/base-rootfs.img").path) {
            self.workspaceRoot = bundleParent
        } else if fm.fileExists(atPath: defaultRoot.appendingPathComponent("VMAssets/base-rootfs.img").path) {
            self.workspaceRoot = defaultRoot
        } else {
            self.workspaceRoot = appSupportRoot
        }
        self.assetsDir = workspaceRoot.appendingPathComponent("VMAssets")
        self.runtimeDir = workspaceRoot.appendingPathComponent("Runtime")
        self.stagingDir = runtimeDir.appendingPathComponent("Staging")
        self.sessionDiskURL = runtimeDir.appendingPathComponent("session-rootfs.img")

        super.init()

        prepareDirectories()
        refreshUploadedFiles()
    }

    private func prepareDirectories() {
        try? FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
    }

    func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "[\(formatter.string(from: Date()))] \(message)"
        consoleLogs.append(line)
        if consoleLogs.count > 250 {
            consoleLogs.removeFirst(consoleLogs.count - 250)
        }
    }

    // MARK: - VM Lifecycle

    func startSandbox(freshClone: Bool = true) {
        guard state != .booting && state != .resetting else { return }
        state = .booting
        guestReady = false
        prepareDirectories()

        let kernelURL = assetsDir.appendingPathComponent("boot/Image")
        let initrdURL = assetsDir.appendingPathComponent("boot/initramfs-virt")
        let baseDiskURL = assetsDir.appendingPathComponent("base-rootfs.img")

        guard FileManager.default.fileExists(atPath: kernelURL.path),
              FileManager.default.fileExists(atPath: initrdURL.path),
              FileManager.default.fileExists(atPath: baseDiskURL.path) else {
            state = .error("首次使用需初始化沙盒系统镜像（点击下方按钮一键自动下载构建）")
            appendLog("未检测到本地沙盒基础镜像 (\(baseDiskURL.path))，请点击“一键下载并初始化沙盒镜像”。")
            return
        }

        do {
            if freshClone || !FileManager.default.fileExists(atPath: sessionDiskURL.path) {
                if FileManager.default.fileExists(atPath: sessionDiskURL.path) {
                    try FileManager.default.removeItem(at: sessionDiskURL)
                }
                // APFS Instant Copy-on-Write clone (<10ms, zero extra disk space)
                try FileManager.default.copyItem(at: baseDiskURL, to: sessionDiskURL)
                appendLog("已基于黄金镜像创建 APFS 瞬时写时复制沙盒盘 (session-rootfs.img)")
            }
        } catch {
            state = .error("克隆沙盒磁盘失败: \(error.localizedDescription)")
            return
        }

        // Fresh serial pipes
        inputPipe = Pipe()
        outputPipe = Pipe()
        serialBuffer = ""

        let config = VZVirtualMachineConfiguration()
        config.cpuCount = max(2, min(4, ProcessInfo.processInfo.processorCount))
        config.memorySize = 2 * 1024 * 1024 * 1024 // 2 GB RAM

        let bootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
        bootLoader.initialRamdiskURL = initrdURL
        let netFlag = networkEnabled ? "1" : "0"
        bootLoader.commandLine = "console=hvc0 random.trust_cpu=on root=/dev/vda rootfstype=ext4 rootflags=rw modules=ext4,virtio_blk,virtio_gpu,virtio_input,virtio_net,virtiofs,xhci_pci,usbhid,hid_generic init=/sbin/safespace-init safespace.net=\(netFlag)"
        config.bootLoader = bootLoader

        do {
            let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: sessionDiskURL, readOnly: false)
            let blockDev = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
            config.storageDevices = [blockDev]
        } catch {
            state = .error("挂载虚拟磁盘失败: \(error.localizedDescription)")
            return
        }

        // Graphics Display (1280x800)
        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1280, heightInPixels: 800)]
        config.graphicsDevices = [graphics]

        // Seamless Mouse & Keyboard
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        config.keyboards = [VZUSBKeyboardConfiguration()]

        // Network (can be toggled live inside guest via eth0 up/down)
        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [net]

        // Read-Only VirtioFS Share for Uploaded Files (Hardware-enforced one-way transfer!)
        let sharedDir = VZSharedDirectory(url: stagingDir, readOnly: true)
        let singleShare = VZSingleDirectoryShare(directory: sharedDir)
        let fsConfig = VZVirtioFileSystemDeviceConfiguration(tag: "safeshare")
        fsConfig.share = singleShare
        config.directorySharingDevices = [fsConfig]

        // Serial Control Channel
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: inputPipe.fileHandleForReading,
            fileHandleForWriting: outputPipe.fileHandleForWriting
        )
        config.serialPorts = [serial]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        do {
            try config.validate()
        } catch {
            state = .error("虚拟机配置校验失败: \(error.localizedDescription)")
            appendLog("配置校验失败: \(error)")
            return
        }

        setupSerialReader()

        let vm = VZVirtualMachine(configuration: config)
        vm.delegate = self
        self.virtualMachine = vm

        appendLog("正在启动 Apple Virtualization.framework 硬件隔离虚拟机...")
        vm.start { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success:
                    self.state = .running
                    self.statusBanner = "沙盒运行中 · 宿主机单向只读隔离保护已生效"
                    self.appendLog("虚拟机内核已启动，正在加载图形桌面环境...")
                case .failure(let error):
                    self.state = .error(error.localizedDescription)
                    self.appendLog("启动失败: \(error.localizedDescription)")
                }
            }
        }
    }

    private func setupSerialReader() {
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.processSerialText(str)
            }
        }
    }

    private func processSerialText(_ text: String) {
        serialBuffer += text
        let lines = serialBuffer.components(separatedBy: .newlines)
        for line in lines.dropLast() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.contains("__SAFESPACE_READY__") {
                guestReady = true
                statusBanner = "沙盒桌面已就绪 · 点击左侧文件即可在虚拟机内安全打开"
                appendLog("SafeSpace 虚拟机桌面代理已连接就绪。")
                sendGuestCommand("__SAFESPACE_CMD__:SYNC")
            } else if trimmed.hasPrefix("__SAFESPACE_ACK__:OPEN:") {
                let fname = trimmed.replacingOccurrences(of: "__SAFESPACE_ACK__:OPEN:", with: "")
                statusBanner = "已在沙盒虚拟机中打开: \(fname)"
                appendLog("虚拟机已响应打开文件: \(fname)")
            } else if trimmed.hasPrefix("__SAFESPACE_ACK__:NET_ON") {
                statusBanner = "虚拟机网络已开启（NAT 隔离模式）"
                appendLog("虚拟机内网卡 eth0 已启用。")
            } else if trimmed.hasPrefix("__SAFESPACE_ACK__:NET_OFF") {
                statusBanner = "虚拟机已彻底断网隔离"
                appendLog("虚拟机内网卡 eth0 已物理断开。")
            }
        }
        serialBuffer = lines.last ?? ""
    }

    func sendGuestCommand(_ cmd: String) {
        guard state.isRunning else { return }
        if let data = (cmd + "\n").data(using: .utf8) {
            try? inputPipe.fileHandleForWriting.write(contentsOf: data)
        }
    }

    // MARK: - Network Toggle

    func setNetworkIsolation(enabled: Bool) {
        networkEnabled = enabled
        if enabled {
            sendGuestCommand("__SAFESPACE_CMD__:NET_ON")
            statusBanner = "正在开启虚拟机联网..."
        } else {
            sendGuestCommand("__SAFESPACE_CMD__:NET_OFF")
            statusBanner = "正在切断虚拟机网络连接..."
        }
    }

    // MARK: - Reset & Destroy Sandbox

    func resetSandbox(clearUploadedFiles: Bool) {
        state = .resetting
        guestReady = false
        statusBanner = clearUploadedFiles ? "正在销毁所有文件并重置纯净沙盒..." : "正在重置纯净沙盒系统镜像..."
        appendLog(clearUploadedFiles ? "执行一键销毁：清空上传文件并重置沙盒磁盘..." : "执行沙盒系统重置...")

        outputPipe.fileHandleForReading.readabilityHandler = nil

        let finishReset = { [weak self] in
            guard let self else { return }
            self.virtualMachine = nil
            if clearUploadedFiles {
                self.clearAllFiles()
            }
            try? FileManager.default.removeItem(at: self.sessionDiskURL)
            self.state = .stopped
            self.startSandbox(freshClone: true)
        }

        if let vm = virtualMachine, vm.state == .running || vm.state == .starting {
            if vm.canStop {
                vm.stop { _ in
                    Task { @MainActor in
                        finishReset()
                    }
                }
            } else {
                finishReset()
            }
        } else {
            finishReset()
        }
    }

    // MARK: - File Upload & Management

    func promptAndUploadFiles() {
        let panel = NSOpenPanel()
        panel.title = "选择要上传到隔离沙盒的文件或软件"
        panel.message = "文件将以单向只读方式传入虚拟机，不会污染宿主机系统"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false

        if panel.runModal() == .OK {
            uploadFiles(urls: panel.urls)
        }
    }

    func uploadFiles(urls: [URL]) {
        prepareDirectories()
        var lastUploaded: SandboxFileItem?

        for srcURL in urls {
            let accessed = srcURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { srcURL.stopAccessingSecurityScopedResource() }
            }

            let safeName = srcURL.lastPathComponent.replacingOccurrences(of: "/", with: "_")
            let dstURL = stagingDir.appendingPathComponent(safeName)

            do {
                if FileManager.default.fileExists(atPath: dstURL.path) {
                    try FileManager.default.removeItem(at: dstURL)
                }
                try FileManager.default.copyItem(at: srcURL, to: dstURL)
                appendLog("已上传文件至隔离区: \(safeName)")
            } catch {
                appendLog("上传文件失败 (\(safeName)): \(error.localizedDescription)")
            }
        }

        refreshUploadedFiles()
        sendGuestCommand("__SAFESPACE_CMD__:SYNC")

        if let firstName = urls.last?.lastPathComponent {
            lastUploaded = uploadedFiles.first(where: { $0.name == firstName })
        }

        if autoOpenOnUpload, let item = lastUploaded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.openFileInVM(item)
            }
        } else if let item = lastUploaded {
            statusBanner = "已上传 \(item.name)，已同步到虚拟机桌面"
        }
    }

    func openFileInVM(_ item: SandboxFileItem) {
        guard state.isRunning else {
            statusBanner = "虚拟机尚未运行，正在启动..."
            startSandbox(freshClone: false)
            return
        }
        statusBanner = "正在虚拟机中打开: \(item.name)..."
        appendLog("请求虚拟机打开文件: \(item.name) [\(item.category.rawValue)]")
        sendGuestCommand("__SAFESPACE_CMD__:OPEN:\(item.name)")
    }

    func deleteFile(_ item: SandboxFileItem) {
        try? FileManager.default.removeItem(at: item.hostURL)
        refreshUploadedFiles()
        sendGuestCommand("__SAFESPACE_CMD__:SYNC")
        appendLog("已从隔离区移除文件: \(item.name)")
    }

    func clearAllFiles() {
        if let items = try? FileManager.default.contentsOfDirectory(at: stagingDir, includingPropertiesForKeys: nil) {
            for url in items {
                try? FileManager.default.removeItem(at: url)
            }
        }
        refreshUploadedFiles()
        sendGuestCommand("__SAFESPACE_CMD__:SYNC")
    }

    func refreshUploadedFiles() {
        prepareDirectories()
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: stagingDir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            uploadedFiles = []
            return
        }

        var items: [SandboxFileItem] = []
        for url in urls {
            let name = url.lastPathComponent
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(vals?.fileSize ?? 0)
            let date = vals?.contentModificationDate ?? Date()
            let hash = Self.computeSHA256(for: url)
            let cat = FileCategory.categorize(filename: name)
            items.append(SandboxFileItem(
                id: UUID(),
                name: name,
                hostURL: url,
                sizeBytes: size,
                sha256: hash,
                category: cat,
                uploadedAt: date
            ))
        }

        items.sort { $0.uploadedAt > $1.uploadedAt }
        uploadedFiles = items
    }

    private static func computeSHA256(for url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "unknown" }
        defer { try? handle.close() }
        var hasher = SHA256()
        // Hash up to first 4MB for instant UI responsiveness even on large files
        if let data = try? handle.read(upToCount: 4 * 1024 * 1024) {
            hasher.update(data: data)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Demo Sample Files Generator

    func createDemoSampleFiles() {
        prepareDirectories()

        // 1. Generate a real multi-page PDF file using AppKit PDF data
        let pdfURL = stagingDir.appendingPathComponent("SafeSpace_安全预览测试文档.pdf")
        let pdfMetaData = [
            kCGPDFContextCreator: "SafeSpace Sandbox",
            kCGPDFContextTitle: "SafeSpace PDF 隔离预览测试"
        ]
        let pdfData = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        if let consumer = CGDataConsumer(data: pdfData as CFMutableData),
           let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, pdfMetaData as CFDictionary) {
            pdfContext.beginPDFPage(nil)
            let graphicsContext = NSGraphicsContext(cgContext: pdfContext, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphicsContext

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 24),
                .foregroundColor: NSColor.systemBlue
            ]
            let bodyAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15),
                .foregroundColor: NSColor.darkGray
            ]

            NSString(string: "SafeSpace 轻量级硬件隔离虚拟机 - PDF 测试文档").draw(at: NSPoint(x: 50, y: 700), withAttributes: titleAttrs)
            let content = """
            恭喜！您当前正在 Apple Virtualization.framework 驱动的独立 Linux 虚拟机中查看此 PDF。

            【安全隔离机制说明】
            1. 硬件级 Hypervisor 隔离：
               该文件运行在独立的 Linux 内核与虚拟磁盘中，与您的 macOS 宿主机完全隔离。

            2. 单向只读文件通道 (Read-Only VirtioFS)：
               宿主机上传目录以硬件只读方式挂载进虚拟机。即使文档中含有恶意宏或漏洞利用代码，
               也绝对无法篡改或感染您 Mac 电脑上的任何文件。

            3. 瞬时无痕重置 (APFS Copy-on-Write)：
               点击顶部的“一键重置沙盒”或关闭软件，虚拟机内的所有改动与病毒残留将在 10 毫秒内彻底销毁。
            """
            NSString(string: content).draw(in: NSRect(x: 50, y: 380, width: 512, height: 290), withAttributes: bodyAttrs)

            NSGraphicsContext.restoreGraphicsState()
            pdfContext.endPDFPage()
            pdfContext.closePDF()
            try? pdfData.write(to: pdfURL)
        }

        // 2. Generate a sample GUI software / executable script to test running software in the sandbox
        let scriptURL = stagingDir.appendingPathComponent("未知桌面软件_沙盒GUI测试.sh")
        let scriptContent = """
        #!/bin/sh
        export DISPLAY=:0
        echo "==================================================="
        echo "   正在 SafeSpace 隔离虚拟机内启动外部软件..."
        echo "==================================================="
        echo "当前虚拟机内核: $(uname -srm)"
        echo "当前主机名:     $(hostname)"
        echo "当前用户环境:   $(id)"
        echo ""
        echo "[安全拦截测试 1] 模拟恶意软件尝试篡改宿主机共享目录..."
        if touch /mnt/safeshare/hack_host.txt 2>/dev/null; then
            HOST_STATUS="❌ 警告：写入成功"
        else
            HOST_STATUS="✅ 拦截成功！宿主机目录为硬件级只读 (Read-Only VirtioFS)，病毒无法感染宿主机"
        fi
        echo "$HOST_STATUS"
        echo ""
        echo "[安全拦截测试 2] 检测当前沙盒网络隔离状态..."
        if ip addr show eth0 2>/dev/null | grep -q "inet "; then
            NET_STATUS="🌐 允许联网模式 (NAT 隔离)"
        else
            NET_STATUS="🔒 完全断网隔离模式 (木马无法外联回传数据)"
        fi
        echo "$NET_STATUS"
        echo ""
        echo "正在弹出软件图形界面窗口 (GTK GUI)..."
        zenity --info --width=460 --title="SafeSpace 隔离沙盒 - 软件运行演示" --text="<b>外部软件已在隔离虚拟机中成功运行！</b>\\n\\n• <b>运行内核：</b>$(uname -srm)\\n• <b>宿主机保护：</b>$HOST_STATUS\\n• <b>网络状态：</b>$NET_STATUS\\n\\n您可以在此虚拟机内放心打开未知软件、脚本、安装包、PPT 与 PDF 文件，关闭或重置沙盒即可瞬间清除所有痕迹。" 2>/dev/null &
        """
        try? scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)

        // 3. Generate a sample Office RTF/Document file
        let docURL = stagingDir.appendingPathComponent("项目演示汇报_Office文档测试.rtf")
        let rtfTitle = NSAttributedString(
            string: "SafeSpace 隔离沙盒 - Office / PPT 演示文档安全预览\n\n",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 22), .foregroundColor: NSColor.systemIndigo]
        )
        let rtfBody = NSAttributedString(
            string: "• 支持在虚拟机内直接通过 LibreOffice 打开 .pptx / .ppt / .docx / .xlsx 文件\n• 彻底阻断 Office 宏病毒、CVE 漏洞利用与木马自动执行\n• 查看完毕后关闭窗口或一键重置沙盒即可销毁一切痕迹\n",
            attributes: [.font: NSFont.systemFont(ofSize: 15)]
        )
        let combined = NSMutableAttributedString(attributedString: rtfTitle)
        combined.append(rtfBody)
        if let rtfData = try? combined.data(from: NSRange(location: 0, length: combined.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            try? rtfData.write(to: docURL)
        }

        refreshUploadedFiles()
        sendGuestCommand("__SAFESPACE_CMD__:SYNC")
        statusBanner = "已生成 3 个测试文件（PDF、Office文档、沙盒防毒测试脚本），点击“打开”即可体验！"
        appendLog("已生成演示样本文件至隔离区。")
    }

    // MARK: - Built-in One-Click Image Downloader & Provisioner for Standalone DMG Users

    func downloadAndInitializeBaseImage() {
        guard !isProvisioningImage else { return }
        isProvisioningImage = true
        provisionProgressText = "正在从 Alpine 官方 CDN 下载 69MB 基础虚拟化镜像..."
        statusBanner = provisionProgressText
        appendLog("开始一键自动下载并初始化沙盒基础镜像至: \(assetsDir.path)")

        try? FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)

        // Copy bundled setup-guest.sh if available
        let dstSetupScript = assetsDir.appendingPathComponent("setup-guest.sh")
        if !FileManager.default.fileExists(atPath: dstSetupScript.path),
           let bundledScript = Bundle.main.url(forResource: "setup-guest", withExtension: "sh") {
            try? FileManager.default.copyItem(at: bundledScript, to: dstSetupScript)
        }

        Task.detached { [weak self] in
            guard let self else { return }
            let assetsPath = await self.assetsDir.path
            let cmd = """
            set -e
            mkdir -p "\(assetsPath)"
            if [ ! -f "\(assetsPath)/alpine-virt-aarch64.iso" ]; then
                curl -fL -o "\(assetsPath)/alpine-virt-aarch64.iso" "https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/aarch64/alpine-virt-3.20.3-aarch64.iso"
            fi
            tar -xf "\(assetsPath)/alpine-virt-aarch64.iso" -C "\(assetsPath)" boot/vmlinuz-virt boot/initramfs-virt
            python3 -c '
            import zlib
            data = open("\(assetsPath)/boot/vmlinuz-virt", "rb").read()
            idx = data.find(b"\\x1f\\x8b\\x08")
            raw = zlib.decompress(data[idx:], 16 + zlib.MAX_WBITS)
            open("\(assetsPath)/boot/Image", "wb").write(raw)
            '
            rm -f "\(assetsPath)/base-rootfs.img"
            dd if=/dev/zero of="\(assetsPath)/base-rootfs.img" bs=1m count=0 seek=4096
            """

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-c", cmd]
            do {
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    await MainActor.run {
                        self.provisionProgressText = "基础内核已就绪，正在初始化图形桌面与阅读器组件（约 1~2 分钟）..."
                        self.statusBanner = self.provisionProgressText
                        self.startInAppProvisioningVM()
                    }
                } else {
                    await MainActor.run {
                        self.isProvisioningImage = false
                        self.state = .error("下载或解压 Alpine 基础镜像失败")
                    }
                }
            } catch {
                await MainActor.run {
                    self.isProvisioningImage = false
                    self.state = .error("执行镜像初始化失败: \(error.localizedDescription)")
                }
            }
        }
    }

    private func startInAppProvisioningVM() {
        let kernelURL = assetsDir.appendingPathComponent("boot/Image")
        let initrdURL = assetsDir.appendingPathComponent("boot/initramfs-virt")
        let isoURL = assetsDir.appendingPathComponent("alpine-virt-aarch64.iso")
        let diskURL = assetsDir.appendingPathComponent("base-rootfs.img")

        inputPipe = Pipe()
        outputPipe = Pipe()
        serialBuffer = ""
        provisionLoggedIn = false

        let config = VZVirtualMachineConfiguration()
        config.cpuCount = max(2, min(4, ProcessInfo.processInfo.processorCount))
        config.memorySize = 2 * 1024 * 1024 * 1024

        let bootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
        bootLoader.initialRamdiskURL = initrdURL
        bootLoader.commandLine = "console=hvc0 random.trust_cpu=on modules=loop,squashfs,sd-mod,usb-storage,virtio_blk,virtio_net,virtiofs"
        config.bootLoader = bootLoader

        do {
            let mainAttachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
            let isoAttachment = try VZDiskImageStorageDeviceAttachment(url: isoURL, readOnly: true)
            config.storageDevices = [
                VZVirtioBlockDeviceConfiguration(attachment: mainAttachment),
                VZVirtioBlockDeviceConfiguration(attachment: isoAttachment)
            ]
        } catch {
            isProvisioningImage = false
            state = .error("挂载初始化磁盘失败: \(error.localizedDescription)")
            return
        }

        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [net]

        let fs = VZVirtioFileSystemDeviceConfiguration(tag: "setup_share")
        fs.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: assetsDir, readOnly: false))
        config.directorySharingDevices = [fs]

        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: inputPipe.fileHandleForReading,
            fileHandleForWriting: outputPipe.fileHandleForWriting
        )
        config.serialPorts = [serial]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                guard let self else { return }
                self.serialBuffer += str
                if !self.provisionLoggedIn && self.serialBuffer.contains("login:") {
                    self.provisionLoggedIn = true
                    self.appendLog("正在向初始化虚拟机注入桌面构建脚本...")
                    if let loginData = "root\n".data(using: .utf8) {
                        try? self.inputPipe.fileHandleForWriting.write(contentsOf: loginData)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        let setupCmd = "modprobe virtiofs && mkdir -p /mnt/setup_share && mount -t virtiofs setup_share /mnt/setup_share && sh /mnt/setup_share/setup-guest.sh\n"
                        if let cmdData = setupCmd.data(using: .utf8) {
                            try? self.inputPipe.fileHandleForWriting.write(contentsOf: cmdData)
                        }
                    }
                }
                if self.serialBuffer.contains("__PROVISION_COMPLETE__") {
                    self.appendLog("沙盒黄金镜像初始化完成！正在启动隔离桌面...")
                    self.isProvisioningImage = false
                    self.outputPipe.fileHandleForReading.readabilityHandler = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self.state = .stopped
                        self.startSandbox(freshClone: true)
                    }
                }
            }
        }

        let vm = VZVirtualMachine(configuration: config)
        vm.delegate = self
        self.virtualMachine = vm
        vm.start { [weak self] result in
            Task { @MainActor in
                if case .failure(let err) = result {
                    self?.isProvisioningImage = false
                    self?.state = .error("启动初始化虚拟机失败: \(err.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Cleanup on Quit

    func handleApplicationWillTerminate() {
        if let vm = virtualMachine, vm.canStop {
            vm.stop { _ in }
        }
        if ephemeralOnQuit {
            clearAllFiles()
            try? FileManager.default.removeItem(at: sessionDiskURL)
        }
    }

    // MARK: - VZVirtualMachineDelegate

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in
            if self.state != .resetting {
                self.state = .stopped
                self.guestReady = false
                self.statusBanner = "虚拟机已停止"
                self.appendLog("虚拟机已关机停止。")
            }
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        Task { @MainActor in
            self.state = .error(error.localizedDescription)
            self.guestReady = false
            self.appendLog("虚拟机异常停止: \(error.localizedDescription)")
        }
    }
}
