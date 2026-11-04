import Foundation

/// The phone announcing itself for the desktop's Play On: Bonjour through NetService, the
/// way the desktop announces itself through Avahi. NetService is old but is still the
/// one API that publishes a TXT record without a listener of Network's own; the server
/// here is plain sockets, shared with the desktop. Used on the main thread only.
final class BonjourAdvertiser: RemoteAdvertising, @unchecked Sendable {
    private var service: NetService?

    func publish(name: String, type: String, port: UInt16, txt: [String]) {
        DispatchQueue.main.async { [self] in
            service?.stop()
            let service = NetService(domain: "local.", type: type + ".", name: name, port: Int32(port))
            var record: [String: Data] = [:]
            for entry in txt {
                let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { record[parts[0]] = Data(parts[1].utf8) }
            }
            service.setTXTRecord(NetService.data(fromTXTRecord: record))
            service.publish()
            self.service = service
        }
    }

    func withdraw() {
        DispatchQueue.main.async { [self] in
            service?.stop()
            service = nil
        }
    }
}
