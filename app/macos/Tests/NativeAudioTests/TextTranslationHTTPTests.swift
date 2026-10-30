import Foundation
import Testing
import WorkbenchCore
@testable import TranslationWorkbench

@Suite(.serialized) @MainActor
struct TextTranslationHTTPTests {
    @Test func japaneseToGermanUsesSelectedLanguageAndOnlyMatchingGlossary() async throws {
        let payload = #"{"choices":[{"index":0,"message":{"content":"Guten Morgen"},"finish_reason":"stop"}]}"#
        let fixture = TextHTTPFixture(contentType: "application/json", chunks: [Data(payload.utf8)])
        let network = fixture.session()
        defer { network.invalidateAndCancel(); TextHTTPProtocol.fixture = nil }
        let profile = try ProviderProfile(name: "DeepSeek", baseURL: "https://api.deepseek.com", model: "deepseek-flash")
        let direction = try #require(TextTranslationDirection(rawValue: "ja>de"))
        let glossary = TranslationGlossary(name: "Greeting", entries: [
            .init(source: "おはよう", target: "Guten Morgen", targetLanguage: "de"),
            .init(source: "おはよう", target: "DO_NOT_SEND_ENGLISH", targetLanguage: "en")])
        try await OpenAITextTranslator(session: network, responseMode: .nonStreaming).translate(
            .init(input: "おはよう", direction: direction, provider: profile.snapshot, resources: .init(glossaries: [glossary])),
            apiKey: "controlled-text-key") { _ in }
        let request = try #require(fixture.requests.first)
        let body = try #require(JSONSerialization.jsonObject(with: bodyData(request)) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages[0]["content"]?.contains("into German") == true)
        #expect(messages[0]["content"]?.contains("Guten Morgen") == true)
        #expect(messages[0]["content"]?.contains("DO_NOT_SEND_ENGLISH") == false)
    }

    @Test func defaultRequestUsesJSONAndPreservesUsageWithoutReasoning() async throws {
        let payload = #"{"choices":[{"index":0,"message":{"role":"assistant","content":"量子比特","reasoning_content":"not user text"},"finish_reason":"stop"}],"usage":{"prompt_tokens":24,"completion_tokens":4,"total_tokens":28}}"#
        let fixture = TextHTTPFixture(contentType: "application/json", chunks: payload.utf8.map { Data([$0]) })
        let network = fixture.session()
        defer { network.invalidateAndCancel(); TextHTTPProtocol.fixture = nil }
        let profile = try ProviderProfile(name: "DeepSeek", baseURL: "https://api.deepseek.com", model: "deepseek-flash")
        let events = TextHTTPEvents()
        try await OpenAITextTranslator(session: network, maxOutputTokens: 256).translate(
            .init(input: "qubit", direction: .englishToChinese, provider: profile.snapshot), apiKey: "controlled-text-key") { await events.append($0) }
        #expect(await events.values == [.delta("量子比特"), .usage(.init(promptTokens: 24, completionTokens: 4, totalTokens: 28))])
        let request = try #require(fixture.requests.first)
        let body = try #require(JSONSerialization.jsonObject(with: bodyData(request)) as? [String: Any])
        #expect(body["stream"] as? Bool == false)
        #expect(body["max_tokens"] as? Int == 256)
        #expect(body["thinking"] as? [String: String] == ["type": "disabled"])
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(fixture.requests.count == 1)
    }

    @Test func multilineTranslationPreservesSourceLinesInWorkspaceHistoryAndExport() async throws {
        let records = """
        {"id":4,"text":"最后。"}
        {"id":3,"text":"重复。"}
        {"id":2,"text":"第二行。"}
        {"id":0,"text":"第一行。"}
        """
        let payload = try JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "message": ["content": records], "finish_reason": "stop"]]])
        let fixture = TextHTTPFixture(contentType: "application/json", chunks: payload.map { Data([$0]) })
        let network = fixture.session()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("text-line-http-\(UUID())")
        defer { network.invalidateAndCancel(); TextHTTPProtocol.fixture = nil; try? FileManager.default.removeItem(at: root) }
        let profile = try ProviderProfile(name: "Controlled", baseURL: "https://provider.test", model: "custom")
        let store = TextWorkspaceStore(root: root)
        let app = TextTranslationSession(store: store, credentials: ResourceHTTPCredentials(), service: OpenAITextTranslator(session: network))
        _ = app.setDirection(direction: .englishToChinese)
        _ = app.updateInput(text: "First.\r\n\r\nSecond.\nFirst.\rLast.\n")
        await app.submit(provider: profile.snapshot, direction: .englishToChinese)
        let expected = "第一行。\r\n\r\n第二行。\n重复。\r最后。\n"
        #expect(app.workspace.translation == expected)
        #expect(app.workspace.currentResult?.status == .completed)
        #expect(app.history.first?.translation == expected)
        let reopened = TextTranslationSession(store: store, credentials: ResourceHTTPCredentials(), service: OpenAITextTranslator(session: network))
        #expect(reopened.workspace.translation == expected)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("text-lines-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: destination) }
        #expect(app.exportTranslation(to: destination))
        #expect(try Data(contentsOf: destination) == Data(expected.utf8))
        #expect(fixture.requests.count == 1)
        let sent = try #require(fixture.requests.first)
        let body = try #require(JSONSerialization.jsonObject(with: bodyData(sent)) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: String]])
        let content = try #require(messages.last?["content"])
        let lines = try content.split(separator: "\n").map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        #expect(lines.compactMap { $0["id"] as? Int } == [0, 2, 3, 4])
        #expect(lines.compactMap { $0["text"] as? String } == ["First.", "Second.", "First.", "Last."])
        #expect(body["stream"] as? Bool == false)
    }

    @Test(arguments: ["length", "aborted", "insufficient_system_resource", "content_filter", "tool_calls"])
    func nonStreamingIncompleteCompletionDoesNotPublishPartialContent(reason: String) async throws {
        let payload = "{\"choices\":[{\"index\":0,\"message\":{\"content\":\"retained partial\"},\"finish_reason\":\"\(reason)\"}]}"
        let fixture = TextHTTPFixture(contentType: "application/json", chunks: [Data(payload.utf8)])
        let network = fixture.session()
        defer { network.invalidateAndCancel(); TextHTTPProtocol.fixture = nil }
        let profile = try ProviderProfile(name: "Controlled", baseURL: "https://provider.test", model: "custom")
        let events = TextHTTPEvents()
        var failure: TextTranslationError?
        do {
            try await OpenAITextTranslator(session: network, responseMode: .nonStreaming).translate(
                .init(input: "hello", direction: .englishToChinese, provider: profile.snapshot), apiKey: "controlled-text-key") { await events.append($0) }
        } catch { failure = error as? TextTranslationError }
        #expect(await events.values.isEmpty)
        #expect(failure == (["content_filter", "tool_calls"].contains(reason) ? .processing : .interrupted))
        #expect(fixture.requests.count == 1)
    }

    @Test(arguments: [
        "合并成一段的译文。",
        #"{"id":0,"text":"缺少第二行"}"#,
        "{\"id\":0,\"text\":\"第一行\"}\n{\"id\":0,\"text\":\"重复\"}",
        "{\"id\":0,\"text\":\"第一行\"}\n{\"id\":9,\"text\":\"未知行\"}",
        "{\"id\":0,\"text\":\"额外\\n换行\"}\n{\"id\":1,\"text\":\"第二行\"}",
        "{\"id\":0,\"text\":\"第一行\"}\n{\"id\":1,\"text\":\" \"}",
        "{\"id\":0,\"text\":\"第一行\"}\n{\"id\":"
    ])
    func invalidLineCorrespondenceNeverPublishesOrRetries(records: String) async throws {
        let payload = try JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "message": ["content": records], "finish_reason": "stop"]]])
        let fixture = TextHTTPFixture(contentType: "application/json", chunks: [payload])
        let network = fixture.session()
        defer { network.invalidateAndCancel(); TextHTTPProtocol.fixture = nil }
        let profile = try ProviderProfile(name: "Controlled", baseURL: "https://provider.test", model: "custom")
        await #expect(throws: TextTranslationError.structure) {
            try await OpenAITextTranslator(session: network).translate(
                .init(input: "First.\nSecond.", direction: .englishToChinese, provider: profile.snapshot), apiKey: "controlled-text-key") { _ in
                    Issue.record("Invalid line structure became visible")
                }
        }
        #expect(fixture.requests.count == 1)
    }

    @Test func blankLinesWhitespaceAndUnicodeSeparatorsSurviveTranslation() async throws {
        let records = "{\"id\":1,\"text\":\"  你好 \\t\"}\n{\"id\":3,\"text\":\"世界\"}"
        let payload = try JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "message": ["content": records], "finish_reason": "stop"]]])
        let fixture = TextHTTPFixture(contentType: "application/json", chunks: [payload])
        let network = fixture.session()
        defer { network.invalidateAndCancel(); TextHTTPProtocol.fixture = nil }
        let profile = try ProviderProfile(name: "Controlled", baseURL: "https://provider.test", model: "custom")
        let events = TextHTTPEvents()
        try await OpenAITextTranslator(session: network).translate(
            .init(input: " \t\r\n  Hello \t\u{2028}\t\rWorld\u{2029}\n", direction: .englishToChinese, provider: profile.snapshot), apiKey: "controlled-text-key") { await events.append($0) }
        #expect(await events.values == [.delta(" \t\r\n  你好 \t\u{2028}\t\r世界\u{2029}\n")])
    }

    @Test(arguments: ["{}", #"{"choices":[]}"#,
        #"{"choices":[{"index":0,"message":{"content":null,"reasoning_content":"hidden"},"finish_reason":"stop"}]}"#,
        #"{"choices":[{"index":0,"message":{"content":"value"},"finish_reason":null}]}"#,
        #"{"choices":[{"index":1,"message":{"content":"wrong choice"},"finish_reason":"stop"}]}"#,
        #"{"choices":[{"index":0,"message":{"content":"value"},"finish_reason":"stop"}],"usage":{"total_tokens":-1}}"#])
    func nonStreamingInvalidEnvelopesNeverBecomeSuccess(payload: String) async throws {
        let fixture = TextHTTPFixture(contentType: "application/json", chunks: [Data(payload.utf8)])
        let network = fixture.session()
        defer { network.invalidateAndCancel(); TextHTTPProtocol.fixture = nil }
        let profile = try ProviderProfile(name: "Controlled", baseURL: "https://provider.test", model: "custom")
        await #expect(throws: TextTranslationError.processing) {
            try await OpenAITextTranslator(session: network, responseMode: .nonStreaming).translate(
                .init(input: "hello", direction: .englishToChinese, provider: profile.snapshot), apiKey: "controlled-text-key") { _ in Issue.record("Unexpected visible output") }
        }
        #expect(fixture.requests.count == 1)
    }

    @Test func cancelledNonStreamingBodyDoesNotPublishPartialJSON() async throws {
        let fixture = TextHTTPFixture(contentType: "application/json", chunks: [Data(#"{"choices":[{"index":0,"message":{"content":"not finished"}"#.utf8)], holdOpen: true)
        let network = fixture.session()
        defer { network.invalidateAndCancel(); TextHTTPProtocol.fixture = nil }
        let profile = try ProviderProfile(name: "Controlled", baseURL: "https://provider.test", model: "custom")
        let task = Task { () -> TextTranslationError? in
            do {
                try await OpenAITextTranslator(session: network, responseMode: .nonStreaming).translate(
                    .init(input: "hello", direction: .englishToChinese, provider: profile.snapshot), apiKey: "controlled-text-key") { _ in Issue.record("Unexpected incomplete JSON output") }
                return nil
            } catch { return error as? TextTranslationError }
        }
        let deadline = Date().addingTimeInterval(2)
        while fixture.requests.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        #expect(await task.value == .interrupted)
        #expect(fixture.requests.count == 1)
    }

    @Test(arguments: TextTranslationDirection.allCases, [false, true])
    func applicationSelectionReachesHTTPForBothDirectionsAndOptionalPreset(direction: TextTranslationDirection, usePreset: Bool) async throws {
        let wire = #"{"choices":[{"index":0,"message":{"content":"Controlled translated result"},"finish_reason":"stop"}]}"#
        let fixture = TextHTTPFixture(contentType: "application/json", chunks: [Data(wire.utf8)]), network = fixture.session()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("text-resource-http-\(UUID())")
        defer { network.invalidateAndCancel(); TextHTTPProtocol.fixture = nil; try? FileManager.default.removeItem(at: root) }
        let profile = try ProviderProfile(name: "Controlled HTTP", baseURL: "https://provider.test", model: "custom")
        let credentials = ResourceHTTPCredentials()
        let library = TranslationResourceLibrary(root: root)
        let glossary = TranslationGlossary(name: "Quantum", entries: [
            .init(source: "qubit", target: "量子比特", targetLanguage: "zh"),
            .init(source: "量子比特", target: "qubit", targetLanguage: "en")])
        let unused = TranslationGlossary(name: "Unselected", entries: [.init(source: "UNSELECTED_SENTINEL", target: "not sent")])
        let preset = TranslationPromptPreset(name: "Custom scholarly", instruction: "Use precise scholarly wording and preserve uncertainty.")
        #expect(library.saveGlossary(glossary)); #expect(library.saveGlossary(unused)); #expect(library.savePrompt(preset))
        let selection = TranslationResourceSelection(glossaryIDs: [glossary.id], promptID: usePreset ? preset.id : nil)
        let app = TextTranslationSession(store: TextWorkspaceStore(root: root), credentials: credentials, service: OpenAITextTranslator(session: network))
        let source = direction == .englishToChinese ? "A qubit may preserve coherence." : "量子比特可能保持相干性。"
        #expect(app.updateInput(text: source)); #expect(app.selectResources(selection: selection))
        await app.submit(provider: profile.snapshot, direction: direction, resources: library)
        #expect(fixture.requests.count == 1)
        let sent = try #require(fixture.requests.first)
        let body = try #require(JSONSerialization.jsonObject(with: bodyData(sent)) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: String]])
        let instructions = try #require(messages.first?["content"])
        #expect(messages[1] == ["role": "user", "content": source])
        #expect(instructions.contains(preset.instruction) == usePreset)
        #expect(!instructions.contains("UNSELECTED_SENTINEL"))
        let expectedTerms = try JSONSerialization.data(withJSONObject: glossary.entries.filter { $0.targetLanguage == (direction == .englishToChinese ? "zh" : "en") }.map { ["source": $0.source, "target": $0.target] }, options: [.sortedKeys])
        #expect(instructions.contains(String(decoding: expectedTerms, as: UTF8.self)))
        let result = try #require(app.workspace.currentResult)
        #expect(result.direction.targetLanguage == direction.targetLanguage)
        #expect(direction == .englishToChinese ? result.direction.sourceLanguage == .english : result.direction.sourceLanguage.rawValue.hasPrefix("zh"))
        #expect(result.sourceWasAutomatic == true)
        #expect(result.resources == (try library.snapshot(selection)))
        #expect(result.currentText == "Controlled translated result" && result.status == .completed)
        #expect(!String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("controlled-text-key"))
    }

    @Test func markdownContractAndOpaqueIDsAreSentWithoutProtectedCodeOrAddresses() async throws {
        let wire = event(#"{"choices":[{"index":0,"delta":{"content":"{}"},"finish_reason":"stop"}]}"#) + event("[DONE]")
        let fixture = TextHTTPFixture(chunks: [Data(wire.utf8)])
        let network = fixture.session()
        defer { network.invalidateAndCancel(); TextHTTPProtocol.fixture = nil }
        let profile = try ProviderProfile(name: "Controlled", baseURL: "https://provider.test", model: "custom")
        let document = MarkdownDocument(source: "# Title\n\n[Label](https://example.test)\n\n```swift\n// private technical text\n```\n")
        try await OpenAITextTranslator(session: network, responseMode: .streaming).translate(
            TextTranslationRequest(input: document.requestPayload, direction: .englishToChinese, provider: profile.snapshot, responseContract: MarkdownDocument.responseContract, resources: .init(prompt: .init(name: "Academic", instruction: "Use precise terms."))),
            apiKey: "controlled-text-key") { _ in }
        let request = try #require(fixture.requests.first)
        let body = try #require(JSONSerialization.jsonObject(with: bodyData(request)) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages[0]["content"]?.hasSuffix(MarkdownDocument.responseContract) == true)
        #expect(messages[0]["content"]?.contains("Use precise terms.") == true)
        #expect(messages[1]["content"] == document.requestPayload)
        #expect(!document.requestPayload.contains("https://example.test"))
        #expect(!document.requestPayload.contains("private technical text"))
    }

    @Test(arguments: ["data:\n\n", "data:   \t\n\n", "data:\ndata:\n\n",
                      event(#"{"choices":[]}"#), event(#"{"choices":[],"usage":null}"#)])
    func emptyStreamEventsDoNotInterruptTranslation(emptyEvent: String) async throws {
        let wire = event(#"{"choices":[{"index":0,"delta":{"content":"前"},"finish_reason":null}]}"#) +
            emptyEvent + event(#"{"choices":[{"index":0,"delta":{"content":"后"},"finish_reason":null}]}"#) +
            event(#"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#) + emptyEvent + event("[DONE]")
        let fixture = TextHTTPFixture(chunks: wire.utf8.map { Data([$0]) })
        let network = fixture.session()
        defer { network.invalidateAndCancel(); TextHTTPProtocol.fixture = nil }
        let profile = try ProviderProfile(name: "Controlled", baseURL: "https://provider.test", model: "custom")
        let events = TextHTTPEvents()
        try await OpenAITextTranslator(session: network, responseMode: .streaming).translate(
            TextTranslationRequest(input: "before after", direction: .englishToChinese, provider: profile.snapshot),
            apiKey: "controlled-text-key") { await events.append($0) }
        #expect(await events.values == [.delta("前"), .delta("后")])
        #expect(fixture.requests.count == 1)
    }

    @Test(arguments: [#"{"choices":[{"index":1,"delta":{},"finish_reason":null}]}"#,
                      "{}", #"{"choices":null}"#, "   invalid-json"])
    func nonemptyInvalidEventsStillFailAndPreserveEarlierText(payload: String) async throws {
        let wire = event(#"{"choices":[{"index":0,"delta":{"content":"partial"},"finish_reason":null}]}"#) + event(payload)
        let fixture = TextHTTPFixture(chunks: [Data(wire.utf8)])
        let network = fixture.session()
        defer { network.invalidateAndCancel(); TextHTTPProtocol.fixture = nil }
        let profile = try ProviderProfile(name: "Controlled", baseURL: "https://provider.test", model: "custom")
        let events = TextHTTPEvents()
        var failure: TextTranslationError?
        do {
            try await OpenAITextTranslator(session: network, responseMode: .streaming).translate(
                TextTranslationRequest(input: "hello", direction: .englishToChinese, provider: profile.snapshot),
                apiKey: "controlled-text-key") { await events.append($0) }
        } catch { failure = error as? TextTranslationError }
        #expect(failure == .processing)
        #expect(await events.values == [.delta("partial")])
        #expect(fixture.requests.count == 1)
    }

    @Test func redirectsCannotForwardCredentialsOrTextToAnotherTarget() async throws {
        let destination = URL(string: "https://other-target.test/stolen")!
        let fixture = TextHTTPFixture(chunks: [], redirectURL: destination)
        let network = fixture.session()
        defer { network.invalidateAndCancel(); TextHTTPProtocol.fixture = nil }
        let profile = try ProviderProfile(name: "Controlled", baseURL: "https://provider.test", model: "custom")
        let events = TextHTTPEvents()
        var failure: TextTranslationError?
        do {
            try await OpenAITextTranslator(session: network, responseMode: .streaming).translate(
                TextTranslationRequest(input: "private text", direction: .englishToChinese, provider: profile.snapshot),
                apiKey: "controlled-text-key") { await events.append($0) }
        } catch { failure = error as? TextTranslationError }
        #expect(failure == .configuration)
        #expect(await events.values.isEmpty)
        #expect(fixture.requests.count == 1)
        #expect(!fixture.requests.contains { $0.url?.host == destination.host })
    }

    @Test func invalidInputAndCredentialFailBeforeSendingARequest() async throws {
        let fixture = TextHTTPFixture(chunks: [])
        let network = fixture.session()
        defer { network.invalidateAndCancel(); TextHTTPProtocol.fixture = nil }
        let profile = try ProviderProfile(name: "Controlled", baseURL: "https://provider.test", model: "custom")
        let cases: [(String, String, TextTranslationError)] = [("  \n", "controlled-text-key", .emptyInput),
            ("hello", "", .credential), ("hello", "bad\nkey", .credential)]
        for (input, key, expected) in cases {
            var failure: TextTranslationError?
            do {
                try await OpenAITextTranslator(session: network, responseMode: .streaming).translate(
                    TextTranslationRequest(input: input, direction: .englishToChinese, provider: profile.snapshot),
                    apiKey: key) { _ in Issue.record("Unexpected response event") }
            } catch { failure = error as? TextTranslationError }
            #expect(failure == expected)
        }
        #expect(fixture.requests.isEmpty)
    }

    @Test func nonSSEAndInvalidUTF8ResponsesAreRejected() async throws {
        let cases = [("application/json", Data(#"{"choices":[{"message":{"content":"not streamed"}}]}"#.utf8)),
                     ("text/event-stream", Data([100, 97, 116, 97, 58, 32, 255, 10, 10]))]
        for (contentType, body) in cases {
            let fixture = TextHTTPFixture(contentType: contentType, chunks: [body])
            let network = fixture.session()
            defer { network.invalidateAndCancel(); TextHTTPProtocol.fixture = nil }
            let profile = try ProviderProfile(name: "Controlled", baseURL: "https://provider.test", model: "custom")
            var failure: TextTranslationError?
            do {
                try await OpenAITextTranslator(session: network, responseMode: .streaming).translate(
                    TextTranslationRequest(input: "hello", direction: .englishToChinese, provider: profile.snapshot),
                    apiKey: "controlled-text-key") { _ in Issue.record("Unexpected response event") }
            } catch { failure = error as? TextTranslationError }
            #expect(failure == .processing)
            #expect(fixture.requests.count == 1)
        }
    }

    @Test func deltasArriveBeforeCompletionAndCancellationStopsTheRequest() async throws {
        let fixture = TextHTTPFixture(chunks: [Data(event(#"{"choices":[{"index":0,"delta":{"content":"first"},"finish_reason":null}]}"#).utf8)], holdOpen: true)
        let network = fixture.session()
        defer { network.invalidateAndCancel(); TextHTTPProtocol.fixture = nil }
        let profile = try ProviderProfile(name: "Controlled", baseURL: "https://provider.test", model: "custom")
        let events = TextHTTPEvents()
        let task = Task { () -> TextTranslationError? in
            do {
                try await OpenAITextTranslator(session: network, responseMode: .streaming).translate(
                    TextTranslationRequest(input: "hello", direction: .englishToChinese, provider: profile.snapshot),
                    apiKey: "controlled-text-key") { await events.append($0) }
                return nil
            } catch { return error as? TextTranslationError }
        }
        defer { task.cancel() }
        for _ in 0..<200 {
            if await !events.values.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await events.values == [.delta("first")])
        #expect(fixture.stops == 0)
        task.cancel()
        #expect(await task.value == .interrupted)
        #expect(fixture.requests.count == 1)
        for _ in 0..<200 {
            if fixture.stops == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(fixture.stops == 1)
    }

    @Test func doneClosesAnOtherwiseOpenStreamWithoutWaitingForEOF() async throws {
        let wire = event(#"{"choices":[{"index":0,"delta":{"content":"complete"},"finish_reason":"stop"}]}"#) + event("[DONE]")
        let fixture = TextHTTPFixture(chunks: [Data(wire.utf8)], holdOpen: true)
        let network = fixture.session()
        defer { network.invalidateAndCancel(); TextHTTPProtocol.fixture = nil }
        let profile = try ProviderProfile(name: "Controlled", baseURL: "https://provider.test", model: "custom")
        let events = TextHTTPEvents()
        try await OpenAITextTranslator(session: network, responseMode: .streaming).translate(
            TextTranslationRequest(input: "hello", direction: .englishToChinese, provider: profile.snapshot),
            apiKey: "controlled-text-key") { await events.append($0) }
        #expect(await events.values == [.delta("complete")])
        for _ in 0..<200 {
            if fixture.stops == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(fixture.stops == 1)
        #expect(fixture.requests.count == 1)
    }

    @Test func prematureEOFAndTransportErrorsNeverPromotePartialTextToSuccess() async throws {
        let cases: [(String, URLError.Code?, TextTranslationError)] = [
            ("", nil, .interrupted),
            (event(#"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#), nil, .interrupted),
            (event("[DONE]"), nil, .processing),
            (event("{broken-json"), nil, .processing),
            ("", .networkConnectionLost, .network),
            ("", .cancelled, .interrupted)
        ]
        for (suffix, transportError, expected) in cases {
            let wire = event(#"{"choices":[{"index":0,"delta":{"content":"partial"},"finish_reason":null}]}"#) + suffix
            let fixture = TextHTTPFixture(chunks: [Data(wire.utf8)], transportError: transportError)
            let network = fixture.session()
            defer { network.invalidateAndCancel(); TextHTTPProtocol.fixture = nil }
            let profile = try ProviderProfile(name: "Controlled", baseURL: "https://provider.test", model: "custom")
            let events = TextHTTPEvents()
            var failure: TextTranslationError?
            do {
                try await OpenAITextTranslator(session: network, responseMode: .streaming).translate(
                    TextTranslationRequest(input: "hello", direction: .englishToChinese, provider: profile.snapshot),
                    apiKey: "controlled-text-key") { await events.append($0) }
            } catch { failure = error as? TextTranslationError }
            #expect(failure == expected)
            // A transport error may arrive before URLSession releases buffered bytes.
            if transportError == nil { #expect(await events.values == [.delta("partial")]) }
            #expect(fixture.requests.count == 1)
        }
    }

    @Test func rejectedHTTPRequestsAreClassifiedWithoutRetryOrProviderText() async throws {
        let cases: [(Int, String?, TextTranslationError)] = [
            (401, nil, .credential), (403, nil, .credential), (402, nil, .rateLimited), (429, nil, .rateLimited),
            (400, "model_not_found", .modelUnavailable), (404, "model_not_found", .modelUnavailable),
            (404, nil, .configuration), (400, nil, .configuration), (422, nil, .configuration),
            (302, nil, .configuration), (503, nil, .processing)
        ]
        for (status, code, expected) in cases {
            var detail = ["message": "private-response-marker controlled-text-key"]
            detail["code"] = code
            let fixture = TextHTTPFixture(status: status, contentType: "application/json",
                chunks: [try JSONSerialization.data(withJSONObject: ["error": detail])])
            let network = fixture.session()
            defer { network.invalidateAndCancel(); TextHTTPProtocol.fixture = nil }
            let profile = try ProviderProfile(name: "Controlled", baseURL: "https://provider.test", model: "custom")
            let events = TextHTTPEvents()
            var failure: TextTranslationError?
            do {
                try await OpenAITextTranslator(session: network, responseMode: .streaming).translate(
                    TextTranslationRequest(input: "hello", direction: .englishToChinese, provider: profile.snapshot),
                    apiKey: "controlled-text-key") { await events.append($0) }
            } catch {
                failure = error as? TextTranslationError
                #expect(!String(describing: error).contains("private-response-marker"))
                #expect(!String(describing: error).contains("controlled-text-key"))
            }
            #expect(failure == expected)
            #expect(await events.values.isEmpty)
            #expect(fixture.requests.count == 1)
        }
    }

    @Test func explicitStreamErrorPreservesEarlierTextAndClassifiesKnownCode() async throws {
        let wire = event(#"{"choices":[{"index":0,"delta":{"content":"partial"},"finish_reason":null}]}"#) +
            event(#"{"error":{"code":"rate_limit_exceeded","message":"private-response-marker controlled-text-key"}}"#)
        let fixture = TextHTTPFixture(chunks: [Data(wire.utf8)])
        let network = fixture.session()
        defer { network.invalidateAndCancel(); TextHTTPProtocol.fixture = nil }
        let profile = try ProviderProfile(name: "Controlled", baseURL: "https://provider.test", model: "custom")
        let events = TextHTTPEvents()
        var failure: TextTranslationError?
        do {
            try await OpenAITextTranslator(session: network, responseMode: .streaming).translate(
                TextTranslationRequest(input: "hello", direction: .englishToChinese, provider: profile.snapshot),
                apiKey: "controlled-text-key") { await events.append($0) }
        } catch { failure = error as? TextTranslationError }
        #expect(failure == .rateLimited)
        #expect(await events.values == [.delta("partial")])
        #expect(fixture.requests.count == 1)
    }

    @Test(arguments: ["length", "aborted", "insufficient_system_resource", "content_filter", "tool_calls"])
    func incompleteFinishPreservesTheLastReceivedDelta(reason: String) async throws {
        let wire = event(#"{"choices":[{"index":0,"delta":{"content":"partial"},"finish_reason":null}]}"#) +
            event("{\"choices\":[{\"index\":0,\"delta\":{\"content\":\" tail\"},\"finish_reason\":\"\(reason)\"}]}") + event("[DONE]")
        let fixture = TextHTTPFixture(chunks: [Data(wire.utf8)])
        let network = fixture.session()
        defer { network.invalidateAndCancel(); TextHTTPProtocol.fixture = nil }
        let profile = try ProviderProfile(name: "Controlled", baseURL: "https://provider.test", model: "custom")
        let events = TextHTTPEvents()
        var failure: TextTranslationError?
        do {
            try await OpenAITextTranslator(session: network, responseMode: .streaming).translate(
                TextTranslationRequest(input: "hello", direction: .englishToChinese, provider: profile.snapshot),
                apiKey: "controlled-text-key") { await events.append($0) }
        } catch { failure = error as? TextTranslationError }
        let expected: TextTranslationError = ["content_filter", "tool_calls"].contains(reason) ? .processing : .interrupted
        #expect(failure == expected)
        #expect(await events.values == [.delta("partial"), .delta(" tail")])
        #expect(fixture.requests.count == 1)
    }

    @Test(arguments: [false, true])
    func byteFragmentedStreamsPreserveChineseAndSupportBothUsageShapes(usageOnlyChunk: Bool) async throws {
        let usage = #"{"prompt_tokens":12,"completion_tokens":4,"total_tokens":16}"#
        let finish = usageOnlyChunk ?
            event(#"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#) + event("{\"choices\":[],\"usage\":\(usage)}") :
            event("{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":\(usage)}")
        let stream = "\u{feff}: keep-alive\r\n\r\n" +
            event(#"{"choices":[{"index":0,"delta":{"reasoning_content":"Hidden reasoning"},"finish_reason":null}],"usage":null}"#) +
            "data: {\"choices\":[\r\ndata: {\"index\":0,\"delta\":{\"content\":\"中😀文\"},\"finish_reason\":null}]}\r\n\r\n" +
            finish + event("[DONE]")
        let fixture = TextHTTPFixture(chunks: stream.utf8.map { Data([$0]) })
        let network = fixture.session()
        defer { network.invalidateAndCancel(); TextHTTPProtocol.fixture = nil }
        let profile = try ProviderProfile(name: "DeepSeek", baseURL: "https://api.deepseek.com", model: "deepseek-flash")
        let events = TextHTTPEvents()
        try await OpenAITextTranslator(session: network, maxOutputTokens: 512, responseMode: .streaming).translate(
            TextTranslationRequest(input: "中文", direction: .chineseToEnglish, provider: profile.snapshot),
            apiKey: "controlled-text-key") { await events.append($0) }
        #expect(await events.values == [.delta("中😀文"), .usage(TextTranslationUsage(promptTokens: 12, completionTokens: 4, totalTokens: 16))])
        let request = try #require(fixture.requests.first)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData(request)) as? [String: Any])
        #expect(body["max_tokens"] as? Int == 512)
        #expect(body["thinking"] as? [String: String] == ["type": "disabled"])
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages[0]["content"]?.contains("English") == true)
    }

    @Test func customProfileSendsExactInputAndStreamsOnlyTranslatedContent() async throws {
        let fixture = TextHTTPFixture(chunks: [Data((
            event(#"{"choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}"#) +
            event(#"{"choices":[{"index":0,"delta":{"content":"你好"},"finish_reason":null}]}"#) +
            event(#"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#) + event("[DONE]")
        ).utf8)])
        let network = fixture.session()
        defer { network.invalidateAndCancel(); TextHTTPProtocol.fixture = nil }
        let profile = try ProviderProfile(name: "Custom", baseURL: "https://provider.test/proxy/v1/chat/completions/", model: "vendor/custom-model")
        let input = "Hello\n\"world\"  中文"
        let events = TextHTTPEvents()
        try await OpenAITextTranslator(session: network, responseMode: .streaming).translate(
            TextTranslationRequest(input: input, direction: .englishToChinese, provider: profile.snapshot),
            apiKey: "controlled-text-key") { await events.append($0) }
        #expect(await events.values == [.delta("你好")])
        let request = try #require(fixture.requests.first)
        #expect(fixture.requests.count == 1)
        #expect(request.url?.absoluteString == "https://provider.test/proxy/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer controlled-text-key")
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData(request)) as? [String: Any])
        #expect(body["model"] as? String == "vendor/custom-model")
        #expect(body["stream"] as? Bool == true)
        #expect(body["thinking"] == nil)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] == "system")
        #expect(messages[0]["content"]?.contains("Simplified Chinese") == true)
        #expect(messages[1] == ["role": "user", "content": input])
    }
}

private func event(_ data: String) -> String { "data: " + data + "\n\n" }

private func bodyData(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: buffer.count)
        if read < 0 { throw URLError(.cannotDecodeRawData) }
        if read == 0 { break }
        result.append(contentsOf: buffer.prefix(read))
    }
    return result
}

private actor TextHTTPEvents {
    private(set) var values: [TextTranslationEvent] = []
    func append(_ value: TextTranslationEvent) { values.append(value) }
}

private final class TextHTTPFixture: @unchecked Sendable {
    let status: Int
    let contentType: String
    let chunks: [Data]
    let transportError: URLError.Code?
    let holdOpen: Bool
    let redirectURL: URL?
    private let lock = NSLock()
    private var received: [URLRequest] = []
    private var stoppedCount = 0
    init(status: Int = 200, contentType: String = "text/event-stream; charset=utf-8", chunks: [Data],
         transportError: URLError.Code? = nil, holdOpen: Bool = false, redirectURL: URL? = nil) {
        self.status = status; self.contentType = contentType; self.chunks = chunks; self.transportError = transportError; self.holdOpen = holdOpen; self.redirectURL = redirectURL
    }
    var stops: Int { lock.lock(); defer { lock.unlock() }; return stoppedCount }
    func stopped() { lock.lock(); stoppedCount += 1; lock.unlock() }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return received }
    func record(_ request: URLRequest) { lock.lock(); received.append(request); lock.unlock() }
    func session() -> URLSession {
        TextHTTPProtocol.fixture = self
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TextHTTPProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class TextHTTPProtocol: URLProtocol, @unchecked Sendable {
    static var fixture: TextHTTPFixture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.fixture else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        fixture.record(request)
        if let destination = fixture.redirectURL, request.url?.host != destination.host {
            let response = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil,
                headerFields: ["Location": destination.absoluteString])!
            var redirected = request
            redirected.url = destination
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: fixture.status,
            httpVersion: nil, headerFields: ["Content-Type": fixture.contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in fixture.chunks { client?.urlProtocol(self, didLoad: chunk) }
        if let code = fixture.transportError { client?.urlProtocol(self, didFailWithError: URLError(code)) }
        else if !fixture.holdOpen { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { Self.fixture?.stopped() }
}

@MainActor private final class ResourceHTTPCredentials: ProviderCredentials {
    func read(reference: ProviderCredentialReference) throws -> String? { "controlled-text-key" }
    func save(_ value: String, reference: ProviderCredentialReference) throws {}
    func delete(reference: ProviderCredentialReference) throws {}
}
