import Foundation

@main struct DDCRoutingRegression {
    static func main() async {
        typealias Routing = DDCDisplayRouting
        let g32 = Routing.Target(displayID: 2, uuid: "G32", name: "G32QC A", serialNumber: 16843009)
        let hp = Routing.Target(displayID: 3, uuid: "HP", name: "HP 27b Curved", serialNumber: 16843009)
        // Sanitized live failure: the HP endpoint is enumerated first; CG lists G32 first.
        let framebuffers: [Routing.Framebuffer] = [
            .init(port: "dispext0", productName: hp.name, serialNumber: hp.serialNumber),
            .init(port: "dispext1", productName: g32.name, serialNumber: g32.serialNumber)
        ]
        let proxies: [Routing.Proxy] = [.init(registryID: 184, port: "dispext0"), .init(registryID: 218, port: "dispext1")]
        for frames in [framebuffers, framebuffers.reversed()] {
            for ports in [proxies, proxies.reversed()] {
                for targets in [[g32, hp], [hp, g32]] {
                    let endpoints = Routing.endpoints(framebuffers: Array(frames), proxies: Array(ports))
                    precondition(Routing.match(targets: targets, endpoints: endpoints) == [2: 218, 3: 184])
                }
            }
        }
        let endpoints = Routing.endpoints(framebuffers: framebuffers, proxies: proxies)
        precondition(Routing.match(targets: [g32, hp], endpoints: [endpoints[0]]) == [3: 184], "An unavailable G32 must never borrow the HP")
        precondition(Routing.match(targets: [g32], endpoints: [endpoints[0]]).isEmpty)
        let duplicate = Routing.Target(displayID: 4, uuid: "another-G32", name: g32.name, serialNumber: g32.serialNumber)
        precondition(Routing.match(targets: [g32, duplicate], endpoints: endpoints).isEmpty)
        precondition(Routing.match(targets: [g32], endpoints: endpoints + [endpoints[1]]).isEmpty)
        precondition(Routing.endpoints(framebuffers: framebuffers + [framebuffers[0]], proxies: [proxies[0]]).isEmpty)
        precondition(Routing.endpoints(framebuffers: framebuffers, proxies: [.init(registryID: 999, port: "unknown")]).isEmpty)
        let replaced = Routing.Target(displayID: 2, uuid: "replacement", name: "Different monitor", serialNumber: 0)
        precondition(Routing.match(targets: [replaced], endpoints: endpoints).isEmpty, "Reused display IDs cannot inherit old routes")
        let uniqueSerial = Routing.Target(displayID: 5, uuid: "unique", name: g32.name, serialNumber: 42)
        precondition(Routing.match(targets: [uniqueSerial], endpoints: endpoints).isEmpty)
        print("PASS: G32/HP failure fixture, all enumeration permutations, missing/duplicate endpoints, conflicting serials and reused IDs")

        var reply: [UInt8] = [0x6E, 0x88, 0x02, 0, 0x10, 0, 0, 100, 0, 57]
        reply.append(reply.reduce(UInt8(0x50), ^))
        precondition(DDCVCPReply.parse(reply, command: 0x10)?.current == 57)
        precondition(DDCVCPReply.parse(reply, command: 0x12) == nil)
        precondition(DDCVCPReply.parse([UInt8](repeating: 0, count: 12), command: 0x10) == nil)
        for index in reply.indices {
            var corrupt = reply
            corrupt[index] ^= 1
            precondition(DDCVCPReply.parse(corrupt, command: 0x10) == nil)
        }
        for (index, value) in [(3, UInt8(1)), (7, 0), (9, 101)] {
            var invalid = reply
            invalid[index] = value
            invalid[10] = invalid.prefix(10).reduce(UInt8(0x50), ^)
            precondition(DDCVCPReply.parse(invalid, command: 0x10) == nil)
        }
        print("PASS: VCP framing, opcode echo, unsupported result, checksum and range validation")

        // Real async service, no configured hardware targets: cancellation must still
        // complete every callback/continuation, without touching any physical monitor.
        let ddc = DDCService.shared
        for _ in 0..<20 {
            async let read = withCheckedContinuation { continuation in
                ddc.readAsync(displayID: 0, command: 0x10) { continuation.resume(returning: $0) }
            }
            async let write = withCheckedContinuation { continuation in
                ddc.writeAsync(displayID: 0, command: 0x10, value: 50) { continuation.resume(returning: $0) }
            }
            ddc.invalidateDisplayMappings()
            let result = await (read, write)
            precondition(result.0 == nil && !result.1)
        }
        print("PASS: real DDC queue invalidation completes cancelled reads and writes safely")
    }
}
