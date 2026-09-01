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
        case paused
        case verifying
        case completed
        case cancelled
        case interrupted
        case insufficientStorage
        case failed(String)
    }

    var id: UUID
    var item: DeviceSyncItem
    var direction: DeviceSyncDirection
    var phase: Phase
    var fractionCompleted: Double = 0
    var bytesTransferred: Int64 = 0
    var resumedFromCheckpoint = false

    var isActive: Bool {
        switch phase {
        case .preparing, .transferring, .paused, .verifying:
            true
        case .completed, .cancelled, .interrupted, .insufficientStorage, .failed:
            false
        }
    }

    mutating func updateProgress(fraction: Double, completedBytes: Int64) {
        fractionCompleted = min(max(fraction, 0), 1)
        bytesTransferred = min(max(completedBytes, 0), item.fileSize)
    }
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

struct DeviceSyncTrackOverlay: Codable, Equatable, Hashable, Sendable {
    var sourceKey: String
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var isFavorite: Bool
    var rating: Int
    var playCount: Int
    var skipCount: Int
    var lastPlayedAt: Date?
    var displayTags: [String]? = nil
    var updatedAt: Date

    func matchesIdentity(of other: DeviceSyncTrackOverlay) -> Bool {
        Self.normalized(title) == Self.normalized(other.title)
            && Self.normalized(artist) == Self.normalized(other.artist)
            && Self.normalized(album) == Self.normalized(other.album)
            && abs(duration - other.duration) <= 3
    }

    func hasSameValues(as other: DeviceSyncTrackOverlay) -> Bool {
        isFavorite == other.isFavorite
            && rating == other.rating
            && playCount == other.playCount
            && skipCount == other.skipCount
            && lastPlayedAt == other.lastPlayedAt
            && (displayTags ?? []) == (other.displayTags ?? [])
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum DeviceSyncOverlayMatchStatus: String, Sendable {
    case different
    case identical
    case ambiguous
    case unmatched
}

struct DeviceSyncOverlayPreview: Identifiable, Sendable {
    var id: String { remote.sourceKey }
    var remote: DeviceSyncTrackOverlay
    var local: DeviceSyncTrackOverlay?
    var localTrackID: UUID?
    var status: DeviceSyncOverlayMatchStatus
}

struct DeviceSyncOverlayApplication: Sendable {
    var trackID: UUID
    var overlay: DeviceSyncTrackOverlay
    var fields: Set<DeviceSyncOverlayField>
}

enum DeviceSyncOverlayField: String, Codable, CaseIterable, Hashable, Sendable {
    case favorite
    case rating
    case playCount
    case skipCount
    case lastPlayedAt
    case displayTags
}

struct DeviceSyncTrackReference: Codable, Equatable, Hashable, Sendable {
    var sourceKey: String
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval

    func matchesIdentity(of overlay: DeviceSyncTrackOverlay) -> Bool {
        overlay.matchesIdentity(of: DeviceSyncTrackOverlay(
            sourceKey: sourceKey,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            isFavorite: false,
            rating: 0,
            playCount: 0,
            skipCount: 0,
            lastPlayedAt: nil,
            updatedAt: .distantPast
        ))
    }
}

struct DeviceSyncPlaylistOverlay: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var tracks: [DeviceSyncTrackReference]
    var createdAt: Date
    var updatedAt: Date
}

enum DeviceSyncPlaylistMatchStatus: String, Sendable {
    case new
    case different
    case identical
    case conflicted
}

struct DeviceSyncPlaylistPreview: Identifiable, Sendable {
    var id: UUID { remote.id }
    var remote: DeviceSyncPlaylistOverlay
    var local: Playlist?
    var matchedTrackIDs: [Track.ID]
    var unmatchedTrackCount: Int
    var ambiguousTrackCount: Int
    var status: DeviceSyncPlaylistMatchStatus
}

struct DeviceSyncPlaylistApplication: Sendable {
    var remote: DeviceSyncPlaylistOverlay
    var trackIDs: [Track.ID]
}

struct DeviceSyncOverlayReceiptItem: Codable, Equatable, Sendable {
    var sourceKey: String
    var fields: [DeviceSyncOverlayField]
}

struct DeviceSyncOverlayReceipt: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var appliedAt: Date
    var items: [DeviceSyncOverlayReceiptItem]
    var ignoredCount: Int

    var appliedFieldCount: Int { items.reduce(0) { $0 + $1.fields.count } }
}

enum DeviceSyncAuditConflictReason: String, Codable, Sendable {
    case ambiguous
    case unmatched
    case noApplicableFields
    case changedAfterSync
    case playlistTracksUnmatched
    case playlistTracksAmbiguous
    case playlistSmartCollision
}

struct DeviceSyncAuditChange: Codable, Equatable, Sendable {
    var trackID: UUID
    var title: String
    var before: DeviceSyncTrackOverlay
    var after: DeviceSyncTrackOverlay
    var fields: [DeviceSyncOverlayField]
}

struct DeviceSyncPlaylistAuditChange: Codable, Equatable, Sendable {
    var before: Playlist?
    var after: Playlist
}

struct DeviceSyncAuditConflict: Codable, Equatable, Sendable {
    var sourceKey: String
    var title: String
    var reason: DeviceSyncAuditConflictReason
}

struct DeviceSyncAuditEntry: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var occurredAt: Date
    var deviceName: String
    var changes: [DeviceSyncAuditChange]
    var playlistChanges: [DeviceSyncPlaylistAuditChange]? = nil
    var conflicts: [DeviceSyncAuditConflict]
    var isUndone: Bool

    var appliedFieldCount: Int { changes.reduce(0) { $0 + $1.fields.count } }
    var appliedPlaylistCount: Int { playlistChanges?.count ?? 0 }
}

struct DeviceSyncOverlayUndoResult: Equatable, Sendable {
    var restoredFieldCount: Int
    var conflictFieldCount: Int
}

struct DeviceSyncManifest: Codable, Equatable, Sendable {
    var deviceName: String
    var generatedAt: Date
    var items: [DeviceSyncItem]
    var storage: DeviceStorageInfo? = nil
    var overlays: [DeviceSyncTrackOverlay]? = nil
    var playlistOverlays: [DeviceSyncPlaylistOverlay]? = nil
}

struct DeviceSyncResourceAnnouncement: Codable, Sendable {
    var transferID: UUID
    var direction: DeviceSyncDirection
    var item: DeviceSyncItem
}

enum DeviceTransferControlAction: String, Codable, Sendable {
    case pause
    case resume
    case cancel
    case insufficientStorage
}

struct DeviceTransferControl: Codable, Sendable {
    var transferID: UUID
    var action: DeviceTransferControlAction
}

enum DeviceTransferCapacity {
    static let defaultReserveBytes: Int64 = 256 * 1_024 * 1_024

    static func canReceive(
        fileSize: Int64,
        availableBytes: Int64,
        reserveBytes: Int64 = defaultReserveBytes
    ) -> Bool {
        guard fileSize >= 0, availableBytes >= 0, reserveBytes >= 0 else { return false }
        return fileSize <= max(0, availableBytes - reserveBytes)
    }
}

enum DeviceSyncMessage: Codable, Sendable {
    case manifest(DeviceSyncManifest)
    case requestItem(UUID)
    case resource(DeviceSyncResourceAnnouncement)
    case transferControl(DeviceTransferControl)
    case chunkOffer(DeviceChunkTransferDescriptor)
    case chunkRequest(DeviceChunkRequest)
    case chunkPayload(DeviceChunkPayload)
    case chunkCompletion(DeviceChunkCompletion)
    case overlayReceipt(DeviceSyncOverlayReceipt)
    case error(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case manifest
        case itemID
        case resource
        case transferControl
        case chunkOffer
        case chunkRequest
        case chunkPayload
        case chunkCompletion
        case overlayReceipt
        case message
    }

    private enum Kind: String, Codable {
        case manifest
        case requestItem
        case resource
        case transferControl
        case chunkOffer
        case chunkRequest
        case chunkPayload
        case chunkCompletion
        case overlayReceipt
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
        case .transferControl:
            self = .transferControl(
                try container.decode(DeviceTransferControl.self, forKey: .transferControl)
            )
        case .chunkOffer:
            self = .chunkOffer(
                try container.decode(DeviceChunkTransferDescriptor.self, forKey: .chunkOffer)
            )
        case .chunkRequest:
            self = .chunkRequest(
                try container.decode(DeviceChunkRequest.self, forKey: .chunkRequest)
            )
        case .chunkPayload:
            self = .chunkPayload(
                try container.decode(DeviceChunkPayload.self, forKey: .chunkPayload)
            )
        case .chunkCompletion:
            self = .chunkCompletion(
                try container.decode(DeviceChunkCompletion.self, forKey: .chunkCompletion)
            )
        case .overlayReceipt:
            self = .overlayReceipt(
                try container.decode(DeviceSyncOverlayReceipt.self, forKey: .overlayReceipt)
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
        case .transferControl(let control):
            try container.encode(Kind.transferControl, forKey: .kind)
            try container.encode(control, forKey: .transferControl)
        case .chunkOffer(let offer):
            try container.encode(Kind.chunkOffer, forKey: .kind)
            try container.encode(offer, forKey: .chunkOffer)
        case .chunkRequest(let request):
            try container.encode(Kind.chunkRequest, forKey: .kind)
            try container.encode(request, forKey: .chunkRequest)
        case .chunkPayload(let payload):
            try container.encode(Kind.chunkPayload, forKey: .kind)
            try container.encode(payload, forKey: .chunkPayload)
        case .chunkCompletion(let completion):
            try container.encode(Kind.chunkCompletion, forKey: .kind)
            try container.encode(completion, forKey: .chunkCompletion)
        case .overlayReceipt(let receipt):
            try container.encode(Kind.overlayReceipt, forKey: .kind)
            try container.encode(receipt, forKey: .overlayReceipt)
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
