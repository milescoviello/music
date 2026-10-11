import AVFoundation
import Foundation
import Synchronization

/// The point where Plexamp's audio chain meets `AVPlayer`.
///
/// `AVPlayer` exposes no Swift-level way to touch samples; `MTAudioProcessingTap` is the
/// only route, and it is a C API with five function-pointer callbacks. It used to be a
/// passthrough that only fed the visualiser. It now **modifies** the audio — gain, EQ,
/// limiter — which is what puts Loudness Leveling and the equaliser on every track,
/// streamed or downloaded, instead of only on downloads through a second engine.
///
/// Every constraint below is real, and getting any of them wrong shows up as silence, a
/// click or a crash rather than as a compile error:
///
/// - The callbacks must be `@convention(c)`, so they **cannot capture** anything. The
///   only channel to Swift state is the `clientInfo` pointer, retained on create and
///   released in `finalize`.
/// - `process` runs on a **real-time audio thread**: no allocation, no locks that wait,
///   no `Task`. The channel-pointer array it hands the chain is allocated up front.
/// - It must call `MTAudioProcessingTapGetSourceAudio` and then work on the buffers in
///   place. A format it does not understand is passed through untouched rather than
///   guessed at — unprocessed audio is a missing feature, misread audio is noise.
/// - The tap is created `PostEffects`, so the visualiser sees what is heard.
enum AudioTap {
    /// Everything one tap needs, reached through `clientInfo`.
    final class Context: @unchecked Sendable {
        let chain: DSPChain
        let spectrum: AudioSampleBuffer?
        /// Cleared on a track that is fading out under the next one, so the visualiser
        /// draws one signal rather than two interleaved in its ring.
        let feedsSpectrum = Atomic<Bool>(true)

        /// Set in `prepare` from the real processing format.
        fileprivate var canProcess = false
        fileprivate var isInterleaved = false
        fileprivate var channelCount = 0
        /// Preallocated so `process` can build the chain's view of the buffer list
        /// without allocating.
        fileprivate let channels: UnsafeMutablePointer<UnsafeMutablePointer<Float>>

        init(chain: DSPChain, spectrum: AudioSampleBuffer?) {
            self.chain = chain
            self.spectrum = spectrum
            channels = .allocate(capacity: DSPChain.maximumChannels)
        }

        deinit {
            channels.deallocate()
        }
    }

    /// Builds the `AVAudioMix` that runs `chain` over `track`, or nil if anything at all
    /// goes wrong.
    ///
    /// Nil rather than throwing, deliberately: playback must never depend on the tap
    /// succeeding, so every caller treats failure as "plays unprocessed" and carries on.
    static func makeMix(
        for track: AVAssetTrack,
        chain: DSPChain,
        spectrum: AudioSampleBuffer?
    ) -> (mix: AVAudioMix, context: Context)? {
        let context = Context(chain: chain, spectrum: spectrum)
        // Retained here, balanced by the release in `finalize`. An unretained pointer is
        // the classic way this crashes minutes into playback.
        let clientInfo = Unmanaged.passRetained(context).toOpaque()

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(clientInfo),
            init: { _, clientInfo, tapStorageOut in
                tapStorageOut.pointee = clientInfo
            },
            finalize: { tap in
                let storage = MTAudioProcessingTapGetStorage(tap)
                let context = Unmanaged<Context>.fromOpaque(storage)
                context.takeUnretainedValue().spectrum?.markStopped()
                context.release()
            },
            prepare: { tap, _, processingFormat in
                // The only place the real format is known: whatever the item decodes to,
                // which is not necessarily the hardware's.
                let storage = MTAudioProcessingTapGetStorage(tap)
                let context = Unmanaged<Context>.fromOpaque(storage).takeUnretainedValue()
                let format = processingFormat.pointee

                let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
                let is32Bit = format.mBitsPerChannel == 32
                context.isInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
                context.channelCount = Int(format.mChannelsPerFrame)
                context.canProcess = isFloat && is32Bit && context.channelCount > 0

                context.chain.prepare(sampleRate: format.mSampleRate, channels: context.channelCount)
                context.spectrum?.sampleRate = format.mSampleRate
            },
            unprepare: nil,
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap,
                    numberFrames,
                    bufferListInOut,
                    flagsOut,
                    nil,
                    numberFramesOut
                )
                guard status == noErr else { return }

                let storage = MTAudioProcessingTapGetStorage(tap)
                let context = Unmanaged<Context>.fromOpaque(storage).takeUnretainedValue()
                let frames = Int(numberFramesOut.pointee)
                let list = UnsafeMutableAudioBufferListPointer(bufferListInOut)

                if context.canProcess, frames > 0 {
                    if context.isInterleaved {
                        if let first = list.first, let data = first.mData {
                            context.chain.processInterleaved(
                                data.assumingMemoryBound(to: Float.self),
                                channels: Int(first.mNumberChannels),
                                frames: frames
                            )
                        }
                    } else {
                        var count = 0
                        for buffer in list where count < DSPChain.maximumChannels {
                            guard let data = buffer.mData else { continue }
                            context.channels[count] = data.assumingMemoryBound(to: Float.self)
                            count += 1
                        }
                        if count > 0 {
                            context.chain.process(
                                UnsafeMutableBufferPointer(start: context.channels, count: count),
                                frames: frames
                            )
                        }
                    }
                }

                // One channel is enough for a spectrum. For interleaved audio that is
                // every sample of every channel, which the analyser tolerates: it reads
                // shape, not exact frequency, from a ring this small.
                if let spectrum = context.spectrum,
                   context.feedsSpectrum.load(ordering: .relaxed),
                   let first = list.first, let data = first.mData {
                    let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                    spectrum.write(data.assumingMemoryBound(to: Float.self), count: count)
                }
            }
        )

        // Imported as a managed optional rather than as `Unmanaged`, so ARC owns the
        // tap and there is no manual release to balance here.
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tap
        )

        guard status == noErr, let tap else {
            // `finalize` will never run, so balance the retain made above.
            Unmanaged<Context>.fromOpaque(clientInfo).release()
            return nil
        }

        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap

        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return (mix, context)
    }
}
