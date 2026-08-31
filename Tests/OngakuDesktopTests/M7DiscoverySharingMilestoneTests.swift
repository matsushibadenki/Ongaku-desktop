import Foundation
import Testing
@testable import OngakuDesktop

@Suite("M7 discovery and sharing milestone")
struct M7DiscoverySharingMilestoneTests {
    @Test("Social features start private with listening-history sharing disabled")
    @MainActor
    func privateByDefault() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let settings = SocialPrivacySettings(defaults: fixture.defaults)
        #expect(settings.visibility == .privateOnly)
        #expect(!settings.sharesListeningHistory)
        #expect(settings.invites.isEmpty)
        #expect(settings.blockedProfileIDs.isEmpty)
        #expect(settings.auditEntries.isEmpty)
    }

    @Test("Profile visibility and history consent persist independently")
    @MainActor
    func explicitOptInPersistence() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let settings = SocialPrivacySettings(defaults: fixture.defaults)
        settings.setVisibility(.publicProfile)
        #expect(!settings.sharesListeningHistory)
        settings.setListeningHistorySharing(true)

        let restored = SocialPrivacySettings(defaults: fixture.defaults)
        #expect(restored.visibility == .publicProfile)
        #expect(restored.sharesListeningHistory)
        #expect(restored.auditEntries.map(\.action).contains(.visibilityChanged))
        #expect(restored.auditEntries.map(\.action).contains(.historySharingEnabled))
    }

    @Test("Invitations expire and cannot be accepted after their deadline")
    @MainActor
    func invitationExpiry() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let start = Date(timeIntervalSince1970: 1_000)
        let settings = SocialPrivacySettings(defaults: fixture.defaults, now: start)
        let inviteID = try settings.createInvite(
            playlistID: UUID(),
            profileID: "Listener@example.com",
            role: .editor,
            lifetime: 120,
            now: start
        )
        #expect(throws: SocialSafetyError.inviteExpired) {
            try settings.acceptInvite(
                inviteID,
                by: "listener@example.com",
                now: start.addingTimeInterval(121)
            )
        }
        #expect(settings.invites.first?.status == .expired)
        #expect(settings.auditEntries.first?.action == .inviteExpired)
    }

    @Test("Blocking a profile revokes its pending invitations and rejects new ones")
    @MainActor
    func blockingRevokesInvitations() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let settings = SocialPrivacySettings(defaults: fixture.defaults)
        let inviteID = try settings.createInvite(
            playlistID: UUID(),
            profileID: "blocked-listener",
            role: .viewer
        )
        try settings.blockProfile("blocked-listener")
        #expect(settings.blockedProfileIDs == ["blocked-listener"])
        #expect(settings.invites.first(where: { $0.id == inviteID })?.status == .revoked)
        #expect(throws: SocialSafetyError.blockedProfile) {
            try settings.createInvite(
                playlistID: UUID(),
                profileID: "blocked-listener",
                role: .editor
            )
        }
        #expect(settings.auditEntries.map(\.action).prefix(2).contains(.profileBlocked))
        #expect(settings.auditEntries.map(\.action).prefix(2).contains(.inviteRevoked))
    }

    @Test("Audit history is bounded and complete deletion restores the private default")
    @MainActor
    func auditRetentionAndDeletion() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let settings = SocialPrivacySettings(defaults: fixture.defaults)
        for index in 0..<260 {
            settings.setVisibility(index.isMultiple(of: 2) ? .publicProfile : .unlisted)
        }
        #expect(settings.auditEntries.count == SocialPrivacySettings.maximumAuditEntries)
        settings.setListeningHistorySharing(true)
        _ = try settings.createInvite(
            playlistID: UUID(),
            profileID: "delete-me",
            role: .editor
        )
        try settings.blockProfile("blocked-user")

        settings.deleteAllSocialData()
        #expect(settings.visibility == .privateOnly)
        #expect(!settings.sharesListeningHistory)
        #expect(settings.invites.isEmpty)
        #expect(settings.blockedProfileIDs.isEmpty)
        #expect(settings.auditEntries.isEmpty)
        #expect(fixture.defaults.data(forKey: SocialPrivacySettings.defaultsKey) == nil)

        let restored = SocialPrivacySettings(defaults: fixture.defaults)
        #expect(restored.visibility == .privateOnly)
        #expect(!restored.sharesListeningHistory)
        #expect(restored.auditEntries.isEmpty)
    }

    private func makeFixture() throws -> Fixture {
        let name = "OngakuDesktopTests.Social.\(UUID().uuidString)"
        return Fixture(
            name: name,
            defaults: try #require(UserDefaults(suiteName: name))
        )
    }

    private struct Fixture {
        let name: String
        let defaults: UserDefaults

        func cleanUp() {
            defaults.removePersistentDomain(forName: name)
        }
    }
}
