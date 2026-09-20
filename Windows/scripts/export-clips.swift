// macOS-only HEVC-with-alpha decoder. Build via convert-assets.py.
import Foundation
import AVFoundation
import CoreVideo

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
let args = CommandLine.arguments
if args.count < 2 { fail("usage: export-clips INPUT.mov [--inspect]") }
let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
guard let track = asset.tracks(withMediaType: .video).first else { fail("no video track") }
let size = track.naturalSize
let width = Int(size.width), height = Int(size.height)
if args.contains("--inspect") {
    print("{\"width\":\(width),\"height\":\(height),\"fps\":\(track.nominalFrameRate),\"duration\":\(asset.duration.seconds)}")
    exit(0)
}
do {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else { fail("cannot read: \(String(describing: reader.error))") }
    var frames = 0, alphaMin = 255, alphaMax = 0
    while let sample = output.copyNextSampleBuffer() {
        guard let pixel = CMSampleBufferGetImageBuffer(sample) else { fail("missing pixel buffer") }
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        guard let base = CVPixelBufferGetBaseAddress(pixel) else { fail("missing pixels") }
        let stride = CVPixelBufferGetBytesPerRow(pixel)
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let alpha = Int(row[x * 4 + 3])
                alphaMin = min(alphaMin, alpha); alphaMax = max(alphaMax, alpha)
            }
            try FileHandle.standardOutput.write(contentsOf: Data(bytes: row, count: width * 4))
        }
        CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
        frames += 1
    }
    guard reader.status == .completed else { fail("decode failed: \(String(describing: reader.error))") }
    guard frames > 1 && alphaMin == 0 && alphaMax == 255 else { fail("invalid alpha or frame count") }
    FileHandle.standardError.write(Data("{\"frames\":\(frames),\"alphaMin\":\(alphaMin),\"alphaMax\":\(alphaMax)}\n".utf8))
} catch { fail("\(error)") }
