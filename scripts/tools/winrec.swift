// winrec <pid> <out.mov> <seconds>
// Records one app window (by owner pid) with ScreenCaptureKit, even if other
// windows cover it. Used to film the Pitwall demo without touching the screen.
import Foundation
import AppKit
import ScreenCaptureKit
import AVFoundation
import CoreMedia

let args = CommandLine.arguments
guard args.count == 4, let pid = Int32(args[1]), let secs = Double(args[3]) else {
    fputs("usage: winrec <pid> <out.mov> <seconds>\n", stderr); exit(2)
}
let out = URL(fileURLWithPath: args[2])
try? FileManager.default.removeItem(at: out)

final class Recorder: NSObject, SCStreamOutput {
    var writer: AVAssetWriter!
    var input: AVAssetWriterInput!
    var started = false
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid else { return }
        // Skip frames without content (idle/blank status).
        if let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = att.first?[.status] as? Int, SCFrameStatus(rawValue: raw) != .complete { return }
        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: sb.presentationTimeStamp)
            started = true
        }
        if input.isReadyForMoreMediaData { input.append(sb) }
    }
}

_ = NSApplication.shared // initializes the window server connection
let rec = Recorder()
var stream: SCStream?
Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let win = content.windows.filter({ $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 300 })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            fputs("no window for pid \(pid)\n", stderr); exit(1)
        }
        let cfg = SCStreamConfiguration()
        cfg.width = Int(win.frame.width * 2)
        cfg.height = Int(win.frame.height * 2)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.showsCursor = false
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.queueDepth = 8
        rec.writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        rec.input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: cfg.width, AVVideoHeightKey: cfg.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 24_000_000, AVVideoExpectedSourceFrameRateKey: 60],
        ])
        rec.input.expectsMediaDataInRealTime = true
        rec.writer.add(rec.input)
        let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: win), configuration: cfg, delegate: nil)
        try s.addStreamOutput(rec, type: .screen, sampleHandlerQueue: DispatchQueue(label: "rec"))
        try await s.startCapture()
        stream = s
        print("recording \(Int(win.frame.width))x\(Int(win.frame.height)) for \(secs)s"); fflush(stdout)
        try await Task.sleep(nanoseconds: UInt64(secs * 1e9))
        try await s.stopCapture()
        rec.input.markAsFinished()
        await rec.writer.finishWriting()
        print("wrote \(out.path)")
    } catch { fputs("winrec: \(error)\n", stderr); exit(1) }
    exit(0)
}
RunLoop.main.run()
