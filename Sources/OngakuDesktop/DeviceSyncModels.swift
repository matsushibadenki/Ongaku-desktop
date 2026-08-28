import CryptoKit
import Foundation

enum DeviceSyncService {
    static let serviceType = "ongaku-sync"
}

enum DeviceSyncConnectionState: Equatable, Sendable {
    case searching
    case connecting(String)
    case connected(String)
    case disconnected
    case failed(String)
}

struct DeviceTransferState: Identifiable, Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case preparing
        case transferring
        case verifying
        case completed
        case failed(String)
    }

    var id: UUID
    var item: DeviceSyncItem
    var direction: DeviceSyncDirection
    var phase: Phase
}

enum DeviceSyncDirection: String, Codable, Sendable {
    case macToPhone
    case phoneToMac
}

struct DeviceSyncItem: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var artist: String
    var album: String
    var fileName: String
    var fileSize: Int64
    var sha256: String
    var modifiedAt: Date
}

struct DeviceStorageInfo: Codable, Equatable, Sendable {
    var totalBytes: Int64
    var availableBytes: Int64
}

struct DeviceSyncManifest: Codable, Equatable, Sendable {
    var deviceName: String
    var generatedAt: Date
    var items: [DeviceSyncItem]
    var storage: DeviceStorageInfo? = nil
}

struct DeviceSyncResourceAnnouncement: Codable, Sendable {
    var transferID: UUID
    var direction: DeviceSyncDirection
    var item: DeviceSyncItem
}

enum DeviceSyncMessage: Codable, Sendable {
    case manifest(DeviceSyncManifest)
    case requestItem(UUID)
    case resource(DeviceSyncResourceAnnouncement)
    case error(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case manifest
        case itemID
        case resource
        case message
    }

    private enum Kind: String, Codable {
        case manifest
        case requestItem
        case resource
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .manifest:
            self = .manifest(try container.decode(DeviceSyncManifest.self, forKey: .manifest))
        case .requestItem:
            self = .requestItem(try container.decode(UUID.self, forKey: .itemID))
        case .resource:
            self = .resource(
                try container.decode(DeviceSyncResourceAnnouncement.self, forKey: .resource)
            )
        case .error:
            self = .error(try container.decode(String.self, forKey: .message))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .manifest(let manifest):
            try container.encode(Kind.manifest, forKey: .kind)
            try container.encode(manifest, forKey: .manifest)
        case .requestItem(let itemID):
            try container.encode(Kind.requestItem, forKey: .kind)
            try container.encode(itemID, forKey: .itemID)
        case .resource(let resource):
            try container.encode(Kind.resource, forKey: .kind)
            try container.encode(resource, forKey: .resource)
        case .error(let message):
            try container.encode(Kind.error, forKey: .kind)
            try container.encode(message, forKey: .message)
        }
    }
}

enum DeviceSyncFileIntegrity {
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else {
                break
            }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func verified(_ url: URL, matches item: DeviceSyncItem) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              Int64(values.fileSize ?? 0) == item.fileSize else {
            return false
        }
        return try sha256(of: url) == item.sha256
    }
}
