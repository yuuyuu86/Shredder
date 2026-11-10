import CoreServices
import Foundation

public struct FileEvent: Sendable, Hashable {
    public struct Kind: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let created = Kind(rawValue: 1 << 0)
        public static let modified = Kind(rawValue: 1 << 1)
        public static let renamed = Kind(rawValue: 1 << 2)
        public static let removed = Kind(rawValue: 1 << 3)
    }

    public let path: String
    public let kind: Kind
    public let isDirectory: Bool
}

/// FSEvents によるフォルダ監視（仕様 7.3）。追加・変更・移動・削除を検知する。
public final class FolderWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable ([FileEvent]) -> Void

    private let paths: [String]
    private let latency: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "app.shredder.fsevents")
    private var stream: FSEventStreamRef?
    private let lock = NSLock()

    public init(paths: [String], latency: TimeInterval = 1.0, handler: @escaping Handler) {
        self.paths = paths
        self.latency = latency
        self.handler = handler
    }

    deinit {
        stop()
    }

    @discardableResult
    public func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil, !paths.isEmpty else { return stream != nil }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            var events: [FileEvent] = []
            for index in 0..<min(count, paths.count) {
                let flags = Int(eventFlags[index])
                var kind: FileEvent.Kind = []
                if flags & kFSEventStreamEventFlagItemCreated != 0 { kind.insert(.created) }
                if flags & kFSEventStreamEventFlagItemModified != 0 || flags & kFSEventStreamEventFlagItemInodeMetaMod != 0 { kind.insert(.modified) }
                if flags & kFSEventStreamEventFlagItemRenamed != 0 { kind.insert(.renamed) }
                if flags & kFSEventStreamEventFlagItemRemoved != 0 { kind.insert(.removed) }
                guard !kind.isEmpty else { continue }
                events.append(FileEvent(path: paths[index], kind: kind, isDirectory: flags & kFSEventStreamEventFlagItemIsDir != 0))
            }
            if !events.isEmpty { watcher.handler(events) }
        }

        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        ) else { return false }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stream != nil
    }
}
