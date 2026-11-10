import Foundation
import SwiftUI

enum FileCategory: String, CaseIterable {
    case pdf = "PDF 文档"
    case presentation = "PPT 演示"
    case office = "Office 文档"
    case image = "图片媒体"
    case archive = "压缩归档"
    case executable = "软件/可执行"
    case textOrCode = "文本/代码"
    case other = "其他文件"

    var iconName: String {
        switch self {
        case .pdf: return "doc.richtext.fill"
        case .presentation: return "play.rectangle.on.rectangle.fill"
        case .office: return "doc.text.fill"
        case .image: return "photo.fill"
        case .archive: return "archivebox.fill"
        case .executable: return "terminal.fill"
        case .textOrCode: return "chevron.left.forwardslash.chevron.right"
        case .other: return "doc.fill"
        }
    }

    var badgeColor: Color {
        switch self {
        case .pdf: return .red
        case .presentation: return .orange
        case .office: return .blue
        case .image: return .purple
        case .archive: return .brown
        case .executable: return .pink
        case .textOrCode: return .teal
        case .other: return .gray
        }
    }

    static func categorize(filename: String) -> FileCategory {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf":
            return .pdf
        case "ppt", "pptx", "odp":
            return .presentation
        case "doc", "docx", "odt", "xls", "xlsx", "ods", "rtf":
            return .office
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "svg", "ico":
            return .image
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar":
            return .archive
        case "dmg", "pkg", "app", "exe", "msi", "sh", "run", "bin", "command", "appimage":
            return .executable
        case "txt", "md", "json", "xml", "yaml", "yml", "csv", "log", "py", "js", "ts", "c", "cpp", "h", "html", "css", "swift", "go", "rs":
            return .textOrCode
        default:
            return .other
        }
    }
}

struct SandboxFileItem: Identifiable, Equatable {
    let id: UUID
    let name: String
    let hostURL: URL
    let sizeBytes: Int64
    let sha256: String
    let category: FileCategory
    let uploadedAt: Date

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var shortHash: String {
        String(sha256.prefix(12))
    }
}

enum VMRuntimeState: Equatable {
    case stopped
    case booting
    case running
    case resetting
    case error(String)

    var label: String {
        switch self {
        case .stopped: return "已停止"
        case .booting: return "正在启动沙盒内核..."
        case .running: return "安全隔离运行中"
        case .resetting: return "正在销毁并重置沙盒..."
        case .error(let msg): return "异常: \(msg)"
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
