import Foundation
import Virtualization

@main
final class Provisioner: NSObject, VZVirtualMachineDelegate {
    private var vm: VZVirtualMachine!
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private var loggedIn = false
    private var buffer = ""

    static func main() {
        let app = Provisioner()
        app.start()
        RunLoop.main.run()
    }

    func start() {
        let rootPath = FileManager.default.currentDirectoryPath
        let baseDir = URL(fileURLWithPath: rootPath).appendingPathComponent("VMAssets")
        let kernelURL = baseDir.appendingPathComponent("boot/Image")
        let initrdURL = baseDir.appendingPathComponent("boot/initramfs-virt")
        let isoURL = baseDir.appendingPathComponent("alpine-virt-aarch64.iso")
        let diskURL = baseDir.appendingPathComponent("base-rootfs.img")

        let config = VZVirtualMachineConfiguration()
        config.cpuCount = max(2, min(4, ProcessInfo.processInfo.processorCount))
        config.memorySize = 2 * 1024 * 1024 * 1024

        let bootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
        bootLoader.initialRamdiskURL = initrdURL
        bootLoader.commandLine = "console=hvc0 random.trust_cpu=on modules=loop,squashfs,sd-mod,usb-storage,virtio_blk,virtio_net,virtiofs"
        config.bootLoader = bootLoader

        do {
            let mainAttachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
            let mainBlock = VZVirtioBlockDeviceConfiguration(attachment: mainAttachment)

            let isoAttachment = try VZDiskImageStorageDeviceAttachment(url: isoURL, readOnly: true)
            let isoBlock = VZVirtioBlockDeviceConfiguration(attachment: isoAttachment)

            config.storageDevices = [mainBlock, isoBlock]
        } catch {
            print("Storage error: \(error)")
            exit(1)
        }

        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [net]

        let fs = VZVirtioFileSystemDeviceConfiguration(tag: "setup_share")
        fs.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: baseDir, readOnly: false))
        config.directorySharingDevices = [fs]

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
            print("Validation error: \(error)")
            exit(1)
        }

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            FileHandle.standardOutput.write(data)
            DispatchQueue.main.async {
                self?.handleSerialOutput(str)
            }
        }

        vm = VZVirtualMachine(configuration: config)
        vm.delegate = self

        print("Starting Provisioning VM...")
        vm.start { result in
            switch result {
            case .success:
                print("Provisioning VM booted successfully.")
            case .failure(let error):
                print("Failed to start VM: \(error)")
                exit(1)
            }
        }
    }

    private func handleSerialOutput(_ text: String) {
        buffer += text
        if !loggedIn && buffer.contains("login:") {
            loggedIn = true
            print("\n[Host] Sending login & setup command...")
            sendCommand("root\n")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.sendCommand("modprobe virtiofs && mkdir -p /mnt/setup_share && mount -t virtiofs setup_share /mnt/setup_share && sh /mnt/setup_share/setup-guest.sh\n")
            }
        }
        if buffer.contains("__PROVISION_COMPLETE__") {
            print("\n[Host] Provisioning completed! Stopping VM...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                exit(0)
            }
        }
    }

    private func sendCommand(_ cmd: String) {
        if let data = cmd.data(using: .utf8) {
            inputPipe.fileHandleForWriting.write(data)
        }
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        print("\n[Host] Guest stopped cleanly.")
        exit(0)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        print("\n[Host] Guest stopped with error: \(error)")
        exit(1)
    }
}
