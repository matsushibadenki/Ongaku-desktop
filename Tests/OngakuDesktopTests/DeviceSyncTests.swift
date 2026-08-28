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
        #expect(manifest.items == [item])
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
}
