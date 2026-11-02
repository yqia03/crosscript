import AudioToolbox
import Combine
import CoreAudio
import Foundation
import WorkbenchCore

enum MicrophoneDeviceError: LocalizedError {
    case unavailable, routeChanged, bindingFailed, permission, active, destination, stopped
    case invalidFormat, captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return AppLanguage.current.text("所选麦克风不可用。请连接设备并刷新音源列表；未切换到其他麦克风。", "The selected microphone is unavailable. Connect it and refresh audio sources; no other microphone was selected.")
        case .routeChanged:
            return AppLanguage.current.text("麦克风已断开或音频输入发生变化，采集已停止，已保存音频保留在历史中。请重新选择音源后开始新的录音。", "The microphone disconnected or its input changed. Capture stopped and saved audio remains in history. Select an audio source before starting a new recording.")
        case .bindingFailed:
            return AppLanguage.current.text("无法连接所选麦克风，录音未开始。请检查设备后重试。", "Could not bind the selected microphone. Recording did not start. Check the device and try again.")
        case .invalidFormat:
            return AppLanguage.current.text("麦克风返回了无法保存的音频格式，采集已停止；此前保存的音频仍保留。", "The microphone returned an unsupported audio format. Capture stopped; previously saved audio is retained.")
        case .captureFailed(let detail):
            return AppLanguage.current.text("麦克风采集失败，已停止；此前保存的音频仍保留。", "Microphone capture failed and stopped; previously saved audio is retained.") + (detail.isEmpty ? "" : "\n" + detail)
        case .permission:
            return AppLanguage.current.text("请在系统设置的隐私与安全性中允许访问麦克风，然后重新开始录音。", "Allow microphone access in System Settings → Privacy & Security, then start recording again.")
        case .active:
            return AppLanguage.current.text("已有录音正在进行，请先停止当前录音。", "A recording is already in progress. Stop it before starting another.")
        case .destination:
            return AppLanguage.current.text("录音目标已存在，为保留已有资料，本次录音未开始。", "The recording destination already exists. Recording did not start so existing material remains safe.")
        case .stopped:
            return AppLanguage.current.text("当前录音已经结束，请开始新的录音。", "This recording has ended. Start a new recording.")
        }
    }
}

/// Core Audio discovery never opens an input stream or requests permission.
struct MicrophoneDeviceCatalog {
    let devices: () -> [AudioInputDevice]
    let defaultUID: () -> String?

    static let system = MicrophoneDeviceCatalog(devices: { CoreAudioMicrophoneDevices.inputs().map(\.device) }, defaultUID: {
        CoreAudioMicrophoneDevices.defaultInput()?.uid
    })

    func resolve(_ source: AudioSource) throws -> AudioInputDevice {
        let uid: String?
        switch source {
        case .microphone: uid = defaultUID()
        case .microphoneDevice(let device): uid = device.uid
        case .system, .application: throw MicrophoneDeviceError.unavailable
        }
        guard let uid, let device = devices().first(where: { $0.uid == uid }) else { throw MicrophoneDeviceError.unavailable }
        return device
    }
}

@MainActor
final class MicrophoneDeviceList: ObservableObject {
    @Published private(set) var devices: [AudioInputDevice] = []
    @Published private(set) var defaultUID: String?
    func refresh() {
        devices = MicrophoneDeviceCatalog.system.devices()
        defaultUID = MicrophoneDeviceCatalog.system.defaultUID()
    }
}

enum CoreAudioMicrophoneDevices {
    struct Input { let id: AudioDeviceID; let device: AudioInputDevice }

    static func inputs() -> [Input] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !ids.isEmpty else { return [] }
        let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { return [] }
        return ids.compactMap { id in
            guard scalar(id, kAudioDevicePropertyDeviceIsAlive) != 0, inputChannels(id) > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID), !uid.isEmpty,
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Input(id: id, device: AudioInputDevice(uid: uid, name: name))
        }.sorted { $0.device.name.localizedStandardCompare($1.device.name) == .orderedAscending }
    }

    static func defaultInput() -> AudioInputDevice? {
        let id = scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
        return inputs().first { $0.id == id }?.device
    }

    private static func scalar(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var result: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &result) == noErr else { return 0 }
        return result
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &result) == noErr else { return nil }
        // Core Audio transfers ownership of these CFString properties.
        return result?.takeRetainedValue() as String?
    }

    private static func inputChannels(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + $1.mNumberChannels }
    }
}
