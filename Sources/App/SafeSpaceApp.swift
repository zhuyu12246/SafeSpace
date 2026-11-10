import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var vmController: SandboxVMController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            vmController?.handleApplicationWillTerminate()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct SafeSpaceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var controller = SandboxVMController()

    var body: some Scene {
        WindowGroup("SafeSpace - 轻量级文件隔离沙盒虚拟机") {
            ContentView(controller: controller)
                .frame(minWidth: 1120, minHeight: 740)
                .onAppear {
                    appDelegate.vmController = controller
                    if controller.state == .stopped {
                        controller.startSandbox(freshClone: true)
                    }
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("上传文件到沙盒...") {
                    controller.promptAndUploadFiles()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Divider()

                Button("一键销毁并重置沙盒") {
                    controller.resetSandbox(clearUploadedFiles: true)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}
