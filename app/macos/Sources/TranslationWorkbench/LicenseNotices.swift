import AppKit
import WorkbenchCore

@MainActor
enum LicenseNotices {
    private static var window: NSWindow?
    private static let repositoryURL = "https://github.com/yqia03/crosscript"
    private static let releaseTag = "v0.1.0-preview.5"

    static func show() {
        let language = AppLanguage.current
        guard let resources = Bundle.main.resourceURL else { return }
        let legal = resources.appendingPathComponent("Legal", isDirectory: true)
        let files = ["SOURCE_AND_BUILD.txt", "THIRD_PARTY_NOTICES.txt", "LICENSE.txt"]
        do {
            let documents = try files.map { name in
                "\n\n=== \(name) ===\n\n" + (try String(contentsOf: legal.appendingPathComponent(name), encoding: .utf8))
            }
            let introduction = language.text(
                "本项目自有代码采用 GNU AGPL v3（仅 v3，AGPL-3.0-only），允许按许可商用、修改和再分发，不提供担保。第三方保留各自的版权和许可。下方可查看完整项目许可、第三方归属与源码／构建材料说明；更多原始组件声明可通过同一菜单的“显示组件声明文件”打开。",
                "Crosscript's own code uses GNU AGPL v3 only (AGPL-3.0-only). Commercial use, modification and redistribution are permitted under the license, without warranty. Third parties retain their copyrights and licenses. Full project terms, third-party attribution and source/build information appear below. Use “Show component notice files” in the same menu for additional original notices."
            )
            let panel: NSWindow
            let text: NSTextView
            if let existing = window,
               let scroll = existing.contentView as? NSScrollView,
               let existingText = scroll.documentView as? NSTextView {
                panel = existing
                text = existingText
            } else {
                panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                                 styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                 backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.minSize = NSSize(width: 480, height: 320)
                let scroll = NSScrollView(frame: panel.contentView?.bounds ?? .zero)
                scroll.hasVerticalScroller = true
                scroll.autoresizingMask = [.width, .height]
                text = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
                text.isEditable = false
                text.isSelectable = true
                text.isHorizontallyResizable = false
                text.isVerticallyResizable = true
                text.autoresizingMask = [.width]
                text.textContainer?.widthTracksTextView = true
                text.textContainerInset = NSSize(width: 14, height: 14)
                text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                scroll.documentView = text
                panel.contentView = scroll
                panel.center()
                window = panel
            }
            text.textStorage?.setAttributedString(noticeText(introduction: introduction, documents: documents, language: language))
            text.scrollRangeToVisible(NSRange(location: 0, length: 0))
            panel.title = language.text("许可证与第三方声明", "License and third-party notices")
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            let alert = NSAlert()
            alert.messageText = language.text("此构建缺少许可材料", "License materials are missing from this build")
            alert.informativeText = language.text(
                "无法读取随包许可文本。请使用完整的应用包；此构建尚不满足发布检查。",
                "The bundled license texts could not be read. Use the complete app bundle; this build does not meet the release checks."
            )
            alert.runModal()
        }
    }

    private static func noticeText(introduction: String, documents: [String], language: AppLanguage) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.textColor,
        ]
        let availability = language.text(
            "源码与发行入口（发布后生效）\n以下是本版本选定的公开地址。源码、构建和第三方材料与本版本共同发布；若尚未发布，链接可能显示未找到。查看下方完整许可不需要联网。",
            "Source and release links (available after publication)\nThese are the selected public destinations for this version. Source, build and third-party materials are provided together when this version is published; before publication, links may return not found. The full license texts below are available offline."
        )
        let result = NSMutableAttributedString(string: introduction + "\n\n" + availability + "\n\n", attributes: attributes)
        let links = [
            (language.text("项目仓库", "Project repository"), repositoryURL),
            (language.text("本版本源码", "Source for this version"), "\(repositoryURL)/tree/\(releaseTag)"),
            (language.text("自有代码许可（AGPL-3.0-only）", "Own-code license (AGPL-3.0-only)"), "\(repositoryURL)/blob/\(releaseTag)/LICENSE"),
            (language.text("第三方声明", "Third-party notices"), "\(repositoryURL)/blob/\(releaseTag)/THIRD_PARTY_NOTICES.md"),
            (language.text("源码、构建与第三方材料（版本发布页）", "Source, build and third-party materials (version release)"), "\(repositoryURL)/releases/tag/\(releaseTag)"),
        ]
        for (label, address) in links {
            result.append(NSAttributedString(string: label + "\n", attributes: attributes))
            var linkAttributes = attributes
            linkAttributes[.link] = URL(string: address)
            linkAttributes[.foregroundColor] = NSColor.linkColor
            linkAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            result.append(NSAttributedString(string: address, attributes: linkAttributes))
            result.append(NSAttributedString(string: "\n\n", attributes: attributes))
        }
        result.append(NSAttributedString(string: documents.joined(), attributes: attributes))
        return result
    }

    static func revealComponentNotices() {
        guard let resources = Bundle.main.resourceURL else { return }
        let notices = resources.appendingPathComponent("PDF/Notices", isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([notices])
    }
}
