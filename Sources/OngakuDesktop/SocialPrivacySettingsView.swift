import SwiftUI

struct SocialPrivacySettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var social: SocialPrivacySettings
    @State private var inviteeProfileID = ""
    @State private var selectedPlaylistID: Playlist.ID?
    @State private var selectedRole: SocialCollaboratorRole = .editor
    @State private var blockedProfileDraft = ""
    @State private var errorMessage: String?
    @State private var confirmsDeletion = false

    init(social: SocialPrivacySettings) {
        self.social = social
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.spaceLG) {
                header
                privacySection
                Divider()
                inviteSection
                Divider()
                blockSection
                Divider()
                auditSection
                Divider()
                deletionSection
            }
            .padding(.bottom, AppTheme.spaceMD)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: PreferencesContentHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            }
        }
        .scrollIndicators(.automatic)
        .onAppear {
            social.expireInvites()
            if selectedPlaylistID == nil { selectedPlaylistID = library.playlists.first?.id }
        }
        .alert(
            L10n.text("settings.social.error.title"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            L10n.text("settings.social.delete.title"),
            isPresented: $confirmsDeletion,
            titleVisibility: .visible
        ) {
            Button(L10n.text("settings.social.delete.action"), role: .destructive) {
                social.deleteAllSocialData()
                inviteeProfileID = ""
                blockedProfileDraft = ""
            }
            Button(L10n.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("settings.social.delete.confirmation"))
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: AppTheme.spaceMD) {
            Image(systemName: "person.2.badge.gearshape.fill")
                .font(.title2)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 34, height: 34)
                .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("settings.social.title"))
                    .font(.title2.weight(.semibold))
                Text(L10n.text("settings.social.subtitle"))
                    .font(.callout)
                    .foregroundStyle(AppTheme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceMD) {
            sectionTitle("settings.social.privacy.title", icon: "lock.shield")
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("settings.social.visibility.title"))
                        .font(.headline)
                    Text(L10n.text("settings.social.visibility.description"))
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryInk)
                }
                Spacer()
                Picker("", selection: visibilityBinding) {
                    ForEach(SocialProfileVisibility.allCases) { option in
                        Text(L10n.text(option.localizationKey)).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 170)
            }
            Toggle(isOn: historySharingBinding) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("settings.social.history.title"))
                        .font(.headline)
                    Text(L10n.text("settings.social.history.description"))
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryInk)
                }
            }
            Label(L10n.text("settings.social.localOnly"), systemImage: "internaldrive")
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryInk)
        }
    }

    private var inviteSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceMD) {
            sectionTitle("settings.social.invites.title", icon: "envelope.badge")
            Text(L10n.text("settings.social.invites.description"))
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryInk)
            HStack(spacing: AppTheme.spaceSM) {
                TextField(
                    L10n.text("settings.social.profileID.placeholder"),
                    text: $inviteeProfileID
                )
                Picker("", selection: $selectedPlaylistID) {
                    Text(L10n.text("settings.social.playlist.choose")).tag(Playlist.ID?.none)
                    ForEach(library.playlists.filter { $0.smartDefinition == nil }) { playlist in
                        Text(playlist.name).tag(Playlist.ID?.some(playlist.id))
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                Picker("", selection: $selectedRole) {
                    ForEach(SocialCollaboratorRole.allCases) { role in
                        Text(L10n.text(role.localizationKey)).tag(role)
                    }
                }
                .labelsHidden()
                .frame(width: 90)
                Button(L10n.text("settings.social.invites.create")) { createInvite() }
                    .disabled(selectedPlaylistID == nil || inviteeProfileID.isEmpty)
            }
            if social.activeInvites.isEmpty {
                Text(L10n.text("settings.social.invites.empty"))
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryInk)
            } else {
                ForEach(social.activeInvites) { invite in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(invite.invitedProfileID).font(.callout.weight(.medium))
                            Text(inviteSummary(invite))
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryInk)
                        }
                        Spacer()
                        Button(L10n.text("settings.social.invites.revoke"), role: .destructive) {
                            social.revokeInvite(invite.id)
                        }
                    }
                }
            }
        }
    }

    private var blockSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceMD) {
            sectionTitle("settings.social.block.title", icon: "hand.raised.fill")
            Text(L10n.text("settings.social.block.description"))
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryInk)
            HStack(spacing: AppTheme.spaceSM) {
                TextField(
                    L10n.text("settings.social.profileID.placeholder"),
                    text: $blockedProfileDraft
                )
                Button(L10n.text("settings.social.block.action")) { blockProfile() }
                    .disabled(blockedProfileDraft.isEmpty)
            }
            ForEach(social.blockedProfileIDs.sorted(), id: \.self) { profileID in
                HStack {
                    Label(profileID, systemImage: "person.crop.circle.badge.xmark")
                    Spacer()
                    Button(L10n.text("settings.social.block.unblock")) {
                        social.unblockProfile(profileID)
                    }
                }
            }
        }
    }

    private var auditSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceMD) {
            sectionTitle("settings.social.audit.title", icon: "clock.arrow.circlepath")
            if social.auditEntries.isEmpty {
                Text(L10n.text("settings.social.audit.empty"))
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryInk)
            } else {
                ForEach(social.auditEntries.prefix(12)) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        Text(L10n.text(entry.action.localizationKey))
                            .font(.caption)
                        if let subjectID = entry.subjectID {
                            Text(subjectID)
                                .font(.caption.monospaced())
                                .foregroundStyle(AppTheme.secondaryInk)
                        }
                        Spacer()
                        Text(entry.occurredAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(AppTheme.secondaryInk)
                    }
                }
            }
        }
    }

    private var deletionSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("settings.social.delete.title"))
                    .font(.headline)
                Text(L10n.text("settings.social.delete.description"))
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryInk)
            }
            Spacer()
            Button(L10n.text("settings.social.delete.action"), role: .destructive) {
                confirmsDeletion = true
            }
        }
    }

    private func sectionTitle(_ key: String, icon: String) -> some View {
        Label(L10n.text(key), systemImage: icon)
            .font(.headline)
    }

    private var visibilityBinding: Binding<SocialProfileVisibility> {
        Binding(get: { social.visibility }, set: { social.setVisibility($0) })
    }

    private var historySharingBinding: Binding<Bool> {
        Binding(
            get: { social.sharesListeningHistory },
            set: { social.setListeningHistorySharing($0) }
        )
    }

    private func createInvite() {
        guard let selectedPlaylistID else { return }
        do {
            try social.createInvite(
                playlistID: selectedPlaylistID,
                profileID: inviteeProfileID,
                role: selectedRole
            )
            inviteeProfileID = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func blockProfile() {
        do {
            try social.blockProfile(blockedProfileDraft)
            blockedProfileDraft = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func inviteSummary(_ invite: SocialInvite) -> String {
        let playlistName = library.playlists.first(where: { $0.id == invite.playlistID })?.name
            ?? L10n.text("settings.social.playlist.unknown")
        return L10n.format(
            "settings.social.invites.summary",
            playlistName,
            L10n.text(invite.role.localizationKey),
            invite.expiresAt.formatted(date: .abbreviated, time: .shortened)
        )
    }
}
