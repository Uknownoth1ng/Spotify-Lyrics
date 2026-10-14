import AVFoundation
import CoreAudio
import AudioToolbox

final class SystemAudioCaptureService: @unchecked Sendable {
    enum CaptureState: Sendable { case idle, capturing, error(String) }

    private(set) var state: CaptureState = .idle

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?

    private let outputSampleRate: Double = 16000
    private let outputChannels: Int = 1
    private var systemSampleRate: Double = 48000
    private var systemChannels: Int = 2

    private var ringBuffer: [Float] = []
    private let ringCapacity: Int = 16000 * 60 * 5 // 5 minutes at 16kHz mono
    private var writeIndex: Int = 0
    private var availableFrames: Int = 0
    private let bufferLock = NSLock()
    private var totalFramesWritten: Int = 0

    private var resampleRatio: Double { outputSampleRate / systemSampleRate }

    /// Streaming output. Called on the audio IO thread with mono 16 kHz PCM
    /// chunks suitable for `AVAudioPCMBuffer` consumption. The closure must
    /// be cheap; avoid blocking the audio thread.
    var onPCMChunk: (@Sendable (_ samples: [Float], _ audioTimeMs: Int, _ isVoice: Bool) -> Void)?

    /// RMS amplitude threshold for voice activity detection. Spotify podcasts
    /// at 50 % system volume measure ~0.005–0.015 RMS in our testing, so a
    /// 0.004 floor keeps quiet narration above the threshold without firing
    /// on hum.
    var vadEnergyThreshold: Float = 0.004

    func startCapture() throws {
        guard state.isIdle else { return }

        if #available(macOS 14.2, *) {
            try startCoreAudioTap()
        } else {
            state = .error("Requires macOS 14.2+")
            throw CaptureError.unsupportedOS
        }
    }

    func stopCapture() {
        guard case .capturing = state else { return }

        if let ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if #available(macOS 14.2, *) {
            if tapID != kAudioObjectUnknown {
                AudioHardwareDestroyProcessTap(tapID)
            }
        }

        tapID = kAudioObjectUnknown
        aggregateDeviceID = kAudioObjectUnknown
        ioProcID = nil
        state = .idle
    }

    func flushChunk(maxSeconds: TimeInterval) -> URL? {
        bufferLock.lock()
        let framesToRead = min(availableFrames, Int(maxSeconds * outputSampleRate))
        guard framesToRead > 0 else {
            bufferLock.unlock()
            return nil
        }

        var samples = [Float](repeating: 0, count: framesToRead)
        let readStart = (writeIndex - availableFrames + ringCapacity) % ringCapacity
        for i in 0..<framesToRead {
            samples[i] = ringBuffer[(readStart + i) % ringCapacity]
        }
        availableFrames -= framesToRead
        bufferLock.unlock()

        return writeWAV(samples: samples, sampleRate: outputSampleRate)
    }

    func clearBuffer() {
        bufferLock.lock()
        availableFrames = 0
        bufferLock.unlock()
    }

    // MARK: - Private

    @available(macOS 14.2, *)
    private func startCoreAudioTap() throws {
        ringBuffer = [Float](repeating: 0, count: ringCapacity)
        writeIndex = 0
        availableFrames = 0
        totalFramesWritten = 0

        systemSampleRate = Self.defaultOutputSampleRate()
        systemChannels = Self.defaultOutputChannels()

        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.muteBehavior = .unmuted

        var tapObjectID: AudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &tapObjectID)
        guard tapStatus == noErr else {
            state = .error("Failed to create audio tap: \(tapStatus)")
            throw CaptureError.tapCreationFailed(tapStatus)
        }
        tapID = tapObjectID

        let tapUIDString = tapDescription.uuid.uuidString

        let aggregateDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "SpotLyrics-LiveCapture",
            kAudioAggregateDeviceUIDKey as String: "com.spotlyrics.live-capture-\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [[
                kAudioSubTapUIDKey as String: tapUIDString,
                kAudioSubTapDriftCompensationKey as String: true
            ]]
        ]

        var aggDeviceID: AudioObjectID = kAudioObjectUnknown
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &aggDeviceID)
        guard aggStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
            state = .error("Failed to create aggregate device: \(aggStatus)")
            throw CaptureError.aggregateDeviceFailed(aggStatus)
        }
        aggregateDeviceID = aggDeviceID

        var procID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcID(
            aggregateDeviceID,
            Self.ioProc,
            Unmanaged.passUnretained(self).toOpaque(),
            &procID
        )
        guard ioStatus == noErr, let procID else {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            aggregateDeviceID = kAudioObjectUnknown
            tapID = kAudioObjectUnknown
            state = .error("Failed to create IO proc: \(ioStatus)")
            throw CaptureError.ioProcFailed(ioStatus)
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggregateDeviceID, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            ioProcID = nil
            aggregateDeviceID = kAudioObjectUnknown
            tapID = kAudioObjectUnknown
            state = .error("Failed to start audio device: \(startStatus)")
            throw CaptureError.startFailed(startStatus)
        }

        state = .capturing
    }

    // PLACEHOLDER_IOPROC

    private static let ioProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, clientData in
        guard let clientData else { return noErr }
        let service = Unmanaged<SystemAudioCaptureService>.fromOpaque(clientData).takeUnretainedValue()
        let bufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))

        for buffer in bufferList {
            guard let data = buffer.mData else { continue }
            let floatCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let floatPtr = data.assumingMemoryBound(to: Float.self)
            let channels = Int(buffer.mNumberChannels)

            service.processAudioBuffer(floatPtr, frameCount: floatCount / max(1, channels), channels: channels)
        }
        return noErr
    }

    private func processAudioBuffer(_ samples: UnsafePointer<Float>, frameCount: Int, channels: Int) {
        let ratio = resampleRatio
        let outputFrames = Int(Double(frameCount) * ratio)
        guard outputFrames > 0 else { return }

        var resampled = [Float](repeating: 0, count: outputFrames)
        for i in 0..<outputFrames {
            let srcIndex = min(Int(Double(i) / ratio), frameCount - 1)
            var sample: Float = 0
            for ch in 0..<min(channels, systemChannels) {
                sample += samples[srcIndex * channels + ch]
            }
            sample /= Float(max(1, min(channels, systemChannels)))
            resampled[i] = sample
        }

        let chunkStartFrame: Int
        bufferLock.lock()
        chunkStartFrame = totalFramesWritten
        for sample in resampled {
            ringBuffer[writeIndex] = sample
            writeIndex = (writeIndex + 1) % ringCapacity
            if availableFrames < ringCapacity {
                availableFrames += 1
            }
        }
        totalFramesWritten += outputFrames
        bufferLock.unlock()

        if let onPCMChunk {
            var sumSquares: Float = 0
            var peak: Float = 0
            for sample in resampled {
                sumSquares += sample * sample
                peak = max(peak, abs(sample))
            }
            let rms = sqrt(sumSquares / Float(max(1, outputFrames)))
            let isVoice = rms >= vadEnergyThreshold
            let audioTimeMs = Int(Double(chunkStartFrame) * 1000.0 / outputSampleRate)

            // Heartbeat log every ~3s so the user can see whether the tap is
            // actually receiving audio when nothing reaches the UI.
            chunksSinceLastLog += 1
            framesSinceLastLog += outputFrames
            voiceFramesSinceLastLog += isVoice ? outputFrames : 0
            peakRMSSinceLastLog = max(peakRMSSinceLastLog, rms)
            peakSampleSinceLastLog = max(peakSampleSinceLastLog, peak)
            if framesSinceLastLog >= Int(outputSampleRate * 3) {
                let voicePct = Double(voiceFramesSinceLastLog) / Double(framesSinceLastLog) * 100
                NSLog("SpotLyrics Tap: %.1fs audio, peak=%.4f maxRMS=%.4f voice=%.0f%% threshold=%.4f",
                      Double(framesSinceLastLog) / outputSampleRate,
                      peakSampleSinceLastLog, peakRMSSinceLastLog, voicePct, vadEnergyThreshold)
                framesSinceLastLog = 0
                voiceFramesSinceLastLog = 0
                peakRMSSinceLastLog = 0
                peakSampleSinceLastLog = 0
                chunksSinceLastLog = 0
            }
            onPCMChunk(resampled, audioTimeMs, isVoice)
        }
    }

    private var chunksSinceLastLog: Int = 0
    private var framesSinceLastLog: Int = 0
    private var voiceFramesSinceLastLog: Int = 0
    private var peakRMSSinceLastLog: Float = 0
    private var peakSampleSinceLastLog: Float = 0

    private func writeWAV(samples: [Float], sampleRate: Double) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spotlyrics-live-\(UUID().uuidString).wav")

        let frameCount = samples.count
        let bytesPerSample = 2
        let dataSize = frameCount * bytesPerSample
        let fileSize = 44 + dataSize

        var data = Data(capacity: fileSize)
        data.append(contentsOf: "RIFF".utf8)
        data.append(UInt32(fileSize - 8).littleEndianBytes)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(UInt32(16).littleEndianBytes)
        data.append(UInt16(1).littleEndianBytes) // PCM
        data.append(UInt16(1).littleEndianBytes) // mono
        data.append(UInt32(sampleRate).littleEndianBytes)
        data.append(UInt32(sampleRate * Double(bytesPerSample)).littleEndianBytes)
        data.append(UInt16(bytesPerSample).littleEndianBytes)
        data.append(UInt16(16).littleEndianBytes) // bits per sample
        data.append(contentsOf: "data".utf8)
        data.append(UInt32(dataSize).littleEndianBytes)

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16 = Int16(clamped * 32767)
            data.append(int16.littleEndianBytes)
        }

        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    // PLACEHOLDER_HELPERS

    private static func defaultOutputSampleRate() -> Double {
        var deviceID = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)

        var sampleRate: Float64 = 48000
        address.mSelector = kAudioDevicePropertyNominalSampleRate
        size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)
        return sampleRate
    }

    private static func defaultOutputChannels() -> Int {
        var deviceID = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)

        address.mSelector = kAudioDevicePropertyStreamConfiguration
        address.mScope = kAudioDevicePropertyScopeInput
        var listSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &listSize)
        guard listSize > 0 else { return 2 }

        let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(listSize))
        defer { bufferListPtr.deallocate() }
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &listSize, bufferListPtr)
        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPtr)
        var channels = 0
        for buf in bufferList { channels += Int(buf.mNumberChannels) }
        return max(1, channels)
    }

    enum CaptureError: Error {
        case unsupportedOS
        case tapCreationFailed(OSStatus)
        case aggregateDeviceFailed(OSStatus)
        case ioProcFailed(OSStatus)
        case startFailed(OSStatus)
    }
}

extension SystemAudioCaptureService.CaptureState {
    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }
}

private extension UInt32 {
    var littleEndianBytes: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: 4)
    }
}

private extension UInt16 {
    var littleEndianBytes: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: 2)
    }
}

private extension Int16 {
    var littleEndianBytes: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: 2)
    }
}
