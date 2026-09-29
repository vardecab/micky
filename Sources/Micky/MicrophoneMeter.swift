import AVFoundation
import AudioToolbox
import Combine
import CoreAudio
import Foundation

struct MicrophoneInputDevice: Identifiable, Hashable {
    let uid: String
    let deviceID: AudioDeviceID
    let name: String
    let isSystemDefault: Bool

    var id: String { uid }
}

@MainActor
final class MicrophoneMeter: ObservableObject {
    @Published private(set) var peakDBFS: Double = -60
    @Published private(set) var isRunning = false
    @Published private(set) var isEnabled = false
    @Published private(set) var isMuted = true

    private let engine = AVAudioEngine()
    private var permissionRequestInFlight = false
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var inputDevicesListener: AudioObjectPropertyListenerBlock?
    private var inputMuteListener: AudioObjectPropertyListenerBlock?
    private var monitoredInputDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var smoothedPeak: Float = 0

    private var selectedInputUID: String {
        UserDefaults.standard.string(forKey: "selectedMicrophoneUID") ?? ""
    }

    static func availableInputDevices() -> [MicrophoneInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.stride
        guard count > 0 else { return [] }
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        let status = deviceIDs.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return kAudioHardwareBadDeviceError }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                baseAddress
            )
        }
        guard status == noErr else { return [] }

        let defaultID = systemDefaultInputDeviceID()
        return deviceIDs.compactMap { deviceID in
            guard deviceHasInput(deviceID),
                  let uid = stringProperty(kAudioDevicePropertyDeviceUID, for: deviceID),
                  let name = stringProperty(kAudioObjectPropertyName, for: deviceID) else { return nil }
            return MicrophoneInputDevice(
                uid: uid,
                deviceID: deviceID,
                name: name,
                isSystemDefault: deviceID == defaultID
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func systemDefaultInputName() -> String? {
        let id = systemDefaultInputDeviceID()
        guard id != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return stringProperty(kAudioObjectPropertyName, for: id)
    }

    private let segmentThresholds: [Double] = [
        -42, -39, -36, -33,
        -30, -27, -24, -21, -18, -15, -12, -9,
        -6, -5, -4, -3,
        -2, -1
    ]

    var litSegmentCount: Int {
        segmentThresholds.filter { peakDBFS >= $0 }.count
    }

    var levelDescription: String {
        if peakDBFS < -30 { return "Too quiet" }
        if peakDBFS < -18 { return "Quiet" }
        if peakDBFS < -6 { return "Good call level" }
        if peakDBFS < -1 { return "Loud" }
        return "Near clipping"
    }

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        watchSystemDefaultInput()
        guard !permissionRequestInFlight else { return }
        permissionRequestInFlight = true

        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                self.permissionRequestInFlight = false
                guard granted, self.isEnabled else {
                    self.isEnabled = false
                    self.peakDBFS = -60
                    return
                }
                self.startEngine()
            }
        }
    }

    func stop() {
        isEnabled = false
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        isRunning = false
        peakDBFS = -60
        smoothedPeak = 0
    }

    func selectInputDevice(uid: String) {
        UserDefaults.standard.set(uid, forKey: "selectedMicrophoneUID")
        refreshInputMuteState()
        restartForDefaultInputChange()
    }

    private func startEngine() {
        let input = engine.inputNode
        guard configureInputDevice(input) else {
            isEnabled = false
            return
        }
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            isEnabled = false
            return
        }

        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            guard let channels = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }

            var peak: Float = 0
            for channel in 0..<Int(buffer.format.channelCount) {
                let samples = channels[channel]
                for index in 0..<count {
                    peak = max(peak, abs(samples[index]))
                }
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                // A peak meter reacts quickly and releases gradually so short syllables remain visible.
                self.smoothedPeak = peak > self.smoothedPeak
                    ? peak
                    : self.smoothedPeak * 0.88 + peak * 0.12
                self.peakDBFS = max(-60, 20 * log10(Double(max(self.smoothedPeak, 0.000_001))))
            }
        }

        do {
            try engine.start()
            isRunning = true
        } catch {
            input.removeTap(onBus: 0)
            peakDBFS = -60
            isRunning = false
            isEnabled = false
        }
    }

    private func watchSystemDefaultInput() {
        if defaultInputListener == nil {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.refreshInputMuteState()
                    if self.selectedInputUID.isEmpty {
                        self.restartForDefaultInputChange()
                    }
                }
            }
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, listener
            )
            if status == noErr {
                defaultInputListener = listener
            }
        }

        if inputDevicesListener == nil {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                NotificationCenter.default.post(name: .micMeterInputDevicesChanged, object: nil)
                Task { @MainActor in
                    guard let self, !self.selectedInputUID.isEmpty else { return }
                    self.refreshInputMuteState()
                    self.restartForDefaultInputChange()
                }
            }
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, listener
            )
            if status == noErr {
                inputDevicesListener = listener
            }
        }
        refreshInputMuteState()
    }

    private func refreshInputMuteState() {
        guard let deviceID = selectedInputDeviceID() else {
            isMuted = true
            return
        }

        if deviceID != monitoredInputDeviceID {
            removeInputMuteListener()
            monitoredInputDeviceID = deviceID
            addInputMuteListener(for: deviceID)
        }

        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muteValue: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        let muteStatus = AudioObjectGetPropertyData(
            deviceID,
            &muteAddress,
            0,
            nil,
            &muteSize,
            &muteValue
        )
        isMuted = muteStatus == noErr && muteValue != 0
    }

    private func selectedInputDeviceID() -> AudioDeviceID? {
        let uid = selectedInputUID
        if !uid.isEmpty, let selected = Self.availableInputDevices().first(where: { $0.uid == uid }) {
            return selected.deviceID
        }
        let defaultID = Self.systemDefaultInputDeviceID()
        return defaultID == AudioDeviceID(kAudioObjectUnknown) ? nil : defaultID
    }

    private func configureInputDevice(_ input: AVAudioInputNode) -> Bool {
        // AVAudioEngine already follows the system default. Setting the HAL
        // device explicitly in this case can prevent its input tap from starting.
        guard !selectedInputUID.isEmpty else { return true }
        guard let deviceID = selectedInputDeviceID(), let audioUnit = input.audioUnit else { return false }
        guard deviceID != Self.systemDefaultInputDeviceID() else { return true }
        var selectedDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &selectedDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        return status == noErr
    }

    private func addInputMuteListener(for deviceID: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshInputMuteState()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, listener)
        if status == noErr {
            inputMuteListener = listener
        }
    }

    private func removeInputMuteListener() {
        guard let inputMuteListener, monitoredInputDeviceID != AudioDeviceID(kAudioObjectUnknown) else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(monitoredInputDeviceID, &address, .main, inputMuteListener)
        self.inputMuteListener = nil
    }

    private func restartForDefaultInputChange() {
        guard isEnabled else { return }
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRunning = false
        }
        smoothedPeak = 0
        peakDBFS = -60
        startEngine()
    }

    private static func systemDefaultInputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID
        )
        return status == noErr ? deviceID : AudioDeviceID(kAudioObjectUnknown)
    }

    private static func deviceHasInput(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr && dataSize > 0
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
        return status == noErr ? value as String : nil
    }
}
