import AVFoundation
import Testing
@testable import TranslationWorkbench

@Suite(.serialized) @MainActor
struct TextSystemToolsTests {
    @Test func dictionarySensesHaveSeparateLinesWithoutChangingWording() {
        let source = "word noun 1 first meaning 2 second meaning 3 third meaning"
        #expect(DictionaryDefinitionLayout.format(source) == "word \nnoun \n1 first meaning \n2 second meaning \n3 third meaning")
        #expect(DictionaryDefinitionLayout.format("A. noun ① first ② second B. verb ① act") == "A. noun \n① first \n② second \nB. verb \n① act")
        let grouped = "A. noun 1. first sense 2. second sense B. verb 1. third sense 2. fourth sense"
        #expect(DictionaryDefinitionLayout.format(grouped) == "A. noun \n1. first sense \n2. second sense \nB. verb \n1. third sense \n2. fourth sense")
        let prose = "In 2026, version 1.2 costs 3 dollars. Example: 42 items."
        #expect(DictionaryDefinitionLayout.format(prose) == prose)
        #expect(DictionaryDefinitionLayout.format("Mix 1 cup with 2 cups of water.") == "Mix 1 cup with 2 cups of water.")
        #expect(DictionaryDefinitionLayout.format("词语 1、第一义 2、第二义") == "词语 \n1、第一义 \n2、第二义")
        let multiline = "word\n1 first\n2 second"
        #expect(DictionaryDefinitionLayout.format(multiline) == multiline)
    }
    @Test func delayedSpeechCallbacksCannotStopNewUtteranceState() async {
        let tools = TextSystemTools(), synthesizer = AVSpeechSynthesizer()
        let old = AVSpeechUtterance(string: "Not played"), current = AVSpeechUtterance(string: "Also not played")
        tools.beginSpeech(old); tools.stop(); tools.beginSpeech(current)
        tools.speechSynthesizer(synthesizer, didCancel: old)
        tools.speechSynthesizer(synthesizer, didFinish: old)
        await Task.yield(); #expect(tools.speaking)
        tools.speechSynthesizer(synthesizer, didFinish: current)
        await Task.yield(); #expect(!tools.speaking)
    }
}
