import Foundation
import Testing
@testable import MusicLogic

@Suite("Signing info")
struct SigningInfoTests {
    @Test func theProfileIsReadFromInsideItsSignature() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Name</key><string>Glass Harbor Distribution</string>
        <key>TeamIdentifier</key><array><string>ABCDE12345</string></array>
        <key>Entitlements</key><dict><key>application-identifier</key><string>ABCDE12345.com.example.music</string></dict>
        </dict></plist>
        """
        // Signature bytes either side, as a real profile has.
        var data = Data([0x30, 0x82, 0x0F, 0x00, 0x06, 0x09])
        data.append(Data(plist.utf8))
        data.append(Data([0xA0, 0x82, 0x0B, 0x00]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID()).mobileprovision")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let profile = try #require(SigningInfo.profile(at: url))
        #expect(profile["Name"] as? String == "Glass Harbor Distribution")
        let entitlements = profile["Entitlements"] as? [String: Any]
        #expect(entitlements?["application-identifier"] as? String == "ABCDE12345.com.example.music")
    }

    @Test func noProfileSaysSo() {
        #expect(SigningInfo.summary.contains("no embedded profile"))
    }
}
