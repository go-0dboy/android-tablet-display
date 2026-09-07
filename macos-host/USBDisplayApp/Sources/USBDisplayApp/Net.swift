// Net.swift — the socket layer.
//
// The bug this file exists to kill: v1 called send(2) once per buffer and
// treated any positive return as success. send(2) is allowed to accept fewer
// bytes than you gave it, and on a 2560x1600 keyframe at 15 Mbps it routinely
// does. The client then read a length prefix that pointed into the middle of
// the previous frame and every frame after that was garbage — which is very
// likely what the README meant by "frame delivery depends on screen changes".
//
// Everything here loops until the whole buffer is written, or the peer is gone.

import Foundation
import Darwin
import USBDisplayCore

enum SocketError: Error, LocalizedError {
    case failedToCreate(errno: Int32)
    case failedToBind(port: UInt16, errno: Int32)
    case failedToListen(errno: Int32)
    case peerGone

    var errorDescription: String? {
        switch self {
        case .failedToCreate(let e):
            return "Could not create socket: \(String(cString: strerror(e)))"
        case .failedToBind(let port, let e):
            return "Could not bind port \(port): \(String(cString: strerror(e))). "
                 + "Another copy of the app may already be running."
        case .failedToListen(let e):
            return "Could not listen: \(String(cString: strerror(e)))"
        case .peerGone:
            return "The client disconnected."
        }
    }
}

/// Write `data` in full. Retries short writes and EINTR; returns false only if
/// the peer is genuinely gone.
@discardableResult
func writeFully(_ fd: Int32, _ data: Data) -> Bool {
    guard !data.isEmpty else { return true }

    return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        guard let base = raw.baseAddress else { return true }
        var sent = 0
        while sent < data.count {
            // MSG_NOSIGNAL has no macOS equivalent; SO_NOSIGPIPE is set on the
            // socket instead, so a dead peer surfaces as EPIPE not SIGPIPE.
            let n = Darwin.send(fd, base.advanced(by: sent), data.count - sent, 0)
            if n > 0 {
                sent += n
                continue
            }
            if n < 0 {
                let err = errno
                if err == EINTR { continue }
                if err == EAGAIN || err == EWOULDBLOCK {
                    // Socket is blocking, so this means a send timeout expired.
                    // Treat as fatal: a stalled client must not stall the host.
                    return false
                }
                return false
            }
            return false   // n == 0: peer closed
        }
        return true
    }
}

/// Read exactly `count` bytes, or return nil if the peer goes away first.
func readFully(_ fd: Int32, count: Int) -> Data? {
    guard count > 0 else { return Data() }
    var buffer = [UInt8](repeating: 0, count: count)
    var got = 0

    while got < count {
        let n = buffer.withUnsafeMutableBytes { ptr -> Int in
            Darwin.recv(fd, ptr.baseAddress!.advanced(by: got), count - got, 0)
        }
        if n > 0 { got += n; continue }
        if n < 0 && errno == EINTR { continue }
        return nil
    }
    return Data(buffer)
}

/// Configure a connected socket for interactive use.
func tuneSocket(_ fd: Int32) {
    var on: Int32 = 1
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
    // Without this a write to a closed socket kills the whole process.
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

    // Bound how long a stalled client can block the encoder callback.
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    // A large send buffer absorbs keyframe bursts without stalling.
    var sndBuf: Int32 = 4 * 1024 * 1024
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndBuf, socklen_t(MemoryLayout<Int32>.size))
}

/// Bind and listen on a TCP port.
/// - Parameter loopbackOnly: USB mode goes through `adb reverse`, which
///   connects from localhost, so the socket never needs to be reachable from
///   the network. Wireless mode is the only case that binds all interfaces.
func makeListeningSocket(port: UInt16, loopbackOnly: Bool) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SocketError.failedToCreate(errno: errno) }

    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = loopbackOnly ? INADDR_LOOPBACK.bigEndian : INADDR_ANY

    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else {
        let e = errno
        close(fd)
        throw SocketError.failedToBind(port: port, errno: e)
    }
    guard listen(fd, 4) == 0 else {
        let e = errno
        close(fd)
        throw SocketError.failedToListen(errno: e)
    }
    return fd
}

// MARK: - Video channel

/// Serves length-prefixed video frames to one client at a time.
final class VideoServer {
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var running = false

    let port: UInt16
    private let loopbackOnly: Bool

    /// Frames dropped because the client could not keep up. Surfaced in the
    /// menu so a stuttering link is visible rather than mysterious.
    private(set) var droppedFrames = 0

    var onClientConnected: (() -> Void)?
    var onClientDisconnected: (() -> Void)?

    init(port: UInt16, loopbackOnly: Bool) {
        self.port = port
        self.loopbackOnly = loopbackOnly
    }

    func start() throws {
        listenFD = try makeListeningSocket(port: port, loopbackOnly: loopbackOnly)
        running = true
        log("Video server listening on \(loopbackOnly ? "127.0.0.1" : "0.0.0.0"):\(port)")

        Thread.detachNewThread { [weak self] in
            self?.acceptLoop()
        }
    }

    private func acceptLoop() {
        while running {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let fd = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenFD, $0, &len)
                }
            }
            guard fd >= 0 else {
                if !running { return }
                if errno == EINTR { continue }
                Thread.sleep(forTimeInterval: 0.2)
                continue
            }
            tuneSocket(fd)

            lock.lock()
            let previous = clientFD
            clientFD = fd
            droppedFrames = 0
            lock.unlock()

            if previous >= 0 { close(previous) }
            log("Video client connected")
            onClientConnected?()
        }
    }

    var hasClient: Bool {
        lock.lock(); defer { lock.unlock() }
        return clientFD >= 0
    }

    /// Send one encoded access unit. Returns false if the client went away.
    @discardableResult
    func send(frame: Data) -> Bool {
        lock.lock()
        let fd = clientFD
        lock.unlock()
        guard fd >= 0 else { return false }

        guard VideoFraming.isPlausibleFrameLength(frame.count) else {
            droppedFrames += 1
            log("Refusing to send an implausible frame of \(frame.count) bytes")
            return true
        }

        // One write for header+payload: two writes let a slow client see a
        // header without a body, and gives Nagle a chance to split them oddly.
        if writeFully(fd, VideoFraming.frame(frame)) { return true }

        log("Video client write failed; dropping the connection")
        dropClient()
        return false
    }

    func dropClient() {
        lock.lock()
        let fd = clientFD
        clientFD = -1
        lock.unlock()
        if fd >= 0 { close(fd) }
        onClientDisconnected?()
    }

    func stop() {
        running = false
        lock.lock()
        let c = clientFD, l = listenFD
        clientFD = -1; listenFD = -1
        lock.unlock()
        if c >= 0 { close(c) }
        if l >= 0 { close(l) }
    }
}

// MARK: - Input channel

/// Receives input messages from the client and hands them to a sink. Also
/// carries the host's hello-ack back, which is how the client learns the
/// display was accepted.
final class InputServer {
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var running = false

    let port: UInt16
    private let loopbackOnly: Bool

    /// Called for every decoded message, on a background thread.
    var onMessage: ((InputMessage) -> Void)?
    var onClientDisconnected: (() -> Void)?

    init(port: UInt16, loopbackOnly: Bool) {
        self.port = port
        self.loopbackOnly = loopbackOnly
    }

    func start() throws {
        listenFD = try makeListeningSocket(port: port, loopbackOnly: loopbackOnly)
        running = true
        log("Input server listening on \(loopbackOnly ? "127.0.0.1" : "0.0.0.0"):\(port)")

        Thread.detachNewThread { [weak self] in
            self?.acceptLoop()
        }
    }

    private func acceptLoop() {
        while running {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let fd = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenFD, $0, &len)
                }
            }
            guard fd >= 0 else {
                if !running { return }
                if errno == EINTR { continue }
                Thread.sleep(forTimeInterval: 0.2)
                continue
            }
            tuneSocket(fd)
            // Input must never block on a slow reader.
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            lock.lock()
            let previous = clientFD
            clientFD = fd
            lock.unlock()
            if previous >= 0 { close(previous) }

            log("Input client connected")
            readLoop(fd)
        }
    }

    private func readLoop(_ fd: Int32) {
        var parser = InputStreamParser()
        var chunk = [UInt8](repeating: 0, count: 8192)
        var inputOnlyFailure = false

        while running {
            let n = chunk.withUnsafeMutableBytes { ptr -> Int in
                Darwin.recv(fd, ptr.baseAddress!, 8192, 0)
            }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { break }

            parser.append(Data(chunk[0..<n]))

            do {
                while let message = try parser.next() {
                    onMessage?(message)
                }
            } catch {
                // A malformed length means this channel is unrecoverable, but
                // the video stream and the display are fine. Drop only the
                // input connection and let the client redial it — tearing the
                // display down over one bad input byte is a far worse outcome
                // than briefly losing touch.
                log("Input stream error (\(error)); dropping the input channel only")
                inputOnlyFailure = true
                break
            }
        }

        lock.lock()
        if clientFD == fd { clientFD = -1 }
        lock.unlock()
        close(fd)
        if inputOnlyFailure {
            log("Input channel closed; the display and video stream are unaffected")
        } else {
            log("Input client disconnected")
            onClientDisconnected?()
        }
    }

    /// Send a message back to the client (hello-ack, keep-alive).
    @discardableResult
    func send(_ message: InputMessage) -> Bool {
        lock.lock()
        let fd = clientFD
        lock.unlock()
        guard fd >= 0 else { return false }
        return writeFully(fd, InputCodec.encode(message))
    }

    func stop() {
        running = false
        lock.lock()
        let c = clientFD, l = listenFD
        clientFD = -1; listenFD = -1
        lock.unlock()
        if c >= 0 { close(c) }
        if l >= 0 { close(l) }
    }
}
