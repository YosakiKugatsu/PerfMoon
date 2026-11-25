// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Darwin
import Foundation

/// One private, lifetime-bound Unix socket. A frame is a big-endian UInt32
/// length followed by JSON. Partial reads, EOF and broken pipes terminate it.
final class CollectorSocket: @unchecked Sendable {
    let fd: Int32
    private let writer = NSLock()

    init() throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }
        configure()
    }
    init(accepted: Int32) {
        fd = accepted
        configure()
    }
    private func configure() {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }
    deinit { Darwin.close(fd) }
    func stop() { shutdown(fd, SHUT_RDWR) }

    func address(_ path: String, bindSocket: Bool) throws {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in bytes.withUnsafeBytes { dst.copyBytes(from: $0) } }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        addr.sun_len = UInt8(length)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bindSocket ? Darwin.bind(fd, $0, length) : Darwin.connect(fd, $0, length)
            }
        }
        guard result == 0 else { throw POSIXError(.ECONNREFUSED) }
    }

    func write<T: Encodable>(_ value: T) throws {
        let payload = try JSONEncoder().encode(value)
        guard payload.count <= Self.maxFrame else { throw POSIXError(.EMSGSIZE) }
        var length = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        writer.lock()
        defer { writer.unlock() }
        try frame.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                let n = Darwin.write(fd, buf.baseAddress!.advanced(by: offset), buf.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw POSIXError(.EPIPE) }
                offset += n
            }
        }
    }

    private static let maxFrame = 4 * 1024 * 1024
    func read<T: Decodable>(_ type: T.Type) throws -> T {
        var length: UInt32 = 0
        try withUnsafeMutableBytes(of: &length) { try readAll($0) }
        let bytes = Int(UInt32(bigEndian: length))
        guard bytes > 0, bytes <= Self.maxFrame else { throw POSIXError(.EMSGSIZE) }
        var data = Data(count: bytes)
        try data.withUnsafeMutableBytes { try readAll($0) }
        return try JSONDecoder().decode(type, from: data)
    }

    private func readAll(_ buffer: UnsafeMutableRawBufferPointer) throws {
        var offset = 0
        while offset < buffer.count {
            let n = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw POSIXError(.ECONNRESET) }
            offset += n
        }
    }
}

struct CollectorRequest: Codable {
    let id: Int
    let command: CollectorCommand
}

enum CollectorCommand: Codable {
    case identify, volumesChanged
    case diskHealth(String)
    case open(SourceID, Double), close(SourceID), baseline(SourceID, Double)
    case sample([JobID: SampleRequest], Double)
    case disks(Double), processes(Double, Bool), overhead(Double, Double, diagnostics: Bool)
}

struct CollectorReply: Codable {
    let id: Int
    var machine: MachineInfo?
    var sensors: [SensorInfo]?
    var opened: OpenResult?
    var outcomes: [JobID: SampleOutcome]?
    var networkInterfaces: [NetworkInterfaceInfo]?
    var diskHealth: DiskHealthReport?
    var cpuThrottle: ThrottleStatus?
    var gpuThrottle: ThrottleStatus?
    var processes: ProcessMemorySnapshot?
    var usage: SelfUsage?
    var uid: UInt32?
}

/// The reader only wakes for a reply. A slow disk scan never holds up a fast
/// sensor frame; replies are matched by request ID, not by completion order.
final class CollectorChannel: @unchecked Sendable {
    private final class Waiter: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0)
        var reply: CollectorReply?
    }
    private let socket: CollectorSocket
    private let lock = NSLock()
    private var closed = false
    private var sequence = 0
    private var waiting: [Int: Waiter] = [:]
    private let launcher: Process

    init(socket: CollectorSocket, launcher: Process) {
        self.socket = socket
        self.launcher = launcher
        Thread.detachNewThread { [weak self, socket] in
            do {
                while true {
                    let reply = try socket.read(CollectorReply.self)
                    guard let self else { return }
                    lock.withLock {
                        if let waiter = waiting.removeValue(forKey: reply.id) {
                            waiter.reply = reply
                            waiter.ready.signal()
                        }
                    }
                }
            } catch { self?.invalidate() }
        }
    }
    deinit { socket.stop() }

    func invalidate() {
        lock.withLock {
            closed = true
            socket.stop()
            for waiter in waiting.values { waiter.ready.signal() }
            waiting.removeAll()
        }
    }

    func call(_ command: CollectorCommand, timeout: Double = 3) -> CollectorReply? {
        let waiter = Waiter()
        let id = lock.withLock { () -> Int? in
            guard !closed else { return nil }
            sequence += 1
            waiting[sequence] = waiter
            return sequence
        }
        guard let id else { return nil }
        do { try socket.write(CollectorRequest(id: id, command: command)) }
        catch { invalidate(); return nil }
        guard waiter.ready.wait(timeout: .now() + timeout) == .success else {
            invalidate()
            return nil
        }
        return waiter.reply
    }

    var isConnected: Bool { lock.withLock { !closed } }

    static func launch(executable: URL, allowDialog: Bool) throws -> CollectorChannel {
        var template = Array("/private/tmp/perfmoon-collector.XXXXXXXX".utf8CString)
        guard mkdtemp(&template) != nil else { throw POSIXError(.EIO) }
        let directory = String(decoding: template.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        let path = directory + "/socket"
        defer { unlink(path); rmdir(directory) }
        let listener = try CollectorSocket()
        try listener.address(path, bindSocket: true)
        guard listen(listener.fd, 1) == 0 else { throw POSIXError(.EIO) }

        func spawn(_ elevatedDialog: Bool) throws -> Process {
            let child = Process()
            if elevatedDialog {
                // SecurityAgent handles the credential. Only executable and socket
                // paths are passed as argv and quoted by the system scripting addition.
                child.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                child.arguments = ["-e", "on run argv", "-e",
                    "do shell script (\"exec \" & quoted form of (item 1 of argv) & \" --root-collector \" & quoted form of (item 2 of argv)) with administrator privileges",
                    "-e", "end run", executable.path, path]
            } else {
                child.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                child.arguments = ["-n", "--", executable.path, "--root-collector", path]
            }
            child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run()
            return child
        }
        for dialog in allowDialog ? [false, true] : [false] {
            let child = try spawn(dialog)
            let deadline = ProcessInfo.processInfo.systemUptime + (dialog ? 120 : 4)
            var watch = pollfd(fd: listener.fd, events: Int16(POLLIN), revents: 0)
            while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                guard poll(&watch, 1, 50) > 0 else { continue }
                let fd = accept(listener.fd, nil, nil)
                guard fd >= 0 else { continue }
                let peer = CollectorSocket(accepted: fd)
                var uid: uid_t = 1, gid: gid_t = 1
                guard getpeereid(fd, &uid, &gid) == 0, uid == 0 else { continue }
                return CollectorChannel(socket: peer, launcher: child)
            }
            if child.isRunning { child.terminate() }
        }
        throw POSIXError(.EACCES)
    }
}
