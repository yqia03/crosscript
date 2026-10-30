import Foundation
import Testing
@testable import WorkbenchCore

struct AudioSourceTests {
    @Test func explicitMicrophoneKeepsStableIdentityAndNameInHistory() throws {
        let source = AudioSource.microphoneDevice(AudioInputDevice(uid: "usb:meeting-mic", name: "Meeting microphone"))
        let restored = try JSONDecoder().decode(AudioSource.self, from: JSONEncoder().encode(source))
        #expect(restored == source)
        #expect(restored.isMicrophone)
        #expect(try JSONDecoder().decode(AudioSource.self, from: Data(#"{"microphone":{}}"#.utf8)) == .microphone)
        #expect(!AudioSource.system.isMicrophone)
    }
}
