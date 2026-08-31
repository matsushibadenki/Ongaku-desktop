import Combine
import Foundation

enum SocialProfileVisibility: String, Codable, CaseIterable, Identifiable, Sendable {
    case privateOnly
    case unlisted
    case publicProfile

    var id: String { rawValue }
    var localizationKey: String { "settings.social.visibility.\(rawValue)" }
}

enum SocialCollaboratorRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case viewer
    case editor

    var id: String { rawValue }
    var localizationKey: String { "settings.social.role.\(rawValue)" }
}

enum SocialInviteStatus: String, Codable, Sendable {
    case pending
    case accepted
    case revoked
    case expired
}

struct SocialInvite: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let playlistID: UUID
    let invitedProfileID: String
    let role: SocialCollaboratorRole
    let createdAt: Date
    let expiresAt: Date
    var status: SocialInviteStatus
}

enum SocialAuditAction: String, Codable, Sendable {
    case visibilityChanged
    case historySharingEnabled
    case historySharingDisabled
    case inviteCreated
    case inviteAccepted
    case inviteRevoked
    case inviteExpired
    case profileBlocked
    case profileUnblocked

    var localizationKey: String { "settings.social.audit.\(rawValue)" }
}

struct SocialAuditEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let action: SocialAuditAction
    let subjectID: String?
    let occurredAt: Date
}

enum SocialSafetyError: LocalizedError, Equatable {
    case invalidProfile
    case blockedProfile
    case inviteExpired
    case inviteUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidProfile: L10n.text("settings.social.error.invalidProfile")
        case .blockedProfile: L10n.text("settings.social.error.blockedProfile")
        case .inviteExpired: L10n.text("settings.social.error.inviteExpired")
        case .inviteUnavailable: L10n.text("settings.social.error.inviteUnavailable")
        }
    }
}

@MainActor
final class SocialPrivacySettings: ObservableObject {
    nonisolated static let defaultsKey = "social.privacy.v1"
    nonisolated static let maximumAuditEntries = 200
    nonisolated static let maximumInviteLifetime: TimeInterval = 30 * 24 * 60 * 60

    @Published private(set) var visibility: SocialProfileVisibility
    @Published private(set) var sharesListeningHistory: Bool
    @Published private(set) var invites: [SocialInvite]
    @Published private(set) var blockedProfileIDs: Set<String>
    @Published private(set) var auditEntries: [SocialAuditEntry]

    private struct PersistedState: Codable {
        var visibility: SocialProfileVisibility
        var sharesListeningHistory: Bool
        var invites: [SocialInvite]
        var blockedProfileIDs: Set<String>
        var auditEntries: [SocialAuditEntry]
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, now: Date = .now) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(PersistedState.self, from: data) {
            visibility = saved.visibility
            sharesListeningHistory = saved.sharesListeningHistory
            invites = saved.invites
            blockedProfileIDs = saved.blockedProfileIDs
            auditEntries = Array(saved.auditEntries.prefix(Self.maximumAuditEntries))
        } else {
            visibility = .privateOnly
            sharesListeningHistory = false
            invites = []
            blockedProfileIDs = []
            auditEntries = []
        }
        expireInvites(at: now)
        persist()
    }

    var activeInvites: [SocialInvite] {
        invites.filter { $0.status == .pending }.sorted { $0.expiresAt < $1.expiresAt }
    }

    func setVisibility(_ newValue: SocialProfileVisibility, at date: Date = .now) {
        guard visibility != newValue else { return }
        visibility = newValue
        record(.visibilityChanged, subjectID: newValue.rawValue, at: date)
        persist()
    }

    func setListeningHistorySharing(_ enabled: Bool, at date: Date = .now) {
        guard sharesListeningHistory != enabled else { return }
        sharesListeningHistory = enabled
        record(enabled ? .historySharingEnabled : .historySharingDisabled, at: date)
        persist()
    }

    @discardableResult
    func createInvite(
        playlistID: UUID,
        profileID rawProfileID: String,
        role: SocialCollaboratorRole,
        lifetime: TimeInterval = 7 * 24 * 60 * 60,
        now: Date = .now
    ) throws -> SocialInvite.ID {
        let profileID = try normalizedProfileID(rawProfileID)
        guard !blockedProfileIDs.contains(profileID) else {
            throw SocialSafetyError.blockedProfile
        }
        let safeLifetime = min(max(lifetime, 60), Self.maximumInviteLifetime)
        let invite = SocialInvite(
            id: UUID(),
            playlistID: playlistID,
            invitedProfileID: profileID,
            role: role,
            createdAt: now,
            expiresAt: now.addingTimeInterval(safeLifetime),
            status: .pending
        )
        invites.append(invite)
        record(.inviteCreated, subjectID: profileID, at: now)
        persist()
        return invite.id
    }

    func acceptInvite(_ id: SocialInvite.ID, by rawProfileID: String, now: Date = .now) throws {
        let profileID = try normalizedProfileID(rawProfileID)
        guard !blockedProfileIDs.contains(profileID) else {
            throw SocialSafetyError.blockedProfile
        }
        guard let index = invites.firstIndex(where: { $0.id == id }),
              invites[index].status == .pending,
              invites[index].invitedProfileID == profileID else {
            throw SocialSafetyError.inviteUnavailable
        }
        guard invites[index].expiresAt > now else {
            invites[index].status = .expired
            record(.inviteExpired, subjectID: profileID, at: now)
            persist()
            throw SocialSafetyError.inviteExpired
        }
        invites[index].status = .accepted
        record(.inviteAccepted, subjectID: profileID, at: now)
        persist()
    }

    func revokeInvite(_ id: SocialInvite.ID, at date: Date = .now) {
        guard let index = invites.firstIndex(where: { $0.id == id }),
              invites[index].status == .pending else { return }
        invites[index].status = .revoked
        record(.inviteRevoked, subjectID: invites[index].invitedProfileID, at: date)
        persist()
    }

    func expireInvites(at date: Date = .now) {
        var expiredProfileIDs: [String] = []
        for index in invites.indices
        where invites[index].status == .pending && invites[index].expiresAt <= date {
            invites[index].status = .expired
            expiredProfileIDs.append(invites[index].invitedProfileID)
        }
        for profileID in expiredProfileIDs {
            record(.inviteExpired, subjectID: profileID, at: date)
        }
        if !expiredProfileIDs.isEmpty { persist() }
    }

    func blockProfile(_ rawProfileID: String, at date: Date = .now) throws {
        let profileID = try normalizedProfileID(rawProfileID)
        guard blockedProfileIDs.insert(profileID).inserted else { return }
        for index in invites.indices
        where invites[index].invitedProfileID == profileID && invites[index].status == .pending {
            invites[index].status = .revoked
            record(.inviteRevoked, subjectID: profileID, at: date)
        }
        record(.profileBlocked, subjectID: profileID, at: date)
        persist()
    }

    func unblockProfile(_ profileID: String, at date: Date = .now) {
        guard blockedProfileIDs.remove(profileID) != nil else { return }
        record(.profileUnblocked, subjectID: profileID, at: date)
        persist()
    }

    func deleteAllSocialData() {
        visibility = .privateOnly
        sharesListeningHistory = false
        invites = []
        blockedProfileIDs = []
        auditEntries = []
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    private func normalizedProfileID(_ rawValue: String) throws -> String {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (3...80).contains(normalized.count),
              normalized.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || "._-@".unicodeScalars.contains($0)
              }) else {
            throw SocialSafetyError.invalidProfile
        }
        return normalized
    }

    private func record(
        _ action: SocialAuditAction,
        subjectID: String? = nil,
        at date: Date
    ) {
        auditEntries.insert(
            SocialAuditEntry(id: UUID(), action: action, subjectID: subjectID, occurredAt: date),
            at: 0
        )
        if auditEntries.count > Self.maximumAuditEntries {
            auditEntries.removeLast(auditEntries.count - Self.maximumAuditEntries)
        }
    }

    private func persist() {
        let state = PersistedState(
            visibility: visibility,
            sharesListeningHistory: sharesListeningHistory,
            invites: invites,
            blockedProfileIDs: blockedProfileIDs,
            auditEntries: auditEntries
        )
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
