import Foundation
import Combine
import os
import CoreGraphics
import IOKit
import IOKit.i2c
import IOKit.graphics

@_silgen_name("CGDisplayIOServicePort")
private func CGDisplayIOServicePort(_ display: CGDirectDisplayID) -> io_service_t

/// DDC/CI I2C communication service for external displays.
/// Supports two hardware paths:
///   - ARM64 (Apple Silicon): IOAVService via DCPAVServiceProxy
///   - x86_64 (Intel):        IOFramebuffer I2C via IOFBCopyI2CInterfaceForBus
/// All I2C operations run on a private background queue to avoid blocking UI.
final class DDCService: ObservableObject, @unchecked Sendable {
    static let shared = DDCService()

    // VCP feature codes (DDC/CI standard)
    static let brightnessVCP: UInt8 = 0x10
    static let contrastVCP: UInt8   = 0x12
    static let powerVCP: UInt8      = 0xD6

    private let ddcQueue = DispatchQueue(label: "com.freedisplay.ddc", qos: .userInitiated)

    // MARK: - VCP Read Cache (5-second TTL)

    private struct VCPCacheEntry {
        let current: UInt16
        let max: UInt16
        let timestamp: Date
        var isExpired: Bool { Date().timeIntervalSince(timestamp) > 5.0 }
    }

    private var vcpCache: [CGDirectDisplayID: [UInt8: VCPCacheEntry]] = [:]
    private let cacheLock = NSLock()

    // A configuration generation also cancels queued work from the previous topology.
    private let routingLock = NSLock()
    private var targets: [DDCDisplayRouting.Target] = []
    private var generation: UInt64 = 0
    private static let log = Logger(subsystem: "com.freedisplay.app", category: "ddc-routing")

    private init() {}

    var configurationGeneration: UInt64 { routingLock.withLock { generation } }

    func updateDisplayTargets(_ newTargets: [DDCDisplayRouting.Target]) {
        routingLock.withLock {
            targets = newTargets
            generation &+= 1
            cacheLock.withLock { vcpCache.removeAll() }
        }
    }

    /// Called immediately at the start of reconfiguration, before main-actor refresh.
    func invalidateDisplayMappings() {
        updateDisplayTargets([])
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        routingLock.withLock { generation == token }
    }

    // MARK: - ARM64 IORegistry identity matching

#if arch(arm64)
    /// An owned connection for one transaction. Never retain a port assignment across
    /// reconnects: DCP proxies can survive while the physical monitor behind them changes.
    private final class AVConnection {
        let service: IOAVServiceRef
        init(_ service: IOAVServiceRef) { self.service = service }
        deinit { Unmanaged<AnyObject>.fromOpaque(service).release() }
    }

    private func properties(_ entry: io_registry_entry_t) -> [String: Any] {
        var value: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &value, kCFAllocatorDefault, 0) == KERN_SUCCESS
        else { return [:] }
        return value?.takeRetainedValue() as? [String: Any] ?? [:]
    }

    private func registryName(_ entry: io_registry_entry_t) -> String? {
        var name = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &name) == KERN_SUCCESS else { return nil }
        return String(decoding: name.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func entries(matching className: String) -> [io_service_t] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [io_service_t] = []
        var entry = IOIteratorNext(iterator)
        while entry != IO_OBJECT_NULL {
            result.append(entry)
            entry = IOIteratorNext(iterator)
        }
        return result
    }

    /// The endpoint explicitly names its framebuffer port, e.g.
    /// dispext1:dcpav-service-epic:0. Its identity is on the sibling framebuffer,
    /// not on the AV proxy's ancestors. Never associate siblings by iterator order.
    private func framebufferPort(for entry: io_service_t) -> String? {
        var current = entry
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        for _ in 0..<16 {
            if let name = registryName(current), let range = name.range(of: ":dcpav-service-epic:") {
                return String(name[..<range.lowerBound])
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS,
                  parent != IO_OBJECT_NULL else { return nil }
            IOObjectRelease(current)
            current = parent
        }
        return nil
    }

    private func findAVService(for displayID: CGDirectDisplayID) -> AVConnection? {
        let currentTargets = routingLock.withLock { targets }
        guard currentTargets.contains(where: { $0.displayID == displayID }) else { return nil }
        let framebuffers = entries(matching: "IOMobileFramebufferShim") + entries(matching: "AppleCLCD2")
        let proxies = entries(matching: "DCPAVServiceProxy")
        defer { (framebuffers + proxies).forEach { IOObjectRelease($0) } }

        var framebufferIdentities: [DDCDisplayRouting.Framebuffer] = []
        // Some registry classes inherit from one another; visit each entry once.
        for framebuffer in Set(framebuffers) {
            guard let attributes = properties(framebuffer)["DisplayAttributes"] as? [String: Any],
                  let product = attributes["ProductAttributes"] as? [String: Any] else { continue }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(framebuffer, kIOServicePlane, &parent) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(parent) }
            guard let port = registryName(parent) else { continue }
            guard let name = product["ProductName"] as? String else { continue }
            framebufferIdentities.append(.init(port: port, productName: name,
                                               serialNumber: (product["SerialNumber"] as? NSNumber)?.uint32Value ?? 0))
        }

        var proxyIdentities: [DDCDisplayRouting.Proxy] = []
        var entriesByID: [UInt64: io_service_t] = [:]
        for proxy in proxies {
            guard properties(proxy)["Location"] as? String == "External",
                  let port = framebufferPort(for: proxy) else { continue }
            var registryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(proxy, &registryID) == KERN_SUCCESS else { continue }
            proxyIdentities.append(.init(registryID: registryID, port: port))
            entriesByID[registryID] = proxy
        }
        let endpoints = DDCDisplayRouting.endpoints(framebuffers: framebufferIdentities, proxies: proxyIdentities)
        let routes = DDCDisplayRouting.match(targets: currentTargets, endpoints: endpoints)
        guard let registryID = routes[displayID], let entry = entriesByID[registryID],
              let service = IOAVServiceCreateWithService(kCFAllocatorDefault, entry) else {
            Self.log.error("No unique physical DDC endpoint for display \(displayID); using software brightness")
            return nil
        }
        Self.log.debug("Verified display \(displayID) -> registry \(registryID)")
        return AVConnection(service)
    }

    /// ARM64 DDC write: send a Set VCP command via IOAVService.
    /// Buffer layout (bytes sent after the device address / offset arguments):
    ///   [0x84, 0x03, vcpCode, valueHigh, valueLow, checksum]
    /// Checksum includes the destination (0x6E), source (0x51) and payload.
    private func arm64Write(displayID: CGDirectDisplayID, command: UInt8, value: UInt16, token: UInt64) -> Bool {
        guard let connection = findAVService(for: displayID) else { return false }
        defer { withExtendedLifetime(connection) {} }
        let avService = connection.service

        let valueHigh = UInt8((value >> 8) & 0xFF)
        let valueLow  = UInt8(value & 0xFF)
        // Checksum seed: 0x50 = 0x6E (DDC destination) XOR 0x51 (sub-address used by IOAVServiceWriteI2C)
        // then XOR with each byte in the payload.
        var checksum  = UInt8(0x6E ^ 0x51)
        let payload: [UInt8] = [0x84, 0x03, command, valueHigh, valueLow]
        for b in payload { checksum ^= b }

        var buf: [UInt8] = payload + [checksum]
        guard isCurrent(token) else { return false }
        let ret = IOAVServiceWriteI2C(avService, 0x37, 0x51, &buf, UInt32(buf.count))
        #if DEBUG
        if ret == kIOReturnSuccess {
            print("[DDCService] ARM64 write VCP 0x\(String(command, radix: 16)) = \(value) OK")
        } else {
            print("[DDCService] ARM64 write VCP 0x\(String(command, radix: 16)) failed: \(ret)")
        }
        #endif
        return ret == kIOReturnSuccess
    }

    /// ARM64 DDC read: send a Get VCP request then read the response via IOAVService.
    /// Request layout: [0x82, 0x01, vcpCode, checksum]
    /// Validated response bytes 6–9 carry [maxHigh, maxLow, curHigh, curLow].
    private func arm64Read(displayID: CGDirectDisplayID, command: UInt8, token: UInt64) -> (current: UInt16, max: UInt16)? {
        guard let connection = findAVService(for: displayID) else { return nil }
        defer { withExtendedLifetime(connection) {} }
        let avService = connection.service

        // Build and send the VCP Get Request packet
        var requestChecksum = UInt8(0x6E ^ 0x51)
        let requestPayload: [UInt8] = [0x82, 0x01, command]
        for b in requestPayload { requestChecksum ^= b }
        var requestBuf: [UInt8] = requestPayload + [requestChecksum]

        guard isCurrent(token) else { return nil }
        let writeRet = IOAVServiceWriteI2C(avService, 0x37, 0x51, &requestBuf, UInt32(requestBuf.count))
        guard writeRet == kIOReturnSuccess else {
            #if DEBUG
            print("[DDCService] ARM64 read request failed for VCP 0x\(String(command, radix: 16)): \(writeRet)")
            #endif
            return nil
        }

        // Wait for the display to prepare its DDC/CI reply (~40ms per spec)
        Thread.sleep(forTimeInterval: 0.04)

        // Read the VCP reply
        guard isCurrent(token) else { return nil }
        var replyBuf = [UInt8](repeating: 0, count: 12)
        let readRet = IOAVServiceReadI2C(avService, 0x37, 0, &replyBuf, UInt32(replyBuf.count))
        guard readRet == kIOReturnSuccess else {
            #if DEBUG
            print("[DDCService] ARM64 read reply failed for VCP 0x\(String(command, radix: 16)): \(readRet)")
            #endif
            return nil
        }

        return DDCVCPReply.parse(replyBuf, command: command)
    }
#endif

    // MARK: - Intel (x86_64) IOFramebuffer Path

    /// Finds the IOFramebuffer service for a given external display.
    /// Returns a retained io_service_t — caller must IOObjectRelease.
    private func framebufferService(for displayID: CGDirectDisplayID) -> io_service_t? {
        // Strategy 1: Use CGDisplayIOServicePort (deprecated but functional on macOS 15)
        let servicePort = CGDisplayIOServicePort(displayID)
        if servicePort != MACH_PORT_NULL && servicePort != 0 {
            var parent: io_service_t = 0
            if IORegistryEntryGetParentEntry(servicePort, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 {
                return parent
            }
        }

        // An unverified vendor/model fallback can control another identical panel.
        // Let BrightnessService use per-display software dimming instead.
        return nil
    }

    // MARK: - DDC Checksum (Intel path)

    /// Computes DDC/CI checksum: XOR of destination address + all buffer bytes.
    private func ddcChecksum(destAddress: UInt8, bytes: [UInt8]) -> UInt8 {
        var cs: UInt8 = destAddress
        for b in bytes { cs ^= b }
        return cs
    }

    // MARK: - Synchronous DDC I/O (called on ddcQueue)

    /// Synchronous DDC write (VCP Set). Returns true on success.
    /// On ARM64 uses the IOAVService path; on x86_64 uses the IOFramebuffer I2C path.
    private func writeSynchronous(displayID: CGDirectDisplayID, command: UInt8, value: UInt16, token: UInt64) -> Bool {
        guard routingLock.withLock({ generation == token && targets.contains(where: { $0.displayID == displayID }) }) else { return false }
#if arch(arm64)
        // ARM64 primary path
        if arm64Write(displayID: displayID, command: command, value: value, token: token) {
            return true
        }
        #if DEBUG
        print("[DDCService] writeSynchronous ARM64: failed for display \(displayID) VCP 0x\(String(command, radix: 16))")
        #endif
        return false
#else
        // Intel fallback path
        return intelWriteSynchronous(displayID: displayID, command: command, value: value)
#endif
    }

    /// Synchronous DDC read (VCP Get). Returns (current, max) or nil on failure.
    private func readSynchronous(displayID: CGDirectDisplayID, command: UInt8, token: UInt64) -> (current: UInt16, max: UInt16)? {
        guard routingLock.withLock({ generation == token && targets.contains(where: { $0.displayID == displayID }) }) else { return nil }
#if arch(arm64)
        return arm64Read(displayID: displayID, command: command, token: token)
#else
        return intelReadSynchronous(displayID: displayID, command: command)
#endif
    }

    // MARK: - Intel Write/Read (renamed from original writeSynchronous/readSynchronous)

    private func intelWriteSynchronous(displayID: CGDirectDisplayID, command: UInt8, value: UInt16) -> Bool {
        guard let fb = framebufferService(for: displayID) else {
            #if DEBUG
            print("[DDCService] intelWrite: no framebuffer for display \(displayID)")
            #endif
            return false
        }
        defer { IOObjectRelease(fb) }

        // Try all I2C buses (DDC bus is not always bus 0)
        for busIndex: UInt32 in 0..<8 {
            var iface: io_service_t = 0
            guard IOFBCopyI2CInterfaceForBus(fb, busIndex, &iface) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iface) }

            var conn: IOI2CConnectRef?
            guard IOI2CInterfaceOpen(iface, IOOptionBits(0), &conn) == KERN_SUCCESS,
                  let conn = conn else { continue }
            defer { IOI2CInterfaceClose(conn, IOOptionBits(0)) }

            // Build DDC/CI Set VCP packet:
            // [0x51, 0x84, 0x03, VCP, val_hi, val_lo, checksum]
            var buf: [UInt8] = [
                0x51,
                0x84,
                0x03,
                command,
                UInt8(value >> 8),
                UInt8(value & 0xFF)
            ]
            buf.append(ddcChecksum(destAddress: 0x6E, bytes: buf))
            let bufCount = buf.count

            let ok = buf.withUnsafeMutableBytes { raw -> Bool in
                guard let ptr = raw.baseAddress else { return false }
                var req = IOI2CRequest()
                req.commFlags           = 0
                req.sendAddress         = 0x6E
                req.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                req.sendSubAddress      = 0
                req.sendBuffer          = UInt(bitPattern: ptr)
                req.sendBytes           = UInt32(bufCount)
                req.replyTransactionType = IOOptionBits(kIOI2CNoTransactionType)
                req.replyBytes          = 0
                req.minReplyDelay       = 10_000_000 // 10ms
                let kr = IOI2CSendRequest(conn, IOOptionBits(0), &req)
                return kr == KERN_SUCCESS && req.result == KERN_SUCCESS
            }
            if ok {
                #if DEBUG
                print("[DDCService] Intel write VCP 0x\(String(command, radix:16)) = \(value) on bus \(busIndex) OK")
                #endif
                return true
            }
        }
        #if DEBUG
        print("[DDCService] intelWrite: all buses failed for display \(displayID) VCP 0x\(String(command, radix:16))")
        #endif
        return false
    }

    private func intelReadSynchronous(displayID: CGDirectDisplayID, command: UInt8) -> (current: UInt16, max: UInt16)? {
        guard let fb = framebufferService(for: displayID) else { return nil }
        defer { IOObjectRelease(fb) }

        // Try all I2C buses
        for busIndex: UInt32 in 0..<8 {
            var iface: io_service_t = 0
            guard IOFBCopyI2CInterfaceForBus(fb, busIndex, &iface) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iface) }

            var conn: IOI2CConnectRef?
            guard IOI2CInterfaceOpen(iface, IOOptionBits(0), &conn) == KERN_SUCCESS,
                  let conn = conn else { continue }
            defer { IOI2CInterfaceClose(conn, IOOptionBits(0)) }

            // Build DDC/CI Get VCP request:
            // [0x51, 0x82, 0x01, VCP, checksum]
            var sendBuf: [UInt8] = [0x51, 0x82, 0x01, command]
            sendBuf.append(ddcChecksum(destAddress: 0x6E, bytes: sendBuf))

            var replyBuf = [UInt8](repeating: 0, count: 12)
            var result: (current: UInt16, max: UInt16)? = nil

            let sendCount  = sendBuf.count
            let replyCount = replyBuf.count

            sendBuf.withUnsafeMutableBytes { sendRaw in
                replyBuf.withUnsafeMutableBytes { replyRaw in
                    guard let sp = sendRaw.baseAddress,
                          let rp = replyRaw.baseAddress else { return }

                    var req = IOI2CRequest()
                    req.commFlags           = 0
                    req.sendAddress         = 0x6E
                    req.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                    req.sendSubAddress      = 0
                    req.sendBuffer          = UInt(bitPattern: sp)
                    req.sendBytes           = UInt32(sendCount)
                    req.replyAddress        = 0x6F
                    req.replyTransactionType = IOOptionBits(kIOI2CDDCciReplyTransactionType)
                    req.replySubAddress     = 0
                    req.replyBuffer         = UInt(bitPattern: rp)
                    req.replyBytes          = UInt32(replyCount)
                    req.minReplyDelay       = 50_000_000 // 50ms

                    guard IOI2CSendRequest(conn, IOOptionBits(0), &req) == KERN_SUCCESS,
                          req.result == KERN_SUCCESS else { return }

                    // DDC/CI VCP reply layout:
                    // [0x6E, 0x88, 0x02, errCode, VCPcode, type, max_hi, max_lo, cur_hi, cur_lo, chk]
                    let rb = replyRaw.bindMemory(to: UInt8.self)
                    result = DDCVCPReply.parse(Array(rb), command: command)
                }
            }
            if let r = result { return r }
        }
        return nil
    }

    // MARK: - Cache Cleanup

    /// Removes all cached VCP entries for a display that is no longer connected.
    func clearCache(for displayID: CGDirectDisplayID) {
        cacheLock.lock()
        vcpCache.removeValue(forKey: displayID)
        cacheLock.unlock()
        invalidateDisplayMappings()
    }

    // MARK: - Public Async API (with retry)

    /// Asynchronously write a VCP value, retrying up to 3 times.
    /// Invalidates the cache for the written VCP code on success.
    func writeAsync(
        displayID: CGDirectDisplayID,
        command: UInt8,
        value: UInt16,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        let token = routingLock.withLock { generation }
        let key = PendingWriteKey(displayID: displayID, command: command)
        // Only the newest value matters; superseded writes are dropped so the serial queue never backs up.
        let needsDrain: Bool = pendingLock.withLock {
            let idle = pendingWrites[key] == nil
            pendingWrites[key] = PendingWrite(value: value, token: token, completion: completion)
            return idle
        }
        guard needsDrain else { return }
        ddcQueue.async {
            while true {
                guard let next = self.pendingLock.withLock({ self.pendingWrites[key] }) else { return }
                let ok = self.performWrite(displayID: displayID, command: command, value: next.value, token: next.token)
                let finished: Bool = self.pendingLock.withLock {
                    // A newer value arrived during the I2C transaction: loop instead of finishing.
                    if let latest = self.pendingWrites[key], latest.value != next.value || latest.token != next.token {
                        return false
                    }
                    self.pendingWrites[key] = nil
                    return true
                }
                if finished { next.completion?(ok); return }
            }
        }
    }

    private struct PendingWriteKey: Hashable { let displayID: CGDirectDisplayID; let command: UInt8 }
    private struct PendingWrite {
        let value: UInt16
        let token: UInt64
        let completion: (@Sendable (Bool) -> Void)?
    }
    private var pendingWrites: [PendingWriteKey: PendingWrite] = [:]
    private let pendingLock = NSLock()

    private func performWrite(displayID: CGDirectDisplayID, command: UInt8, value: UInt16, token: UInt64) -> Bool {
        for attempt in 0..<3 {
            guard isCurrent(token) else { return false }
            if writeSynchronous(displayID: displayID, command: command, value: value, token: token) {
                guard isCurrent(token) else { return false }
                // Invalidate cached value so next read reflects the new setting.
                cacheLock.lock()
                vcpCache[displayID]?[command] = nil
                cacheLock.unlock()
                return true
            }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.05) }
        }
        return false
    }

    /// Asynchronously read a VCP value.
    /// Returns a cached result if available and not expired (5-second TTL).
    func readAsync(
        displayID: CGDirectDisplayID,
        command: UInt8,
        completion: @escaping @Sendable ((current: UInt16, max: UInt16)?) -> Void
    ) {
        let token = routingLock.withLock { generation }
        // Fast path: return cached value if still fresh
        cacheLock.lock()
        if let entry = vcpCache[displayID]?[command], !entry.isExpired {
            cacheLock.unlock()
            completion(isCurrent(token) ? (current: entry.current, max: entry.max) : nil)
            return
        }
        cacheLock.unlock()

        ddcQueue.async {
            for attempt in 0..<3 {
                guard self.isCurrent(token) else { completion(nil); return }
                if let r = self.readSynchronous(displayID: displayID, command: command, token: token) {
                    self.routingLock.lock()
                    guard self.generation == token else { self.routingLock.unlock(); completion(nil); return }
                    self.cacheLock.lock()
                    if self.vcpCache[displayID] == nil { self.vcpCache[displayID] = [:] }
                    self.vcpCache[displayID]![command] = VCPCacheEntry(
                        current: r.current, max: r.max, timestamp: Date()
                    )
                    self.cacheLock.unlock()
                    self.routingLock.unlock()
                    completion(r)
                    return
                }
                if attempt < 2 { Thread.sleep(forTimeInterval: 0.05) }
            }
            completion(nil)
        }
    }

    /// Reads a batch of common VCP codes asynchronously.
    /// Every requested code appears in the result dictionary:
    ///   - `.some(value)` means the code was read successfully (or served from cache)
    ///   - `.none` means the I2C read was attempted but failed
    func readBatchVCPCodes(displayID: CGDirectDisplayID) async -> [UInt8: UInt16?] {
        let codes: [UInt8] = [0x10, 0x12, 0x14, 0x16, 0x18, 0x1A, 0x60, 0x62, 0x87, 0xD6, 0xDC]

        var result: [UInt8: UInt16?] = [:]
        for code in codes {
            let value = await withCheckedContinuation { continuation in
                readAsync(displayID: displayID, command: code) { continuation.resume(returning: $0) }
            }
            result[code] = .some(value?.current)
        }
        return result
    }
}
