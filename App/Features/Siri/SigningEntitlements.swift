import Foundation
import MachO

/// The entitlements this process was actually signed with, read from its own image.
///
/// `INPreferences` throws an Objective-C exception -- which Swift cannot catch, so the app
/// dies at launch -- when the signature lacks `com.apple.developer.siri`. The phone's
/// signing profile has it; a simulator build, or an install signed without that capability,
/// does not. So the Siri calls ask here first.
///
/// Where the entitlements live:
/// - Simulator: Xcode writes them into the main executable's `__TEXT,__entitlements` section
///   (the ad-hoc signature carries none).
/// - Device: the code signature, which the loader keeps mapped as part of `__LINKEDIT`: a
///   big-endian SuperBlob whose entitlements blob (magic `0xfade7171`) is the XML plist.
enum SigningEntitlements {
    static func contains(_ key: String) -> Bool {
        guard let header = _dyld_get_image_header(0) else { return false }
        let slide = _dyld_get_image_vmaddr_slide(0)
        guard let xml = simulatorSection(header) ?? codeSignature(header, slide: slide),
              let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil),
              let entitlements = plist as? [String: Any]
        else { return false }
        return (entitlements[key] as? Bool) == true
    }

    private static func simulatorSection(_ header: UnsafePointer<mach_header>) -> Data? {
        let header64 = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
        var size: UInt = 0
        guard let bytes = getsectiondata(header64, "__TEXT", "__entitlements", &size), size > 0 else {
            return nil
        }
        return Data(bytes: bytes, count: Int(size))
    }

    private static func codeSignature(_ header: UnsafePointer<mach_header>, slide: Int) -> Data? {
        guard header.pointee.magic == MH_MAGIC_64 else { return nil }
        var command = UnsafeRawPointer(header) + MemoryLayout<mach_header_64>.size
        var linkedit: segment_command_64?
        var signature: linkedit_data_command?
        for _ in 0..<header.pointee.ncmds {
            let load = command.loadUnaligned(as: load_command.self)
            if load.cmd == UInt32(LC_SEGMENT_64) {
                let segment = command.loadUnaligned(as: segment_command_64.self)
                let name = withUnsafeBytes(of: segment.segname) {
                    String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
                }
                if name == "__LINKEDIT" { linkedit = segment }
            } else if load.cmd == UInt32(LC_CODE_SIGNATURE) {
                signature = command.loadUnaligned(as: linkedit_data_command.self)
            }
            command += Int(load.cmdsize)
        }
        guard let linkedit, let signature,
              UInt64(signature.dataoff) >= linkedit.fileoff,
              UInt64(signature.dataoff) + UInt64(signature.datasize) <= linkedit.fileoff + linkedit.filesize
        else { return nil }
        let address = slide + Int(linkedit.vmaddr) + Int(UInt64(signature.dataoff) - linkedit.fileoff)
        guard let blob = UnsafeRawPointer(bitPattern: address) else { return nil }
        let size = Int(signature.datasize)
        func word(_ offset: Int) -> Int {
            Int(UInt32(bigEndian: blob.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
        }
        // SuperBlob: magic, length, count, then `count` (type, offset) pairs.
        guard size >= 12, word(0) == 0xfade0cc0 else { return nil }
        let count = word(8)
        guard 12 + count * 8 <= size else { return nil }
        for index in 0..<count {
            let offset = word(12 + index * 8 + 4)
            guard offset + 8 <= size, word(offset) == 0xfade7171 else { continue }
            let length = word(offset + 4)
            guard length > 8, offset + length <= size else { return nil }
            return Data(bytes: blob + offset + 8, count: length - 8)
        }
        return nil
    }
}
