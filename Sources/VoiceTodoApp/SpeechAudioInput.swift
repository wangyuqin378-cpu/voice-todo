import AVFoundation
import VoiceTodoCore

/// The tap buffer is reused by AVAudioEngine. Own a copy until analysis consumes it.
struct SpeechAudioBuffer: @unchecked Sendable { let pcm: AVAudioPCMBuffer }

final class SpeechAudioInput: @unchecked Sendable {
    let stream: AsyncThrowingStream<SpeechAudioBuffer, Error>
    private let continuation: AsyncThrowingStream<SpeechAudioBuffer, Error>.Continuation
    init(capacity: Int = 256) {
        (stream, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(capacity))
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            continuation.finish(throwing: UserFacingError("无法保存本次语音缓冲。")); return
        }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in source.indices {
            guard let from = source[index].mData, let to = target[index].mData else { continue }
            memcpy(to, from, Int(source[index].mDataByteSize))
        }
        if case .dropped = continuation.yield(SpeechAudioBuffer(pcm: copy)) {
            continuation.finish(throwing: UserFacingError("语音模型准备过慢，本次录音不完整，请重试。"))
        }
    }
    func finish() { continuation.finish() }
}
