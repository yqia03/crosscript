import SwiftUI
import WorkbenchCore

/// Local rendering: no remote scripts, image loads or HTML execution from imported documents.
struct MarkdownReadingView: View {
    let text: String
    var body: some View {
        let document = MarkdownDocument(source: text)
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(document.blocks) { block in
                    let value = document.render(block, translated: false).trimmingCharacters(in: .newlines)
                    switch block.kind {
                    case .separator: EmptyView()
                    case .code:
                        ScrollView(.horizontal) {
                            Text(codeContents(value)).font(.system(.body, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(10).background(.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    case .formula, .reference:
                        Text(value).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                    case .heading:
                        Text(inline(value.replacingOccurrences(of: #"^\s*#{1,6}\s+"#, with: "", options: .regularExpression)))
                            .font(.title3.bold())
                    case .table: ScrollView(.horizontal) { table(value) }
                    default: Text(inline(value))
                    }
                }
            }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(4)
        }.accessibilityIdentifier("markdown-reading")
    }
    private func codeContents(_ value: String) -> String {
        var lines = value.components(separatedBy: "\n")
        if let first = lines.first, first.range(of: #"^[ >\t]*(?:[-+*] )?(?:`{3,}|~{3,})"#, options: .regularExpression) != nil {
            lines.removeFirst()
            if let last = lines.last, last.range(of: #"^[ >\t]*(?:`{3,}|~{3,})\s*$"#, options: .regularExpression) != nil { lines.removeLast() }
        }
        return lines.joined(separator: "\n")
    }
    private func inline(_ value: String) -> AttributedString {
        (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value)
    }
    private func table(_ value: String) -> some View {
        let lines = value.split(separator: "\n").map(String.init)
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                if index != 1 {
                    GridRow {
                        ForEach(Array(cells(line).enumerated()), id: \.offset) { _, cell in
                            Text(inline(cell)).fontWeight(index == 0 ? .semibold : .regular)
                        }
                    }
                    Divider()
                }
            }
        }.padding(8).background(.black.opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
    }
    private func cells(_ line: String) -> [String] {
        var cells: [String] = []; var cell = ""; var escaped = false; var code = false
        for character in line {
            if escaped { cell.append(character); escaped = false; continue }
            if character == "\\" { cell.append(character); escaped = true; continue }
            if character == "`" { code.toggle() }
            if character == "|", !code { cells.append(cell); cell = "" } else { cell.append(character) }
        }
        cells.append(cell)
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
