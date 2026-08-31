import Foundation
import Testing
@testable import OngakuDesktop

@Suite("Device sync protocol")
struct DeviceSyncTests {
    @Test("Manifest messages preserve transfer metadata")
    func manifestRoundTrip() throws {
        let item = makeItem()
        let message = DeviceSyncMessage.manifest(DeviceSyncManifest(
            deviceName: "Listening Room iPhone",
            generatedAt: Date(timeIntervalSince1970: 1_725_000_000),
            items: [item],
            storage: DeviceStorageInfo(
                totalBytes: 256_000_000_000,
                availableBytes: 42_000_000_000
            )
        ))

        let decoded = try JSONDecoder().decode(
            DeviceSyncMessage.self,
            from: JSONEncoder().encode(message)
        )

        guard case .manifest(let manifest) = decoded else {
            Issue.record("Expected a manifest message")
            return
        }
        #expect(manifest.deviceName == "Listening Room iPhone")
        #expect(manifest.items == [item])
        #expect(manifest.storage?.totalBytes == 256_000_000_000)
        #expect(manifest.storage?.availableBytes == 42_000_000_000)
    }

    @Test("Individual transfer requests preserve the stable item ID")
    func requestRoundTrip() throws {
        let itemID = UUID()
        let data = try JSONEncoder().encode(DeviceSyncMessage.requestItem(itemID))
        let decoded = try JSONDecoder().decode(DeviceSyncMessage.self, from: data)

        guard case .requestItem(let decodedID) = decoded else {
            Issue.record("Expected an individual item request")
            return
        }
        #expect(decodedID == itemID)
    }

    @Test("Manifests from an older app remain compatible")
    func legacyManifestDecoding() throws {
        let item = makeItem()
        let encodedItem = try JSONEncoder().encode(item)
        let itemObject = try #require(
            JSONSerialization.jsonObject(with: encodedItem) as? [String: Any]
        )
        let legacyPayload: [String: Any] = [
            "kind": "manifest",
            "manifest": [
                "deviceName": "Older iPhone",
                "generatedAt": Date(timeIntervalSince1970: 1_725_000_000)
                    .timeIntervalSinceReferenceDate,
                "items": [itemObject],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyPayload)
        let decoded = try JSONDecoder().decode(DeviceSyncMessage.self, from: data)

        guard case .manifest(let manifest) = decoded else {
            Issue.record("Expected a manifest message")
            return
        }
        #expect(manifest.storage == nil)
        #expect(manifest.overlays == nil)
        #expect(manifest.playlistOverlays == nil)
        #expect(manifest.items == [item])
    }

    @Test("Manifest messages preserve Ongaku track overlays")
    func overlayRoundTrip() throws {
        let overlay = DeviceSyncTrackOverlay(
            sourceKey: "systemMusic:42",
            title: "夜のレコード",
            artist: "Ongaku Ensemble",
            album: "Listening Room",
            duration: 245,
            isFavorite: true,
            rating: 5,
            playCount: 12,
            skipCount: 2,
            lastPlayedAt: Date(timeIntervalSince1970: 1_725_000_100),
            displayTags: ["夜", "集中"],
            updatedAt: Date(timeIntervalSince1970: 1_725_000_200)
        )
        let message = DeviceSyncMessage.manifest(DeviceSyncManifest(
            deviceName: "Listening Room iPhone",
            generatedAt: Date(timeIntervalSince1970: 1_725_000_000),
            items: [],
            overlays: [overlay]
        ))

        let decoded = try JSONDecoder().decode(
            DeviceSyncMessage.self,
            from: JSONEncoder().encode(message)
        )
        guard case .manifest(let manifest) = decoded else {
            Issue.record("Expected a manifest message")
            return
        }
        #expect(manifest.overlays == [overlay])
    }

    @Test("Manifest messages preserve independent playlist overlays")
    func playlistOverlayRoundTrip() throws {
        let playlist = DeviceSyncPlaylistOverlay(
            id: UUID(),
            name: "Night Focus",
            tracks: [DeviceSyncTrackReference(
                sourceKey: "systemMusic:42",
                title: "夜のレコード",
                artist: "Ongaku Ensemble",
                album: "Listening Room",
                duration: 245
            )],
            createdAt: Date(timeIntervalSince1970: 1_725_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_725_000_200)
        )
        let data = try JSONEncoder().encode(DeviceSyncMessage.manifest(DeviceSyncManifest(
            deviceName: "Listening Room iPhone",
            generatedAt: .now,
            items: [],
            playlistOverlays: [playlist]
        )))
        let decoded = try JSONDecoder().decode(DeviceSyncMessage.self, from: data)
        guard case .manifest(let manifest) = decoded else {
            Issue.record("Expected a manifest message")
            return
        }
        #expect(manifest.playlistOverlays == [playlist])
    }

    @Test("Overlay identity matching tolerates display differences but rejects distant durations")
    func overlayIdentityMatching() {
        let local = makeOverlay(
            sourceKey: "ongakuManaged:local",
            title: "Ｎｉｇｈｔ Record",
            duration: 245
        )
        let near = makeOverlay(
            sourceKey: "systemMusic:phone",
            title: "night record",
            duration: 247.9
        )
        let distant = makeOverlay(
            sourceKey: "systemMusic:phone",
            title: "night record",
            duration: 249
        )

        #expect(near.matchesIdentity(of: local))
        #expect(!distant.matchesIdentity(of: local))
    }

    @Test("Selected overlays merge counters without replacing playback history")
    @MainActor
    func appliesSelectedOverlay() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let track = Track(
            id: UUID(),
            title: "Night Record",
            artist: "Ongaku Ensemble",
            album: "Listening Room",
            duration: 245,
            fileSize: 1_024,
            managedPath: root.appendingPathComponent("night.flac").path,
            sha256: String(repeating: "a", count: 64),
            addedAt: .distantPast,
            health: .verified
        )
        let originalEvent = PlaybackEvent(trackID: track.id, kind: .completed)
        let repository = LibraryRepository(rootURL: root)
        try await repository.save(document: LibraryDocument(
            tracks: [track],
            playbackEvents: [originalEvent]
        ))
        let store = LibraryStore(repository: repository)
        await store.load()
        var remote = makeOverlay(
            sourceKey: "systemMusic:phone",
            title: track.title,
            duration: track.duration
        )
        remote.playCount = 5
        remote.skipCount = 3

        let applied = await store.applySyncedTrackOverlays([
            DeviceSyncOverlayApplication(
                trackID: track.id,
                overlay: remote,
                fields: Set(DeviceSyncOverlayField.allCases)
            ),
        ])

        #expect(applied == 1)
        #expect(store.playbackEvents.map(\.id) == [originalEvent.id])
        #expect(store.playbackEvents.map(\.kind) == [.completed])
        #expect(store.playbackStatistics(for: track.id).playCount == 5)
        #expect(store.playbackStatistics(for: track.id).skipCount == 3)
        #expect(store.tracks.first?.isFavorite == true)
        #expect(store.tracks.first?.rating == 5)

        let restored = try await LibraryRepository(rootURL: root).load().document
        let restoredStatistics = PlaybackStatisticsResolver.statistics(
            events: restored.playbackEvents,
            tracks: restored.tracks
        )[track.id]
        #expect(restored.playbackEvents.map(\.id) == [originalEvent.id])
        #expect(restored.playbackEvents.map(\.kind) == [.completed])
        #expect(restoredStatistics?.playCount == 5)
        #expect(restoredStatistics?.skipCount == 3)
    }

    @Test("Overlay application changes only selected fields")
    @MainActor
    func appliesOnlySelectedOverlayFields() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let track = Track(
            id: UUID(),
            title: "Night Record",
            artist: "Ongaku Ensemble",
            album: "Listening Room",
            duration: 245,
            fileSize: 1_024,
            managedPath: root.appendingPathComponent("night.flac").path,
            sha256: String(repeating: "a", count: 64),
            addedAt: .distantPast,
            health: .verified
        )
        let repository = LibraryRepository(rootURL: root)
        try await repository.save(document: LibraryDocument(tracks: [track]))
        let store = LibraryStore(repository: repository)
        await store.load()
        var remote = makeOverlay(
            sourceKey: "systemMusic:phone",
            title: track.title,
            duration: track.duration
        )
        remote.playCount = 8
        remote.skipCount = 4
        var before = remote
        before.sourceKey = "ongakuManaged:\(track.id.uuidString)"
        before.isFavorite = false
        before.rating = 0
        before.playCount = 0
        before.skipCount = 0

        let applied = await store.applySyncedTrackOverlays([
            DeviceSyncOverlayApplication(
                trackID: track.id,
                overlay: remote,
                fields: [.rating]
            ),
        ])

        #expect(applied == 1)
        #expect(store.tracks.first?.rating == 5)
        #expect(store.tracks.first?.isFavorite == false)
        #expect(store.playbackStatistics(for: track.id).playCount == 0)
        #expect(store.playbackStatistics(for: track.id).skipCount == 0)

        let undo = await store.undoSyncedTrackOverlays([
            DeviceSyncAuditChange(
                trackID: track.id,
                title: track.title,
                before: before,
                after: remote,
                fields: [.rating]
            ),
        ])
        #expect(undo.restoredFieldCount == 1)
        #expect(undo.conflictFieldCount == 0)
        #expect(store.tracks.first?.rating == 0)
    }

    @Test("Overlay audit history persists and records conflict reasons")
    @MainActor
    func persistsOverlayAuditHistory() {
        let suiteName = "DeviceSyncTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Unable to create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let entry = DeviceSyncAuditEntry(
            id: UUID(),
            occurredAt: Date(timeIntervalSince1970: 1_725_000_000),
            deviceName: "Listening Room iPhone",
            changes: [],
            conflicts: [DeviceSyncAuditConflict(
                sourceKey: "systemMusic:ambiguous",
                title: "Night Record",
                reason: .ambiguous
            )],
            isUndone: false
        )

        let writer = PhoneSyncController(defaults: defaults)
        writer.recordOverlayAudit(entry)
        let reader = PhoneSyncController(defaults: defaults)

        #expect(reader.overlayAuditHistory == [entry])
    }

    @Test("Playlist sync preserves order and can be safely undone")
    @MainActor
    func appliesAndUndoesPlaylistOverlays() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Track(
            id: UUID(), title: "First", artist: "Ongaku Ensemble", album: "Set",
            duration: 180, fileSize: 1_024,
            managedPath: root.appendingPathComponent("first.flac").path,
            sha256: String(repeating: "a", count: 64), addedAt: .distantPast,
            health: .verified
        )
        let second = Track(
            id: UUID(), title: "Second", artist: "Ongaku Ensemble", album: "Set",
            duration: 210, fileSize: 1_024,
            managedPath: root.appendingPathComponent("second.flac").path,
            sha256: String(repeating: "b", count: 64), addedAt: .distantPast,
            health: .verified
        )
        let playlistID = UUID()
        let original = Playlist(
            id: playlistID,
            name: "Mac Order",
            entries: [
                PlaylistEntry(trackID: first.id),
                PlaylistEntry(trackID: second.id),
            ]
        )
        let repository = LibraryRepository(rootURL: root)
        try await repository.save(document: LibraryDocument(
            tracks: [first, second],
            playlists: [original]
        ))
        let store = LibraryStore(repository: repository)
        await store.load()
        let remote = DeviceSyncPlaylistOverlay(
            id: playlistID,
            name: "iPhone Order",
            tracks: [],
            createdAt: original.createdAt,
            updatedAt: Date(timeIntervalSince1970: 1_725_000_200)
        )

        let changes = try await store.applySyncedPlaylistOverlays([
            DeviceSyncPlaylistApplication(
                remote: remote,
                trackIDs: [second.id, first.id]
            ),
        ])

        #expect(changes.count == 1)
        #expect(store.playlists.first?.name == "iPhone Order")
        #expect(store.playlists.first?.entries.map(\.trackID) == [second.id, first.id])

        let undo = await store.undoSyncedPlaylistChanges(changes)
        #expect(undo.restoredFieldCount == 1)
        #expect(undo.conflictFieldCount == 0)
        #expect(store.playlists.first?.name == original.name)
        #expect(store.playlists.first?.entries.map(\.trackID) == [first.id, second.id])

        let reapplied = try await store.applySyncedPlaylistOverlays([
            DeviceSyncPlaylistApplication(remote: remote, trackIDs: [second.id, first.id]),
        ])
        try await store.updatePlaylist(
            id: playlistID,
            name: "Edited after sync",
            description: "",
            artworkData: nil,
            removesArtwork: false
        )
        let protectedUndo = await store.undoSyncedPlaylistChanges(reapplied)
        #expect(protectedUndo.restoredFieldCount == 0)
        #expect(protectedUndo.conflictFieldCount == 1)
        #expect(store.playlists.first?.name == "Edited after sync")
    }

    @Test("Overlay receipt survives message encoding")
    func overlayReceiptRoundTrip() throws {
        let receipt = DeviceSyncOverlayReceipt(
            id: UUID(),
            appliedAt: Date(timeIntervalSince1970: 1_725_000_000),
            items: [DeviceSyncOverlayReceiptItem(
                sourceKey: "systemMusic:phone",
                fields: [.favorite, .rating]
            )],
            ignoredCount: 2
        )
        let data = try JSONEncoder().encode(DeviceSyncMessage.overlayReceipt(receipt))
        let decoded = try JSONDecoder().decode(DeviceSyncMessage.self, from: data)
        guard case .overlayReceipt(let decodedReceipt) = decoded else {
            Issue.record("Expected an overlay receipt")
            return
        }
        #expect(decodedReceipt == receipt)
        #expect(decodedReceipt.appliedFieldCount == 2)
    }

    @Test("SHA-256 verification accepts the original and rejects changed metadata")
    func verifiesReceivedFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("song.m4a")
        let contents = Data("Ongaku transfer fixture".utf8)
        try contents.write(to: fileURL)
        let digest = try DeviceSyncFileIntegrity.sha256(of: fileURL)
        var item = makeItem(fileSize: Int64(contents.count), sha256: digest)

        #expect(try DeviceSyncFileIntegrity.verified(fileURL, matches: item))

        item.fileSize += 1
        #expect(try !DeviceSyncFileIntegrity.verified(fileURL, matches: item))

        item.fileSize -= 1
        item.sha256 = String(repeating: "0", count: 64)
        #expect(try !DeviceSyncFileIntegrity.verified(fileURL, matches: item))
    }

    private func makeItem(
        fileSize: Int64 = 1_024,
        sha256: String = String(repeating: "a", count: 64)
    ) -> DeviceSyncItem {
        DeviceSyncItem(
            id: UUID(),
            title: "夜のレコード",
            artist: "Ongaku Ensemble",
            album: "Listening Room",
            fileName: "night-record.flac",
            fileSize: fileSize,
            sha256: sha256,
            modifiedAt: Date(timeIntervalSince1970: 1_725_000_000)
        )
    }

    private func makeOverlay(
        sourceKey: String,
        title: String,
        duration: TimeInterval
    ) -> DeviceSyncTrackOverlay {
        DeviceSyncTrackOverlay(
            sourceKey: sourceKey,
            title: title,
            artist: "Ongaku Ensemble",
            album: "Listening Room",
            duration: duration,
            isFavorite: true,
            rating: 5,
            playCount: 12,
            skipCount: 2,
            lastPlayedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 1_725_000_200)
        )
    }
}
