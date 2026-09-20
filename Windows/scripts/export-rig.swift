// Compile with unchanged Source/Sprites.swift, Source/Rig.swift and Source/Motion.swift on macOS.
// This exports the exact Swift-baked 20-channel masks, not re-created regions.
import AppKit
import ImageIO
@main struct ExportRig {
 static func main() throws {
  let out = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
  try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
  let sprites = try Sprites(url: URL(fileURLWithPath: CommandLine.arguments[1]))
  func png(_ image: CGImage, _ name: String) {
   let dst = CGImageDestinationCreateWithURL(out.appendingPathComponent(name).appendingPathExtension("png") as CFURL, "public.png" as CFString, 1, nil)!
   CGImageDestinationAddImage(dst, image, nil); precondition(CGImageDestinationFinalize(dst))
  }
  var sizes: [String: [Int]] = [:]
  for pose in Pose.allCases { png(sprites[pose], "\(pose)"); sizes["\(pose)"] = [sprites[pose].width, sprites[pose].height] }
  var result: [String: Any] = [:]
  for (key, rig) in CatRigs.build(sprites) {
   png(rig.base, key + "-base")
   for (i, bytes) in rig.packedMaps().enumerated() {
    // Store packed channels as raw RGBA: PNG alpha/color conversion would corrupt mask values.
    try Data(bytes).write(to: out.appendingPathComponent("\(key)-map\(i).rgba"))
   }
   result[key] = ["width": rig.width, "height": rig.height, "rest": rig.restParams(frame: rig.base),
    "bends": rig.bendSlots.mapValues { ["slot": $0.slot, "along": $0.along] as [String: Any] },
    "shifts": rig.shiftSlots, "scales": rig.scaleSlots]
  }
  let rigs = CatRigs.build(sprites)
  let motion = CatMotion(rigs: rigs, sprites: sprites, seed: 42)
  let reference = rigs.keys.sorted().reduce(into: [String: [Float]]()) { $0[$1] = motion.params(for: $1, opacity: 1) }
  try JSONSerialization.data(withJSONObject: reference, options: [.sortedKeys]).write(to: out.appendingPathComponent("motion-reference.json"))
  let manifest: [String: Any] = ["pad": rigPad, "sizes": sizes, "rigs": result,
   "source": "Source/Sprites.swift + Source/Rig.swift (unchanged)",
   "legs": CatRigs.legs.map { ["name": $0.name, "length": $0.length] as [String: Any] }]
  try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("rig.json"))
 }
}
