import Foundation
import Testing
@testable import WorkbenchCore

struct ConfigurationValidationTests {
    // Run this regression in release as well as debug: the original validation
    // rejected valid saved profiles only when the Core module was optimized.
    @Test func savedProfilesAndEditedTextHistoryRemainReadable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let providerJSON = Data(#"{"version":1,"defaults":{"textID":"EA076964-954F-47F2-8FBE-AFF6FA2D787B","pdfID":"EA076964-954F-47F2-8FBE-AFF6FA2D787B"},"profiles":[{"id":"EA076964-954F-47F2-8FBE-AFF6FA2D787B","name":"Controlled compatible service","baseURL":"https://controlled.invalid/v1","model":"editable-model-id","credentialReference":{"profileID":"EA076964-954F-47F2-8FBE-AFF6FA2D787B","target":"https://controlled.invalid/v1"}}]}"#.utf8)
        let providerFile = root.appendingPathComponent("provider-configurations.json")
        try providerJSON.write(to: providerFile)
        let document = try JSONDecoder().decode(ProviderConfigurationDocument.self, from: providerJSON)
        let profile = try #require(document.profiles.first)
        let loaded = try? ProviderConfigurationStore(root: root).load()
        #expect(loaded?.profiles == document.profiles)
        #expect(loaded?.defaults == document.defaults)

        let audioJSON = Data(#"{"version":2,"selected":"aiHubMix","profiles":[{"provider":"aiHubMix","baseURL":"https://aihubmix.com/v1","model":"whisper-large-v3-turbo"}]}"#.utf8)
        let audioFile = root.appendingPathComponent("audio-configuration.json")
        try audioJSON.write(to: audioFile)
        let audio = try RecordingStore(root: root).loadAudioSettings().configuration(for: .aiHubMix)
        #expect((try? audio.validated()) == audio)

        var result = TextTranslationResult(input: "Original text", direction: .englishToChinese, provider: profile.snapshot)
        result.generatedText = "原始译文"; result.currentText = "用户保留的修改"; result.status = .completed
        let materialID = UUID()
        let materialDirectory = root.appendingPathComponent("TextMaterials").appendingPathComponent(materialID.uuidString)
        try FileManager.default.createDirectory(at: materialDirectory, withIntermediateDirectories: true)
        let materialFile = materialDirectory.appendingPathComponent("material.json")
        let object: [String: Any] = ["schemaVersion": 2, "id": materialID.uuidString, "createdAt": 700000000, "updatedAt": 700000000, "inputDraft": result.input, "direction": "englishToChinese", "currentResult": try JSONSerialization.jsonObject(with: JSONEncoder().encode(result))]
        let materialBytes = try JSONSerialization.data(withJSONObject: object)
        try materialBytes.write(to: materialFile)
        let history = try TextWorkspaceStore(root: root).load()
        #expect(history.library.history.map(\.result) == [result])
        #expect(history.library.workspace.translation == "用户保留的修改")
        #expect(history.unreadableIDs.isEmpty)
        #expect(try Data(contentsOf: providerFile) == providerJSON)
        #expect(try Data(contentsOf: audioFile) == audioJSON)
        #expect(try Data(contentsOf: materialFile) == materialBytes)
    }
}
