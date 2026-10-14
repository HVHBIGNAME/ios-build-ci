import CoreFoundation
import Foundation

public struct WhitegramErrorReport: Codable, Equatable {
    public enum Kind: String, Codable { case crash, hang, http, network, runtime, test }
    public enum Component: String, Codable { case app, services, backend, audio, storage }

    public struct Frame: Codable, Equatable {
        public let binary: String
        public let uuid: String
        public let offset: UInt64
        public let depth: Int
        public let thread: Int
    }

    public let schema: Int
    public let id: UUID
    public let timestamp: Int64
    public let version: String
    public let build: String
    public let revision: String
    public let os: String
    public let kind: Kind
    public let component: Component
    public let code: Int
    public let frames: [Frame]

    public init(kind: Kind, component: Component, code: Int, frames: [Frame] = [], now: Date = Date(), info: [String: Any] = Bundle.main.infoDictionary ?? [:], diagnosticBuild: String? = nil) {
        self.schema = 1
        self.id = UUID()
        self.timestamp = Int64(now.timeIntervalSince1970)
        let currentBuild = Self.numericVersion(info["CFBundleVersion"] as? String)
        let previousBuild = diagnosticBuild != nil && Self.numericVersion(diagnosticBuild) != currentBuild
        self.version = previousBuild ? "0" : Self.numericVersion(info["CFBundleShortVersionString"] as? String)
        self.build = diagnosticBuild.map { Self.numericVersion($0) } ?? currentBuild
        let revision = (info["WhitegramSourceRevision"] as? String) ?? ""
        self.revision = !previousBuild && Self.matches(revision, "^[a-f0-9]{40}$") ? revision : "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        self.os = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        self.kind = kind
        self.component = component
        self.code = code
        self.frames = Array(frames.prefix(64))
    }

    private static func numericVersion(_ value: String?) -> String {
        guard let value, matches(value, "^[0-9]{1,10}(\\.[0-9]{1,10}){0,3}$") else { return "0" }
        return value
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    /// Keep only binary identities and relative offsets; never copy raw diagnostic metadata.
    public static func frames(from data: Data) -> [Frame] {
        guard data.count <= 4 * 1024 * 1024,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let stacks = root["callStacks"] as? [[String: Any]] else { return [] }
        var result: [Frame] = []
        func visit(_ frames: [[String: Any]], depth: Int, thread: Int) {
            guard depth <= 32 else { return }
            for frame in frames.prefix(64) {
                guard result.count < 64 else { return }
                if let binary = frame["binaryName"] as? String, binary.count <= 96,
                   matches(binary, "^[A-Za-z0-9_.+-]+$"),
                   let uuid = frame["binaryUUID"] as? String, UUID(uuidString: uuid) != nil,
                   let offset = frame["offsetIntoBinary"] as? NSNumber,
                   CFGetTypeID(offset) != CFBooleanGetTypeID(),
                   offset.doubleValue.isFinite, offset.doubleValue >= 0, offset.doubleValue <= Double(Int64.max),
                   offset.doubleValue.rounded(.down) == offset.doubleValue, offset.uint64Value <= UInt64(Int64.max) {
                    result.append(Frame(binary: binary, uuid: uuid.uppercased(), offset: offset.uint64Value, depth: depth, thread: thread))
                }
                if let children = frame["subFrames"] as? [[String: Any]] { visit(children, depth: depth + 1, thread: thread) }
            }
        }
        // Attributed/crashed stacks first, so a bounded report retains the useful frames.
        let ordered = stacks.enumerated().sorted { ($0.element["threadAttributed"] as? Bool == true ? 0 : 1) < ($1.element["threadAttributed"] as? Bool == true ? 0 : 1) }
        for (thread, stack) in ordered.prefix(8) {
            if let frames = stack["callStackRootFrames"] as? [[String: Any]] { visit(frames, depth: 0, thread: thread) }
        }
        return result
    }

    var fingerprint: String {
        return "\(revision):\(kind.rawValue):\(component.rawValue):\(code):" + frames.prefix(8).map { "\($0.uuid):\($0.offset)" }.joined(separator: ",")
    }
}
