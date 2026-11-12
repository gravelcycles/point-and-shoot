import AVFoundation

enum RecorderError: LocalizedError {
    case cannotAddInput
    case cannotStart(Error?)
    var errorDescription: String? {
        switch self {
        case .cannotAddInput: "The encoder rejected these settings."
        case .cannotStart(let e): e?.localizedDescription ?? "The writer couldn't start."
        }
    }
}

/// AVAssetWriter-based recorder. Everything here runs on the camera's data queue, so the
/// same sample buffers that feed the preview are appended straight to the file — what you
/// see (Log, 10-bit, stabilized) is exactly what's recorded.
final class VideoRecorder {
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStart: CMTime = .invalid
    private var outputURL: URL?
    private(set) var isRecording = false

    func start(videoSettings: [String: Any], audioSettings: [String: Any]?, transform: CGAffineTransform) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PS_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(6))")
            .appendingPathExtension("mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = false

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = true
        video.transform = transform
        guard writer.canAdd(video) else { throw RecorderError.cannotAddInput }
        writer.add(video)

        var audio: AVAssetWriterInput?
        if let audioSettings {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            a.expectsMediaDataInRealTime = true
            if writer.canAdd(a) {
                writer.add(a)
                audio = a
            }
        }

        guard writer.startWriting() else { throw RecorderError.cannotStart(writer.error) }

        self.writer = writer
        self.videoInput = video
        self.audioInput = audio
        self.outputURL = url
        self.sessionStart = .invalid
        self.isRecording = true
    }

    func append(video sampleBuffer: CMSampleBuffer) {
        guard isRecording, let writer, let videoInput, writer.status == .writing else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !sessionStart.isValid {
            writer.startSession(atSourceTime: pts)
            sessionStart = pts
        }
        if videoInput.isReadyForMoreMediaData {
            videoInput.append(sampleBuffer)
        }
    }

    func append(audio sampleBuffer: CMSampleBuffer) {
        guard isRecording, sessionStart.isValid, let writer, let audioInput, writer.status == .writing else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard CMTimeCompare(pts, sessionStart) >= 0 else { return }
        if audioInput.isReadyForMoreMediaData {
            audioInput.append(sampleBuffer)
        }
    }

    func stop(completion: @escaping (URL?, Error?) -> Void) {
        guard isRecording, let writer else {
            completion(nil, nil)
            return
        }
        isRecording = false
        let url = outputURL
        defer {
            self.writer = nil
            self.videoInput = nil
            self.audioInput = nil
        }
        guard sessionStart.isValid else {
            writer.cancelWriting()
            completion(nil, nil)
            return
        }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting {
            completion(writer.status == .completed ? url : nil, writer.error)
        }
    }
}
