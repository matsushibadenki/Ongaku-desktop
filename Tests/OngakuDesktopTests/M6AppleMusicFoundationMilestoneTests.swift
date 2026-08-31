import Foundation
import Testing
@testable import OngakuDesktop

@Suite("M6 Apple Music foundation milestone")
struct M6AppleMusicFoundationMilestoneTests {
    @Test("Permission states disable remote capabilities without disabling local music", arguments: [
        AppleMusicStoreController.AuthorizationState.notDetermined,
        .denied,
        .restricted,
    ])
    func permissionFallback(_ authorization: AppleMusicStoreController.AuthorizationState) {
        let policy = AppleMusicAvailabilityPolicy.resolve(
            authorization: authorization,
            canPlayCatalogContent: true,
            canBecomeSubscriber: true,
            hasCloudLibraryEnabled: true,
            hasRetryableFailure: false
        )
        #expect(!policy.canBrowseCatalog)
        #expect(!policy.canPlayCatalog)
        #expect(!policy.canModifyCloudLibrary)
        #expect(!policy.shouldOfferSubscription)
        #expect(!policy.shouldOfferRetry)
        #expect(policy.localLibraryRemainsAvailable)
    }

    @Test("Subscribers receive playback and cloud-library capabilities independently")
    func subscriberCapabilities() {
        let withoutCloudLibrary = AppleMusicAvailabilityPolicy.resolve(
            authorization: .authorized,
            canPlayCatalogContent: true,
            canBecomeSubscriber: false,
            hasCloudLibraryEnabled: false,
            hasRetryableFailure: false
        )
        #expect(withoutCloudLibrary.canBrowseCatalog)
        #expect(withoutCloudLibrary.canPlayCatalog)
        #expect(!withoutCloudLibrary.canModifyCloudLibrary)
        #expect(!withoutCloudLibrary.shouldOfferSubscription)

        let withCloudLibrary = AppleMusicAvailabilityPolicy.resolve(
            authorization: .authorized,
            canPlayCatalogContent: true,
            canBecomeSubscriber: false,
            hasCloudLibraryEnabled: true,
            hasRetryableFailure: false
        )
        #expect(withCloudLibrary.canPlayCatalog)
        #expect(withCloudLibrary.canModifyCloudLibrary)
        #expect(withCloudLibrary.localLibraryRemainsAvailable)
    }

    @Test("Non-subscribers receive a subscription path but no catalog playback")
    func nonSubscriberFallback() {
        let policy = AppleMusicAvailabilityPolicy.resolve(
            authorization: .authorized,
            canPlayCatalogContent: false,
            canBecomeSubscriber: true,
            hasCloudLibraryEnabled: false,
            hasRetryableFailure: false
        )
        #expect(policy.canBrowseCatalog)
        #expect(!policy.canPlayCatalog)
        #expect(!policy.canModifyCloudLibrary)
        #expect(policy.shouldOfferSubscription)
        #expect(policy.localLibraryRemainsAvailable)
    }

    @Test("Offline or regional failures expose retry while preserving local playback")
    func transientFailureFallback() {
        let policy = AppleMusicAvailabilityPolicy.resolve(
            authorization: .authorized,
            canPlayCatalogContent: true,
            canBecomeSubscriber: false,
            hasCloudLibraryEnabled: true,
            hasRetryableFailure: true
        )
        #expect(!policy.canBrowseCatalog)
        #expect(!policy.canPlayCatalog)
        #expect(!policy.canModifyCloudLibrary)
        #expect(policy.shouldOfferRetry)
        #expect(policy.localLibraryRemainsAvailable)
    }

    @Test("Bulk queue editing preserves the playing entry")
    func bulkQueueEditing() {
        let items = ["playing", "one", "two", "three"].map {
            AppleMusicQueueItem(
                id: $0,
                title: $0,
                subtitle: "Artist",
                duration: 180,
                artworkURL: nil
            )
        }
        let reordered = AppleMusicQueueEditor.moving(
            items,
            fromOffsets: IndexSet([1, 3]),
            toOffset: 4,
            currentItemID: "playing"
        )
        #expect(reordered.map(\.id) == ["playing", "two", "one", "three"])
        let removed = AppleMusicQueueEditor.removing(
            reordered,
            ids: ["playing", "one", "three"],
            currentItemID: "playing"
        )
        #expect(removed.map(\.id) == ["playing", "two"])
    }

    @Test("Service failures are rejected for authorization, region, conflict, rate, and server cases")
    func serviceFailureClasses() throws {
        try AppleMusicStoreController.validateStatus(200, accepted: [200])
        for status in [401, 403, 404, 409, 412, 429, 500, 503] {
            #expect(throws: (any Error).self) {
                try AppleMusicStoreController.validateStatus(status, accepted: [200])
            }
        }
    }
}
