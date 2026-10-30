import Foundation
import Testing
@testable import WorkbenchCore

struct MarkdownDocumentTests {
    static let complex = #"""
# Heading with **bold** and [docs](https://example.test/a_(b)?x=1 "title")

First paragraph with `let x = 1` and $E = mc^2$.

Second paragraph. ![diagram](images/a.png)

- Parent
  - Child with [reference][guide]
    1. Nested item

| Name | Meaning |
| :--- | ---: |
| Alpha | $a^2$ |

````swift
// Never translate this comment
let sample = "```"
````

~~~swift
// Never translate this comment
let sample = "```"
~~~

$$
x = y + z
$$

\[a + b\]

[guide]: https://example.test/reference "Guide"
"""#

    @Test func v6ComplexSourceRoundTripsExactlyAndProtectedContentNeverEntersPayload() throws {
        let document = MarkdownDocument(source: Self.complex)
        #expect(document.source == Self.complex)
        #expect(document.translated == Self.complex)
        #expect(!document.requestPayload.contains("Never translate"))
        #expect(!document.requestPayload.contains("https://"))
        #expect(!document.requestPayload.contains("images/a.png"))
        #expect(!document.requestPayload.contains("mc^2"))
        #expect(document.leaves.contains { $0.source == "docs" })
        #expect(document.leaves.contains { $0.source == "reference" })
        #expect(document.blocks.filter { $0.kind == .code }.count == 2)
        #expect(document.blocks.filter { $0.kind == .table }.count == 1)
        try document.validate()
    }
    @Test func v6OutOfOrderIDsBindToSourceOccurrencesAndSplitsStayOwned() throws {
        var document = MarkdownDocument(source: "First paragraph.\n\nSecond paragraph.\n")
        let first = document.leaves[0].id, second = document.leaves[1].id
        try document.apply(id: second, text: "第二段。")
        try document.apply(id: first, text: "第一段。\n\n第一段新增拆分。")
        #expect(document.translated == "第一段。\n\n第一段新增拆分。\n\n第二段。\n")
        let restored = try JSONDecoder().decode(MarkdownDocument.self, from: JSONEncoder().encode(document))
        #expect(restored == document)
        #expect(restored.bilingual.range(of: "First paragraph.\n\n第一段。\n\n第一段新增拆分。") != nil)
        #expect(restored.bilingual.range(of: "Second paragraph.\n\n第二段。") != nil)
    }
    @Test func v6RepeatedCodeAndFormulaOccurrencesAreNotDeduplicated() throws {
        let source = "Before\n\n```swift\n// comment\nfoo()\n```\n\nAfter\n\n```swift\n// comment\nfoo()\n```\n\n$$x=1$$\n\n$$x=1$$\n"
        var document = MarkdownDocument(source: source)
        for leaf in document.leaves.reversed() { try document.apply(id: leaf.id, text: "译" + leaf.source) }
        #expect(document.bilingual.components(separatedBy: "foo()").count - 1 == 2)
        #expect(document.bilingual.components(separatedBy: "$$x=1$$").count - 1 == 2)
        #expect(document.translated.components(separatedBy: "// comment").count - 1 == 2)
    }
    @Test func v6ExplicitMergeRetainsBothSourcesAndIdentityThroughSave() throws {
        var document = MarkdownDocument(source: "First.\n\nSecond.\n\nThird.\n")
        for leaf in document.leaves { try document.apply(id: leaf.id, text: "译" + leaf.source) }
        let groupID = document.groups[0].id
        let blockIDs = Array(document.blocks.prefix(3).map(\.id))
        let merged = document.mergeWithNext(groupID)
        #expect(merged)
        let edited = document.editGroup(id: groupID, text: "前两段合并后的修改。\n\n编辑后又拆成两段。")
        #expect(edited)
        let reopened = try JSONDecoder().decode(MarkdownDocument.self, from: JSONEncoder().encode(document))
        #expect(reopened.groups[0].blockIDs == blockIDs)
        #expect(reopened.bilingual.contains("First.\n\nSecond.\n\n前两段合并后的修改。\n\n编辑后又拆成两段。"))
        #expect(reopened.bilingual.contains("Third.\n\n译Third."))
        try reopened.validate()
    }
    @Test func v6CodeInNestedContainersAndEscapedPipesRemainLiteral() throws {
        let source = "> - quoted\n>   ~~~js\n>   // Keep comment\n>   const x = 1\n>   ~~~\n\n| name | value |\n| --- | --- |\n| a\\|b | `x|y` |\n"
        let document = MarkdownDocument(source: source)
        #expect(document.source == source)
        #expect(!document.requestPayload.contains("Keep comment"))
        #expect(!document.requestPayload.contains("x|y"))
        #expect(document.blocks.contains { $0.kind == .code })
    }
    @Test func v6UnknownDuplicateAndStructuralInjectionFailWithoutReplacingEarlierContent() throws {
        var document = MarkdownDocument(source: "First.\n\nSecond.")
        let first = document.leaves[0].id
        try document.apply(id: first, text: "第一段。")
        #expect(throws: TextTranslationError.structure) { try document.apply(id: first, text: "重复覆盖") }
        #expect(throws: TextTranslationError.structure) { try document.apply(id: UUID(), text: "未知来源") }
        #expect(throws: TextTranslationError.structure) { try document.apply(id: document.leaves[1].id, text: "[changed](https://bad.test)") }
        #expect(document.leaves[0].translation == "第一段。")
        #expect(document.leaves[1].translation == nil)
    }
    @Test func listContinuationTranslatesWhileRelativeIndentedCodeStaysProtected() throws {
        let source = "- Parent\n    Continuation that must translate.\n\n      // Nested code stays literal\n      let x = 1\n\n1. Ordered parent\n    Ordered continuation.\n\n       // Ordered nested code\n\nOutside.\n\n    // Top-level code\n"
        let document = MarkdownDocument(source: source)
        #expect(document.source == source)
        #expect(document.leaves.contains { $0.source == "Continuation that must translate." })
        #expect(document.leaves.contains { $0.source == "Ordered continuation." })
        #expect(!document.requestPayload.contains("Nested code"))
        #expect(!document.requestPayload.contains("Ordered nested code"))
        #expect(!document.requestPayload.contains("Top-level code"))
        #expect(document.blocks.filter { $0.kind == .code }.count == 3)
    }
    @Test func nestedListsRestoreAncestorIndentationAfterReturningFromGrandchildren() {
        let plain = "- Parent\n  - Child\n    - Grandchild\n\n    Child continuation that must translate.\n\n  Parent continuation.\n\n      // Parent code remains literal\n\n  - Sibling\n    1. Ordered grandchild\n\n    Sibling continuation.\n"
        for source in [plain, plain.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")] {
            let document = MarkdownDocument(source: source)
            #expect(document.source == source)
            for expected in ["Child continuation that must translate.", "Parent continuation.", "Sibling continuation."] {
                #expect(document.leaves.contains { $0.source == expected })
            }
            #expect(!document.requestPayload.contains("Parent code remains literal"))
            #expect(document.blocks.filter { $0.kind == .code }.count == 1)
            #expect(document.blocks.filter { $0.kind == .list }.count == 8)
        }
    }
    @Test func protectedInlineFragmentsCannotSplitParagraphsInGeneratedOrEditedText() throws {
        for source in ["See [guide](https://example.test).", "See **guide**.", "See _guide_.", "See [guide][ref].\n\n[ref]: https://example.test\n", "See [guide][].\n\n[guide]: https://example.test\n"] {
            var document = MarkdownDocument(source: source)
            let id = try #require(document.leaves.first { $0.source == "guide" }?.id)
            #expect(throws: TextTranslationError.structure) { try document.apply(id: id, text: "First translation\n\nSecond translation") }
            let edited = document.editLeaf(id: id, text: "First translation\n\nSecond translation")
            #expect(!edited)
            #expect(document.translated == source || document.translated.contains("][guide]"))
            #expect(document.leaves.first { $0.id == id }?.translation == nil)
            try document.apply(id: id, text: "指南")
            #expect(document.translated.contains("指南"))
        }
        var plain = MarkdownDocument(source: "Plain paragraph.")
        try plain.apply(id: plain.leaves[0].id, text: "First translation\n\nSecond translation")
        #expect(plain.translated == "First translation\n\nSecond translation")
    }
    @Test func generatedAndEditedLeavesCannotBreakInlineDelimitersOrCreateCode() throws {
        for injection in ["Translated **broken", "_broken", "~~broken", "[new reference]", "text\n    indented code", "text\n---"] {
            var document = MarkdownDocument(source: "**Bold**")
            let id = document.leaves[0].id
            #expect(throws: TextTranslationError.structure) { try document.apply(id: id, text: injection) }
            let edited = document.editLeaf(id: id, text: injection)
            #expect(!edited)
            #expect(document.translated == "**Bold**")
        }
    }
    @Test func paragraphCannotMergeIntoListOrHeadingAndNestedItemsKeepTheirKinds() {
        let document = MarkdownDocument(source: "Paragraph.\n\n- Parent\n  - Child\n    1. Deep child\n\n# Heading\n")
        #expect(document.blocks.filter { $0.kind == .list }.count == 3)
        #expect(!document.canMerge(document.groups[0].id))
        let quoted = MarkdownDocument(source: "> - Quoted item\n>   - Nested quote item\n")
        #expect(quoted.blocks.filter { $0.kind == .list }.count == 2)
    }
    @Test func mergingProseWithFormulaAndLinksKeepsProtectedOccurrencesInsideOneTranslation() throws {
        var document = MarkdownDocument(source: "First $x=1$ with [guide](https://example.test).\n\nSecond $x=1$.\n")
        for leaf in document.leaves { try document.apply(id: leaf.id, text: "译" + leaf.source) }
        let group = document.groups[0].id
        let merged = document.mergeWithNext(group)
        #expect(merged)
        #expect(document.groups.count == 1)
        #expect(document.groups[0].editedTranslation == nil)
        #expect(document.translated.components(separatedBy: "$x=1$").count - 1 == 2)
        #expect(document.translated.contains("[译guide](https://example.test)"))
        #expect(!document.translated.contains("\n\n"))
        #expect(document.source == "First $x=1$ with [guide](https://example.test).\n\nSecond $x=1$.\n")
        try document.validate()
    }
    @Test func collapsedAndShortcutReferenceLabelsTranslateWithoutChangingTheirDestinations() throws {
        let source = "Read [Guide][] and [Guide].\n\n[Guide]: https://example.test/guide\n"
        var document = MarkdownDocument(source: source)
        #expect(document.source == source)
        let labels = document.leaves.filter { $0.source == "Guide" }
        #expect(labels.count == 2)
        for label in labels { try document.apply(id: label.id, text: "指南") }
        #expect(document.translated.components(separatedBy: "[指南][Guide]").count - 1 == 2)
        #expect(document.translated.contains("[Guide]: https://example.test/guide"))
    }
    @Test func v6IncrementalDecoderBuffersJSONAcrossArbitraryChunks() throws {
        let id = UUID()
        let line = String(decoding: try JSONEncoder().encode(["id": id.uuidString, "text": "译文\n\n拆分"]), as: UTF8.self)
        var decoder = MarkdownResponseDecoder(); var values: [(UUID, String)] = []
        for character in line { values += decoder.append(String(character)).records }
        #expect(values.isEmpty)
        values += decoder.append("", final: true).records
        #expect(values.count == 1)
        #expect(values.first?.0 == id)
        #expect(values.first?.1 == "译文\n\n拆分")
    }
}
