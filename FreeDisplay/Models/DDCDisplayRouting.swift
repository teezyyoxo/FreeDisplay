import Foundation

/// Physical identities used for DDC routing. Enumeration order is never identity.
enum DDCDisplayRouting {
    struct Target: Equatable, Sendable {
        let displayID: UInt32
        let uuid: String
        let name: String
        let serialNumber: UInt32
    }

    struct Endpoint: Equatable, Sendable {
        let registryID: UInt64
        let productName: String
        let serialNumber: UInt32
    }

    struct Framebuffer: Sendable {
        let port: String
        let productName: String
        let serialNumber: UInt32
    }

    struct Proxy: Sendable {
        let registryID: UInt64
        let port: String
    }

    static func endpoints(framebuffers: [Framebuffer], proxies: [Proxy]) -> [Endpoint] {
        proxies.compactMap { proxy in
            let candidates = framebuffers.filter { $0.port == proxy.port }
            guard candidates.count == 1, let framebuffer = candidates.first else { return nil }
            return Endpoint(registryID: proxy.registryID, productName: framebuffer.productName,
                            serialNumber: framebuffer.serialNumber)
        }
    }

    /// Require a unique match in both directions, considering the complete set.
    /// Identical/unknown monitors deliberately use software dimming instead of guessing.
    static func match(targets: [Target], endpoints: [Endpoint]) -> [UInt32: UInt64] {
        func matches(_ target: Target, _ endpoint: Endpoint) -> Bool {
            let name = target.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let product = endpoint.productName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !name.isEmpty, name == product else { return false }
            return target.serialNumber == 0 || endpoint.serialNumber == 0
                || target.serialNumber == endpoint.serialNumber
        }

        var result: [UInt32: UInt64] = [:]
        for target in targets {
            let candidates = endpoints.filter { matches(target, $0) }
            guard candidates.count == 1, let endpoint = candidates.first,
                  targets.filter({ matches($0, endpoint) }).count == 1 else { continue }
            result[target.displayID] = endpoint.registryID
        }
        return result
    }
}

enum DDCVCPReply {
    /// Reject null, stale, unsupported and corrupt replies before enabling hardware control.
    static func parse(_ bytes: [UInt8], command: UInt8) -> (current: UInt16, max: UInt16)? {
        guard bytes.count >= 11, bytes[0] == 0x6E, bytes[1] == 0x88,
              bytes[2] == 0x02, bytes[3] == 0, bytes[4] == command,
              bytes.prefix(11).reduce(UInt8(0x50), ^) == 0 else { return nil }
        let maximum = (UInt16(bytes[6]) << 8) | UInt16(bytes[7])
        let current = (UInt16(bytes[8]) << 8) | UInt16(bytes[9])
        guard maximum > 0, current <= maximum else { return nil }
        return (current, maximum)
    }
}
