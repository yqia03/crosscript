import Foundation
import Testing
@testable import WorkbenchCore

struct GeminiLiveTranslationProtocolTests {
    @Test func japaneseToGermanSelectionSurvivesHistoryAndReachesLiveSetup() throws {
        let direction = try #require(TextTranslationDirection(rawValue: "ja>de"))
        let restored = try JSONDecoder().decode(TextTranslationDirection.self, from: JSONEncoder().encode(direction))
        let wire = try GeminiLiveTranslationProtocol(configuration: .init(provider: .gemini), direction: restored)
        let setup = try #require((JSONSerialization.jsonObject(with: wire.setupMessage()) as? [String: Any])?["setup"] as? [String: Any])
        let generation = try #require(setup["generationConfig"] as? [String: Any])
        let translation = try #require(generation["translationConfig"] as? [String: Any])
        #expect(translation["targetLanguageCode"] as? String == "de")
        #expect(try JSONDecoder().decode(TextTranslationDirection.self, from: Data(#""englishToChinese""#.utf8)) == .englishToChinese)
    }
    @Test func liveLanguagesUsePublishedRegionalCodesAndRejectUnknownTargets() throws {
        let portuguese = try #require(TextTranslationDirection(rawValue: "fr>pt-BR"))
        let wire = try GeminiLiveTranslationProtocol(configuration: .init(provider: .gemini), direction: portuguese)
        #expect(String(decoding: try wire.setupMessage(), as: UTF8.self).contains("pt-BR"))
        let unsupported = try #require(TextTranslationDirection(rawValue: "en>xx"))
        #expect(throws: AudioProcessingError.configuration) {
            try GeminiLiveTranslationProtocol(configuration: .init(provider: .gemini), direction: unsupported)
        }
    }

    @Test func oneMessageRetainsBothChannelsWithoutPairingOrClaimingCompletion() throws {
        var wire = try GeminiLiveTranslationProtocol(configuration: .init(provider: .gemini), direction: .englishToChinese)
        let events = try wire.events(Data(#"{"serverContent":{"inputTranscription":{"text":"Hello ","startOffset":"0.25s","endOffset":"1.5s","finished":true},"outputTranscription":{"text":"你好","startOffset":"0s","finished":false}}}"#.utf8))
        #expect(events.count == 2)
        guard events.count == 2 else { return }
        guard case let .text(source, sourceID, sourceText, sourceStart, sourceEnd, sourceFinished) = events[0],
              case let .text(translation, targetID, targetText, targetStart, targetEnd, targetFinished) = events[1] else {
            Issue.record("Both independent transcription events must remain text events"); return
        }
        #expect(source == .source && translation == .translation)
        #expect(sourceText == "Hello " && targetText == "你好")
        #expect(!sourceID.isEmpty && sourceID != targetID)
        #expect(sourceStart == 0.25 && sourceEnd == 1.5 && sourceFinished == true)
        #expect(targetStart == 0 && targetEnd == nil && targetFinished == false)
        #expect(!events.contains(.closed) && !events.contains(.turnComplete))
    }
    @Test func fixedSetupUsesRootTranscriptionTogglesAndOnlyBoundedPCMInput() throws {
        let wire = try GeminiLiveTranslationProtocol(configuration: .init(provider: .gemini), direction: .englishToChinese)
        let setup = try #require((JSONSerialization.jsonObject(with: wire.setupMessage()) as? [String: Any])?["setup"] as? [String: Any])
        #expect(setup["model"] as? String == "models/gemini-3.5-live-translate-preview")
        #expect((setup["inputAudioTranscription"] as? [String: Any])?.isEmpty == true)
        #expect((setup["outputAudioTranscription"] as? [String: Any])?.isEmpty == true)
        let generation = try #require(setup["generationConfig"] as? [String: Any])
        #expect(generation["responseModalities"] as? [String] == ["AUDIO"])
        #expect(generation["inputAudioTranscription"] == nil && generation["outputAudioTranscription"] == nil)
        let translation = try #require(generation["translationConfig"] as? [String: Any])
        #expect(translation["targetLanguageCode"] as? String == "zh-Hans")
        #expect(translation["echoTargetLanguage"] as? Bool == false)
        #expect(wire.webSocketURL.absoluteString == "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")
        let pcm = Data(repeating: 17, count: 3200)
        let input = try #require((JSONSerialization.jsonObject(with: wire.audioMessage(pcm)) as? [String: Any])?["realtimeInput"] as? [String: Any])
        let audio = try #require(input["audio"] as? [String: String])
        #expect(audio["mimeType"] == "audio/pcm;rate=16000")
        #expect(audio["data"].flatMap { Data(base64Encoded: $0) } == pcm)
        for invalid in [Data(), Data([0]), Data(repeating: 0, count: 3202)] {
            #expect(throws: AudioProcessingError.configuration) { try wire.audioMessage(invalid) }
        }
        let end = try #require((JSONSerialization.jsonObject(with: wire.finishInputMessage()) as? [String: Any])?["realtimeInput"] as? [String: Bool])
        #expect(end == ["audioStreamEnd": true])
        let english = try GeminiLiveTranslationProtocol(configuration: .init(provider: .gemini), direction: .chineseToEnglish)
        let englishSetup = try #require((JSONSerialization.jsonObject(with: english.setupMessage()) as? [String: Any])?["setup"] as? [String: Any])
        let englishGeneration = try #require(englishSetup["generationConfig"] as? [String: Any])
        #expect((englishGeneration["translationConfig"] as? [String: Any])?["targetLanguageCode"] as? String == "en")
        for invalid in [AudioServiceConfiguration(provider: .openAI),
                        .init(provider: .gemini, baseURL: "https://example.test/v1beta"),
                        .init(provider: .gemini, model: "unverified-model")] {
            #expect(throws: AudioProcessingError.configuration) { try GeminiLiveTranslationProtocol(configuration: invalid, direction: .englishToChinese) }
        }
    }

    @Test func diagnosticsDiscardAudioAndNeverConfirmTheInputTail() throws {
        var wire = try GeminiLiveTranslationProtocol(configuration: .init(provider: .gemini), direction: .chineseToEnglish)
        let payload = Data(#"{"setupComplete":{},"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"AAECAw=="}},{"text":"not a transcription"}]},"turnComplete":true,"generationComplete":true,"interrupted":true,"interactionStatus":"IN_PROGRESS"},"goAway":{"timeLeft":"12.25s"},"usageMetadata":{"totalTokenCount":11,"responseTokensDetails":[{"modality":"AUDIO","tokenCount":9}],"unknownSecret":"do not retain"}}"#.utf8)
        let events = try wire.events(payload)
        #expect(events == [.configured, .audioDiscarded(byteCount: 4), .turnComplete, .generationComplete, .interrupted,
                           .interactionStatus(.inProgress), .goAway(timeLeft: 12.25),
                           .usage(.init(tokenCounts: ["totalTokenCount": 11], modalityTokenCounts: ["responseTokensDetails": ["AUDIO": 9]]))])
        #expect(!events.contains(.closed))
        #expect(try wire.events(Data(#"{"serverContent":{"interactionStatus":"FUTURE_SECRET_STATUS"}}"#.utf8)).isEmpty)
    }

    @Test func malformedEventsAndProviderErrorsStayTypedAndSecretFree() throws {
        for raw in [#"{"error":{"code":401,"message":"fake-key https://secret"}}"#,
                    #"{"error":{"code":429,"message":"fake-key"}}"#,
                    #"{"serverContent":{"inputTranscription":{"text":"x","startOffset":"NaNs"}}}"#,
                    #"{"serverContent":{"outputTranscription":{"startOffset":"3s","endOffset":"2s"}}}"#,
                    #"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm","data":"not-base64"}}]}}}"#,
                    #"{"usageMetadata":{"totalTokenCount":-1}}"#] {
            var wire = try GeminiLiveTranslationProtocol(configuration: .init(provider: .gemini), direction: .englishToChinese)
            do { _ = try wire.events(Data(raw.utf8)); Issue.record("Invalid service response was accepted") }
            catch {
                #expect(error is AudioProcessingError)
                #expect(!String(describing: error).contains("fake-key"))
                if raw.contains("401") { #expect(error as? AudioProcessingError == .credential) }
                if raw.contains("429") { #expect(error as? AudioProcessingError == .rateLimited) }
            }
        }
        var wire = try GeminiLiveTranslationProtocol(configuration: .init(provider: .gemini), direction: .englishToChinese)
        let text = Data(#"{"serverContent":{"inputTranscription":{"text":"same"}}}"#.utf8)
        #expect(try wire.events(text) != wire.events(text))
    }
}
