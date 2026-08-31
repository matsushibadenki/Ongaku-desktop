import SwiftUI

struct DeviceSyncView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var sync: PhoneSyncController
    @State private var selection: SyncCollection = .phone
    @State private var syncMode: SyncMode = .sync
    @State private var bulkScope: BulkSyncScope = .all
    @State private var selectedArtists: Set<String> = []
    @State private var selectedAlbums: Set<AlbumSelection> = []
    @State private var selectedSongIDs: Set<UUID> = []
    @State private var allSongsPolicy: AllSongsPolicy = .addMissing
    @State private var capacityPriority: CapacityPriority = .recentlyModified
    @State private var capacityReserve: CapacityReserve = .oneGB
    @State private var isShowingOverlayPreview = false
    @State private var isShowingPlaylistPreview = false
    @State private var isShowingOverlayAudit = false

    private static let mobileAppURL = URL(
        string: "https://apps.apple.com/jp/app/ongaku-%E9%99%90%E7%95%8C%E3%81%BE%E3%81%A7%E9%AB%98%E9%9F%B3%E8%B3%AA%E3%82%92%E6%B1%82%E3%82%81%E3%82%8B%E3%83%8F%E3%82%A4%E3%83%AC%E3%82%BE%E9%9F%B3%E6%A5%BD%E3%83%97%E3%83%AC%E3%83%BC%E3%83%A4%E3%83%BC/id6761979714"
    )!

    private enum SyncCollection: String, CaseIterable, Identifiable {
        case phone
        case mac

        var id: String { rawValue }
        var titleKey: String { "deviceSync.collection.\(rawValue)" }
    }

    private enum SyncMode: String, CaseIterable, Identifiable {
        case sync
        case individual

        var id: String { rawValue }
        var titleKey: String { "deviceSync.mode.\(rawValue)" }
    }

    private enum BulkSyncScope: String, CaseIterable, Identifiable {
        case all
        case artists
        case albums
        case songs

        var id: String { rawValue }
        var titleKey: String { "deviceSync.bulk.scope.\(rawValue)" }
    }

    private enum AllSongsPolicy: String, CaseIterable, Identifiable {
        case addMissing
        case downloadMissing
        case fillCapacity
        case mergeBothWays

        var id: String { rawValue }
        var titleKey: String { "deviceSync.bulk.policy.\(rawValue)" }
        var descriptionKey: String { "deviceSync.bulk.policy.\(rawValue).description" }
    }

    private enum CapacityPriority: String, CaseIterable, Identifiable {
        case recentlyModified
        case libraryOrder
        case smallestFirst

        var id: String { rawValue }
        var titleKey: String { "deviceSync.bulk.priority.\(rawValue)" }
    }

    private enum CapacityReserve: Int64, CaseIterable, Identifiable {
        case fiveHundredMB = 500_000_000
        case oneGB = 1_000_000_000
        case twoGB = 2_000_000_000
        case fiveGB = 5_000_000_000

        var id: Int64 { rawValue }
    }

    private struct AlbumSelection: Hashable, Identifiable {
        var artist: String
        var album: String
        var id: String { "\(artist)\u{0}\(album)" }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 820, minHeight: 640)
        .accessibilityIdentifier("device-sync.window")
        .background(AppTheme.canvas)
        .sheet(isPresented: $isShowingOverlayPreview) {
            OverlaySyncPreviewSheet()
                .environmentObject(library)
                .environmentObject(sync)
        }
        .sheet(isPresented: $isShowingOverlayAudit) {
            OverlaySyncAuditSheet()
                .environmentObject(library)
                .environmentObject(sync)
        }
        .sheet(isPresented: $isShowingPlaylistPreview) {
            PlaylistSyncPreviewSheet()
                .environmentObject(library)
                .environmentObject(sync)
        }
        .onAppear {
            sync.updateLocalTracks(
                library.tracks,
                playbackEvents: library.playbackEvents,
                playlists: library.playlists,
                displayTags: library.syncedDisplayTags
            )
            sync.start()
        }
        .onChange(of: library.contentRevision) {
            sync.updateLocalTracks(
                library.tracks,
                playbackEvents: library.playbackEvents,
                playlists: library.playlists,
                displayTags: library.syncedDisplayTags
            )
        }
    }

    private var header: some View {
        HStack(spacing: AppTheme.spaceMD) {
            VStack(alignment: .leading, spacing: AppTheme.spaceXS) {
                Text(L10n.text("deviceSync.title"))
                    .font(.title2.weight(.semibold))
                Text(connectionDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: AppTheme.spaceMD)

            if !sync.usbMobileDevices.isEmpty {
                Menu {
                    Button(L10n.text("deviceSync.usb.openFinder"), systemImage: "folder") {
                        sync.openFinderForUSBFileSharing()
                    }
                } label: {
                    Label(L10n.text("deviceSync.usb.connected"), systemImage: "cable.connector")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(AppTheme.good)
                        .padding(.horizontal, AppTheme.spaceSM)
                        .padding(.vertical, AppTheme.spaceXS)
                        .background(AppTheme.good.opacity(0.12), in: Capsule())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if case .connected = sync.connectionState {
                Button(L10n.text("deviceSync.disconnect")) {
                    sync.disconnect()
                }
            }

            Button(L10n.text("deviceSync.audit.title"), systemImage: "clock.arrow.circlepath") {
                isShowingOverlayAudit = true
            }
            .disabled(sync.overlayAuditHistory.isEmpty)

            Button(L10n.text("common.close")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("device-sync.close")
        }
        .padding(AppTheme.spaceLG)
    }

    @ViewBuilder
    private var content: some View {
        switch sync.connectionState {
        case .connected:
            connectedContent
        case .failed(let message):
            VStack(spacing: AppTheme.spaceLG) {
                ContentUnavailableView {
                    Label(L10n.text("deviceSync.error.title"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button(L10n.text("deviceSync.discovery.retry"), systemImage: "arrow.clockwise") {
                        sync.retryDiscovery()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("device-sync.retry")
                }

                mobileAppCard
                    .frame(maxWidth: 620)

                if !sync.usbMobileDevices.isEmpty {
                    usbConnectionCard
                        .frame(maxWidth: 620)
                }
            }
            .padding(AppTheme.spaceLG)
        default:
            discoveryContent
        }
    }

    private var discoveryContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceLG) {
            Label(L10n.text("deviceSync.discovery.title"), systemImage: "iphone.radiowaves.left.and.right")
                .font(.headline)

            Text(L10n.text("deviceSync.discovery.description"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: 560, alignment: .leading)

            if !sync.usbMobileDevices.isEmpty {
                usbConnectionCard
            }

            if let connectingPhoneName {
                HStack(alignment: .top, spacing: AppTheme.spaceMD) {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.format("deviceSync.connect.waiting.title", connectingPhoneName))
                            .font(.headline)
                        Text(L10n.text("deviceSync.connect.waiting.description"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppTheme.spaceMD)
                .background(AppTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(AppTheme.accent.opacity(0.28), lineWidth: 1)
                }
            }

            mobileAppCard

            if sync.discoveredPhones.isEmpty {
                VStack(spacing: AppTheme.spaceMD) {
                    HStack(spacing: AppTheme.spaceSM) {
                        ProgressView()
                        Text(L10n.text("deviceSync.discovery.searching"))
                            .foregroundStyle(.secondary)
                    }

                    Text(L10n.text("deviceSync.discovery.permissionHelp"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(L10n.text("deviceSync.discovery.retry"), systemImage: "arrow.clockwise") {
                        sync.retryDiscovery()
                    }
                    .accessibilityIdentifier("device-sync.retry")
                }
                .frame(maxWidth: .infinity, minHeight: 180)
                .padding(.horizontal, AppTheme.spaceMD)
            } else {
                List(sync.discoveredPhones) { phone in
                    HStack(spacing: AppTheme.spaceMD) {
                        Image(systemName: "iphone")
                            .font(.title2)
                            .foregroundStyle(AppTheme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(phone.name)
                                .font(.headline)
                            Text(L10n.format("deviceSync.pairingCode", phone.pairingCode))
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if connectingPhoneName == phone.name {
                            Label(L10n.text("deviceSync.connect.waiting.button"), systemImage: "iphone.and.arrow.forward")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            Button(L10n.text("deviceSync.connect")) {
                                sync.connect(to: phone)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(connectingPhoneName != nil)
                            .accessibilityIdentifier("device-sync.connect.\(phone.id)")
                        }
                    }
                    .padding(.vertical, AppTheme.spaceXS)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .padding(AppTheme.spaceLG)
    }

    private var mobileAppCard: some View {
        HStack(spacing: AppTheme.spaceMD) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.title2.weight(.medium))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 44, height: 44)
                .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("deviceSync.mobileApp.title"))
                    .font(.headline)
                Text(L10n.text("deviceSync.mobileApp.description"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: AppTheme.spaceMD)

            Link(destination: Self.mobileAppURL) {
                Label(L10n.text("deviceSync.mobileApp.download"), systemImage: "arrow.up.right")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint(L10n.text("deviceSync.mobileApp.accessibilityHint"))
        }
        .padding(AppTheme.spaceMD)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(AppTheme.accent.opacity(0.22), lineWidth: 1)
        }
    }

    private var usbConnectionCard: some View {
        HStack(alignment: .top, spacing: AppTheme.spaceMD) {
            Image(systemName: "cable.connector")
                .font(.title2)
                .foregroundStyle(AppTheme.good)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.format("deviceSync.usb.deviceDetected", usbDeviceNames))
                    .font(.headline)
                Text(L10n.text("deviceSync.usb.description"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: AppTheme.spaceMD)

            Button(L10n.text("deviceSync.usb.openFinder"), systemImage: "folder") {
                sync.openFinderForUSBFileSharing()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppTheme.spaceMD)
        .background(AppTheme.good.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppTheme.good.opacity(0.24), lineWidth: 1)
        }
    }

    private var usbDeviceNames: String {
        sync.usbMobileDevices.map(\.name).joined(separator: ", ")
    }

    private var connectedContent: some View {
        VStack(spacing: 0) {
            Picker(L10n.text("deviceSync.mode.title"), selection: $syncMode) {
                ForEach(SyncMode.allCases) { mode in
                    Text(L10n.text(mode.titleKey)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, AppTheme.spaceLG)
            .padding(.top, AppTheme.spaceMD)

            if !sync.remoteOverlays.isEmpty {
                Button {
                    isShowingOverlayPreview = true
                } label: {
                    HStack(spacing: AppTheme.spaceSM) {
                        Image(systemName: "slider.horizontal.3")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.text("deviceSync.overlay.review"))
                                .font(.headline)
                            Text(L10n.format(
                                "deviceSync.overlay.receivedCount",
                                sync.remoteOverlays.count
                            ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AppTheme.spaceMD)
                    .background(AppTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, AppTheme.spaceLG)
                .padding(.top, AppTheme.spaceSM)
            }

            if !sync.remotePlaylistOverlays.isEmpty {
                Button {
                    isShowingPlaylistPreview = true
                } label: {
                    HStack(spacing: AppTheme.spaceSM) {
                        Image(systemName: "music.note.list")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.text("deviceSync.playlist.review"))
                                .font(.headline)
                            Text(L10n.format(
                                "deviceSync.playlist.receivedCount",
                                sync.remotePlaylistOverlays.count
                            ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AppTheme.spaceMD)
                    .background(AppTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, AppTheme.spaceLG)
                .padding(.top, AppTheme.spaceSM)
            }

            if let receipt = sync.latestOverlayReceipt {
                HStack(alignment: .top, spacing: AppTheme.spaceSM) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(AppTheme.good)
                    Text(L10n.format(
                        "deviceSync.overlay.receiptSummary",
                        receipt.items.count,
                        receipt.appliedFieldCount,
                        receipt.ignoredCount
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppTheme.spaceLG)
                .padding(.top, AppTheme.spaceSM)
            }

            if syncMode == .sync {
                bulkSyncContent
            } else {
                individualSyncContent
            }
        }
    }

    private var individualSyncContent: some View {
        VStack(spacing: 0) {
            Picker(L10n.text("deviceSync.collection.title"), selection: $selection) {
                ForEach(SyncCollection.allCases) { collection in
                    Text(L10n.text(collection.titleKey)).tag(collection)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, AppTheme.spaceLG)
            .padding(.vertical, AppTheme.spaceMD)

            if selection == .phone {
                trackList(
                    items: sync.remoteItems,
                    emptyKey: "deviceSync.phone.empty",
                    actionTitle: { sync.hasLocalCopy(of: $0) ? L10n.text("deviceSync.downloaded") : L10n.text("deviceSync.download") },
                    actionIcon: "arrow.down.to.line",
                    isDisabled: { sync.hasLocalCopy(of: $0) },
                    action: sync.downloadFromPhone
                )
            } else {
                let localItems = library.tracks
                    .filter { $0.health == .verified }
                    .map(DeviceSyncView.item(from:))
                trackList(
                    items: localItems,
                    emptyKey: "deviceSync.mac.empty",
                    actionTitle: { _ in L10n.text("deviceSync.upload") },
                    actionIcon: "arrow.up.to.line",
                    isDisabled: { _ in false },
                    action: sync.uploadToPhone
                )
            }

            if let latest = sync.transfers.first {
                transferFooter(latest)
            }
        }
    }

    private var bulkSyncContent: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: AppTheme.spaceMD) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("deviceSync.bulk.title"))
                            .font(.headline)
                        Text(L10n.text("deviceSync.bulk.description"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(L10n.format("deviceSync.bulk.available", localSyncItems.count))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Picker(L10n.text("deviceSync.bulk.scope.title"), selection: $bulkScope) {
                    ForEach(BulkSyncScope.allCases) { scope in
                        Text(L10n.text(scope.titleKey)).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(sync.isBulkSyncing)

                if bulkScope == .all {
                    allSongsPolicySettings
                }
            }
            .padding(.horizontal, AppTheme.spaceLG)
            .padding(.vertical, AppTheme.spaceMD)

            Divider()

            bulkSelectionContent

            bulkSyncFooter
        }
    }

    private var allSongsPolicySettings: some View {
        VStack(alignment: .leading, spacing: AppTheme.spaceSM) {
            HStack {
                Text(L10n.text("deviceSync.bulk.policy.title"))
                    .font(.callout.weight(.medium))
                Spacer()
                Picker(L10n.text("deviceSync.bulk.policy.title"), selection: $allSongsPolicy) {
                    ForEach(AllSongsPolicy.allCases) { policy in
                        Text(L10n.text(policy.titleKey)).tag(policy)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 310, alignment: .trailing)
                .disabled(sync.isBulkSyncing)
            }

            Text(L10n.text(allSongsPolicy.descriptionKey))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if allSongsPolicy == .fillCapacity {
                HStack(spacing: AppTheme.spaceLG) {
                    Picker(L10n.text("deviceSync.bulk.priority.title"), selection: $capacityPriority) {
                        ForEach(CapacityPriority.allCases) { priority in
                            Text(L10n.text(priority.titleKey)).tag(priority)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker(L10n.text("deviceSync.bulk.reserve.title"), selection: $capacityReserve) {
                        ForEach(CapacityReserve.allCases) { reserve in
                            Text(ByteCountFormatter.string(
                                fromByteCount: reserve.rawValue,
                                countStyle: .file
                            )).tag(reserve)
                        }
                    }
                    .pickerStyle(.menu)
                }
                .disabled(sync.isBulkSyncing)

                Label(capacitySummaryText, systemImage: "internaldrive")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(sync.remoteStorageInfo == nil ? AppTheme.warning : .secondary)
            } else if allSongsPolicy == .downloadMissing {
                Label(
                    L10n.format("deviceSync.bulk.download.summary", phoneOnlyItems.count),
                    systemImage: "arrow.down.to.line"
                )
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            } else if allSongsPolicy == .mergeBothWays {
                Label(
                    L10n.format(
                        "deviceSync.bulk.bidirectional.summary",
                        phoneOnlyItems.count,
                        missingOnPhoneItems.count
                    ),
                    systemImage: "arrow.left.arrow.right"
                )
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .padding(AppTheme.spaceMD)
        .background(AppTheme.raised, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var bulkSelectionContent: some View {
        if localSyncItems.isEmpty {
            ContentUnavailableView(
                L10n.text("deviceSync.mac.empty"),
                systemImage: "music.note.list"
            )
        } else {
            switch bulkScope {
            case .all:
                ContentUnavailableView {
                    Label(L10n.text("deviceSync.bulk.all.title"), systemImage: "music.note.house")
                } description: {
                    Text(allSongsPlanDescription)
                }
            case .artists:
                selectableListHeader(
                    selectedCount: selectedArtists.count,
                    totalCount: artistChoices.count,
                    selectAll: { selectedArtists = Set(artistChoices.map(\.name)) },
                    clear: { selectedArtists.removeAll() }
                )
                List(artistChoices) { choice in
                    selectionRow(
                        title: choice.name,
                        detail: L10n.format("deviceSync.bulk.songCount", choice.count),
                        isSelected: selectedArtists.contains(choice.name)
                    ) {
                        toggle(choice.name, in: &selectedArtists)
                    }
                }
                .scrollContentBackground(.hidden)
            case .albums:
                selectableListHeader(
                    selectedCount: selectedAlbums.count,
                    totalCount: albumChoices.count,
                    selectAll: { selectedAlbums = Set(albumChoices.map(\.selection)) },
                    clear: { selectedAlbums.removeAll() }
                )
                List(albumChoices) { choice in
                    selectionRow(
                        title: choice.selection.album,
                        detail: "\(choice.selection.artist) · \(L10n.format("deviceSync.bulk.songCount", choice.count))",
                        isSelected: selectedAlbums.contains(choice.selection)
                    ) {
                        toggle(choice.selection, in: &selectedAlbums)
                    }
                }
                .scrollContentBackground(.hidden)
            case .songs:
                selectableListHeader(
                    selectedCount: selectedSongIDs.count,
                    totalCount: localSyncItems.count,
                    selectAll: { selectedSongIDs = Set(localSyncItems.map(\.id)) },
                    clear: { selectedSongIDs.removeAll() }
                )
                List(localSyncItems) { item in
                    selectionRow(
                        title: item.title,
                        detail: metadata(for: item),
                        isSelected: selectedSongIDs.contains(item.id)
                    ) {
                        toggle(item.id, in: &selectedSongIDs)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func selectableListHeader(
        selectedCount: Int,
        totalCount: Int,
        selectAll: @escaping () -> Void,
        clear: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(L10n.format("deviceSync.bulk.selectedGroups", selectedCount, totalCount))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button(L10n.text("deviceSync.bulk.selectAll"), action: selectAll)
                .disabled(sync.isBulkSyncing || selectedCount == totalCount)
            Button(L10n.text("deviceSync.bulk.clear"), action: clear)
                .disabled(sync.isBulkSyncing || selectedCount == 0)
        }
        .padding(.horizontal, AppTheme.spaceLG)
        .padding(.vertical, AppTheme.spaceSM)
    }

    private func selectionRow(
        title: String,
        detail: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: AppTheme.spaceMD) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AppTheme.accent : .secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(sync.isBulkSyncing)
        .padding(.vertical, 4)
    }

    private var bulkSyncFooter: some View {
        HStack(spacing: AppTheme.spaceMD) {
            if sync.bulkSyncTotalCount > 0 {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: AppTheme.spaceSM) {
                        if sync.isBulkSyncing { ProgressView().controlSize(.small) }
                        Text(bulkProgressText)
                            .font(.callout)
                            .lineLimit(1)
                    }
                    ProgressView(
                        value: Double(sync.bulkSyncCompletedCount + sync.bulkSyncFailedCount),
                        total: Double(max(sync.bulkSyncTotalCount, 1))
                    )
                    .frame(maxWidth: 320)
                }
            } else {
                Text(bulkFooterSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                if bulkScope == .all && allSongsPolicy == .downloadMissing {
                    sync.synchronizeBidirectionally(
                        uploadItems: [],
                        downloadItems: phoneOnlyItems
                    )
                } else if bulkScope == .all && allSongsPolicy == .mergeBothWays {
                    sync.synchronizeBidirectionally(
                        uploadItems: missingOnPhoneItems,
                        downloadItems: phoneOnlyItems
                    )
                } else {
                    sync.syncToPhone(pendingBulkItems)
                }
            } label: {
                Label(bulkStartTitle, systemImage: bulkStartIcon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                sync.isBulkSyncing
                    || plannedOperationCount == 0
                    || (bulkScope == .all
                        && allSongsPolicy == .fillCapacity
                        && sync.remoteStorageInfo == nil)
            )
        }
        .padding(.horizontal, AppTheme.spaceLG)
        .padding(.vertical, AppTheme.spaceMD)
        .background(AppTheme.surface)
    }

    private struct ArtistChoice: Identifiable {
        var name: String
        var count: Int
        var id: String { name }
    }

    private struct AlbumChoice: Identifiable {
        var selection: AlbumSelection
        var count: Int
        var id: String { selection.id }
    }

    private var localSyncItems: [DeviceSyncItem] {
        library.tracks
            .filter { $0.health == .verified }
            .map(DeviceSyncView.item(from:))
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private var artistChoices: [ArtistChoice] {
        let grouped = Dictionary(grouping: localSyncItems) { item in
            item.artist.isEmpty ? L10n.text("deviceSync.bulk.unknownArtist") : item.artist
        }
        return grouped.map { ArtistChoice(name: $0.key, count: $0.value.count) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var albumChoices: [AlbumChoice] {
        let grouped = Dictionary(grouping: localSyncItems) { item in
            AlbumSelection(
                artist: item.artist.isEmpty
                    ? L10n.text("deviceSync.bulk.unknownArtist")
                    : item.artist,
                album: item.album.isEmpty
                    ? L10n.text("deviceSync.bulk.unknownAlbum")
                    : item.album
            )
        }
        return grouped.map { AlbumChoice(selection: $0.key, count: $0.value.count) }
            .sorted {
                if $0.selection.artist == $1.selection.artist {
                    return $0.selection.album.localizedStandardCompare($1.selection.album) == .orderedAscending
                }
                return $0.selection.artist.localizedStandardCompare($1.selection.artist) == .orderedAscending
            }
    }

    private var selectedBulkItems: [DeviceSyncItem] {
        switch bulkScope {
        case .all:
            localSyncItems
        case .artists:
            localSyncItems.filter {
                selectedArtists.contains(
                    $0.artist.isEmpty ? L10n.text("deviceSync.bulk.unknownArtist") : $0.artist
                )
            }
        case .albums:
            localSyncItems.filter { item in
                selectedAlbums.contains(AlbumSelection(
                    artist: item.artist.isEmpty
                        ? L10n.text("deviceSync.bulk.unknownArtist")
                        : item.artist,
                    album: item.album.isEmpty
                        ? L10n.text("deviceSync.bulk.unknownAlbum")
                        : item.album
                ))
            }
        case .songs:
            localSyncItems.filter { selectedSongIDs.contains($0.id) }
        }
    }

    private var missingOnPhoneItems: [DeviceSyncItem] {
        selectedBulkItems.filter { !sync.hasRemoteCopy(of: $0) }
    }

    private var phoneOnlyItems: [DeviceSyncItem] {
        sync.remoteItems.filter { !sync.hasLocalCopy(of: $0) }
    }

    private var pendingBulkItems: [DeviceSyncItem] {
        guard bulkScope == .all && allSongsPolicy == .fillCapacity else {
            return missingOnPhoneItems
        }
        return capacityPlannedItems
    }

    private var plannedOperationCount: Int {
        if bulkScope == .all {
            switch allSongsPolicy {
            case .downloadMissing:
                return phoneOnlyItems.count
            case .mergeBothWays:
                return missingOnPhoneItems.count + phoneOnlyItems.count
            case .addMissing, .fillCapacity:
                break
            }
        }
        return pendingBulkItems.count
    }

    private var bulkFooterSummary: String {
        if bulkScope == .all {
            switch allSongsPolicy {
            case .downloadMissing:
                return L10n.format("deviceSync.bulk.download.summary", phoneOnlyItems.count)
            case .mergeBothWays:
                return L10n.format(
                    "deviceSync.bulk.bidirectional.summary",
                    phoneOnlyItems.count,
                    missingOnPhoneItems.count
                )
            case .addMissing, .fillCapacity:
                break
            }
        }
        return L10n.format(
            "deviceSync.bulk.selectionSummary",
            selectedBulkItems.count,
            plannedOperationCount
        )
    }

    private var allSongsPlanDescription: String {
        switch allSongsPolicy {
        case .downloadMissing:
            L10n.format("deviceSync.bulk.download.summary", phoneOnlyItems.count)
        case .mergeBothWays:
            L10n.format(
                "deviceSync.bulk.bidirectional.summary",
                phoneOnlyItems.count,
                missingOnPhoneItems.count
            )
        case .addMissing, .fillCapacity:
            L10n.format(
                "deviceSync.bulk.all.description",
                localSyncItems.count,
                plannedOperationCount
            )
        }
    }

    private var bulkStartTitle: String {
        if bulkScope == .all {
            switch allSongsPolicy {
            case .downloadMissing:
                return L10n.format("deviceSync.bulk.download.start", plannedOperationCount)
            case .mergeBothWays:
                return L10n.format("deviceSync.bulk.bidirectional.start", plannedOperationCount)
            case .addMissing, .fillCapacity:
                break
            }
        }
        return L10n.format("deviceSync.bulk.start", plannedOperationCount)
    }

    private var bulkStartIcon: String {
        if bulkScope == .all {
            switch allSongsPolicy {
            case .downloadMissing:
                return "arrow.left.circle.fill"
            case .mergeBothWays:
                return "arrow.left.arrow.right.circle.fill"
            case .addMissing, .fillCapacity:
                break
            }
        }
        return "arrow.right.circle.fill"
    }

    private var capacityPlannedItems: [DeviceSyncItem] {
        guard let storage = sync.remoteStorageInfo else { return [] }
        var remaining = max(0, storage.availableBytes - capacityReserve.rawValue)
        var result: [DeviceSyncItem] = []

        for item in capacityOrderedMissingItems where item.fileSize <= remaining {
            result.append(item)
            remaining -= item.fileSize
        }
        return result
    }

    private var capacityOrderedMissingItems: [DeviceSyncItem] {
        switch capacityPriority {
        case .recentlyModified:
            missingOnPhoneItems.sorted { $0.modifiedAt > $1.modifiedAt }
        case .libraryOrder:
            missingOnPhoneItems
        case .smallestFirst:
            missingOnPhoneItems.sorted {
                if $0.fileSize == $1.fileSize {
                    return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
                return $0.fileSize < $1.fileSize
            }
        }
    }

    private var capacitySummaryText: String {
        guard let storage = sync.remoteStorageInfo else {
            return L10n.text("deviceSync.bulk.capacity.unavailable")
        }
        let plannedBytes = capacityPlannedItems.reduce(Int64(0)) { $0 + $1.fileSize }
        return L10n.format(
            "deviceSync.bulk.capacity.summary",
            ByteCountFormatter.string(fromByteCount: storage.availableBytes, countStyle: .file),
            ByteCountFormatter.string(fromByteCount: capacityReserve.rawValue, countStyle: .file),
            capacityPlannedItems.count,
            ByteCountFormatter.string(fromByteCount: plannedBytes, countStyle: .file)
        )
    }

    private var bulkProgressText: String {
        if sync.isBulkSyncing {
            return L10n.format(
                "deviceSync.bulk.progress",
                sync.bulkSyncCompletedCount + sync.bulkSyncFailedCount,
                sync.bulkSyncTotalCount,
                sync.bulkSyncCurrentTitle ?? ""
            )
        }
        return L10n.format(
            "deviceSync.bulk.finished",
            sync.bulkSyncCompletedCount,
            sync.bulkSyncFailedCount
        )
    }

    private func toggle<Value: Hashable>(_ value: Value, in set: inout Set<Value>) {
        if set.contains(value) {
            set.remove(value)
        } else {
            set.insert(value)
        }
    }

    private func trackList(
        items: [DeviceSyncItem],
        emptyKey: String,
        actionTitle: @escaping (DeviceSyncItem) -> String,
        actionIcon: String,
        isDisabled: @escaping (DeviceSyncItem) -> Bool,
        action: @escaping (DeviceSyncItem) -> Void
    ) -> some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    L10n.text(emptyKey),
                    systemImage: "music.note.list"
                )
            } else {
                List(items) { item in
                    HStack(spacing: AppTheme.spaceMD) {
                        Image(systemName: "music.note")
                            .frame(width: 28, height: 28)
                            .background(AppTheme.raised, in: RoundedRectangle(cornerRadius: 7))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Text(metadata(for: item))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: AppTheme.spaceMD)
                        Text(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button(actionTitle(item), systemImage: actionIcon) {
                            action(item)
                        }
                        .labelStyle(.titleAndIcon)
                        .disabled(isDisabled(item))
                    }
                    .padding(.vertical, 6)
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func transferFooter(_ transfer: DeviceTransferState) -> some View {
        HStack(spacing: AppTheme.spaceSM) {
            if transfer.phase == .transferring || transfer.phase == .paused {
                ProgressView(value: transfer.fractionCompleted)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else if transfer.phase == .preparing || transfer.phase == .verifying {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: transfer.phase == .completed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(transfer.phase == .completed ? AppTheme.good : AppTheme.danger)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(transferStatus(transfer))
                    .font(.callout)
                    .lineLimit(1)
                if transfer.phase == .transferring || transfer.phase == .paused {
                    Text(transferProgressText(transfer))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if transfer.phase == .transferring {
                Button(L10n.text("deviceSync.transfer.pause"), systemImage: "pause.fill") {
                    sync.pauseTransfer(transfer.id)
                }
                .labelStyle(.iconOnly)
                .help(L10n.text("deviceSync.transfer.pause"))
            } else if transfer.phase == .paused {
                Button(L10n.text("deviceSync.transfer.resume"), systemImage: "play.fill") {
                    sync.resumeTransfer(transfer.id)
                }
                .labelStyle(.iconOnly)
                .help(L10n.text("deviceSync.transfer.resume"))
            }
            if transfer.isActive {
                Button(L10n.text("deviceSync.transfer.cancel"), systemImage: "xmark") {
                    sync.cancelTransfer(transfer.id)
                }
                .labelStyle(.iconOnly)
                .help(L10n.text("deviceSync.transfer.cancel"))
            }
        }
        .padding(.horizontal, AppTheme.spaceLG)
        .padding(.vertical, AppTheme.spaceSM)
        .background(AppTheme.surface)
    }

    private var connectionDescription: String {
        switch sync.connectionState {
        case .searching, .disconnected:
            L10n.text("deviceSync.state.searching")
        case .connecting(let name):
            L10n.format("deviceSync.state.connecting", name)
        case .connected(let name):
            L10n.format("deviceSync.state.connected", name)
        case .failed:
            L10n.text("deviceSync.state.failed")
        }
    }

    private var connectingPhoneName: String? {
        if case .connecting(let name) = sync.connectionState { return name }
        return nil
    }

    private func transferStatus(_ transfer: DeviceTransferState) -> String {
        switch transfer.phase {
        case .preparing:
            L10n.format("deviceSync.transfer.preparing", transfer.item.title)
        case .transferring:
            L10n.format("deviceSync.transfer.transferring", transfer.item.title)
        case .paused:
            L10n.format("deviceSync.transfer.paused", transfer.item.title)
        case .verifying:
            L10n.format("deviceSync.transfer.verifying", transfer.item.title)
        case .completed:
            L10n.format("deviceSync.transfer.completed", transfer.item.title)
        case .cancelled:
            L10n.format("deviceSync.transfer.cancelled", transfer.item.title)
        case .interrupted:
            L10n.format("deviceSync.transfer.interrupted", transfer.item.title)
        case .insufficientStorage:
            L10n.format("deviceSync.transfer.insufficientStorage", transfer.item.title)
        case .failed(let message):
            L10n.format("deviceSync.transfer.failed", transfer.item.title, message)
        }
    }

    private func transferProgressText(_ transfer: DeviceTransferState) -> String {
        L10n.format(
            "deviceSync.transfer.progress",
            Int((transfer.fractionCompleted * 100).rounded()),
            ByteCountFormatter.string(fromByteCount: transfer.bytesTransferred, countStyle: .file),
            ByteCountFormatter.string(fromByteCount: transfer.item.fileSize, countStyle: .file)
        )
    }

    private func metadata(for item: DeviceSyncItem) -> String {
        [item.artist, item.album].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func item(from track: Track) -> DeviceSyncItem {
        DeviceSyncItem(
            id: track.id,
            title: track.title,
            artist: track.artist,
            album: track.album,
            fileName: track.fileURL.lastPathComponent,
            fileSize: track.fileSize,
            sha256: track.sha256,
            modifiedAt: track.lastVerifiedAt ?? track.addedAt
        )
    }
}

private struct OverlaySyncPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var sync: PhoneSyncController
    @State private var selectedFields: [String: Set<DeviceSyncOverlayField>] = [:]
    @State private var isApplying = false

    private var previews: [DeviceSyncOverlayPreview] { sync.overlayPreviews }

    private var selectedApplications: [DeviceSyncOverlayApplication] {
        previews.compactMap { preview in
            guard let fields = selectedFields[preview.id], !fields.isEmpty,
                  preview.status == .different,
                  let trackID = preview.localTrackID else { return nil }
            return DeviceSyncOverlayApplication(
                trackID: trackID,
                overlay: preview.remote,
                fields: fields
            )
        }
    }

    private var selectedFieldCount: Int {
        selectedApplications.reduce(0) { $0 + $1.fields.count }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("deviceSync.overlay.title"))
                        .font(.title2.weight(.semibold))
                    Text(L10n.text("deviceSync.overlay.description"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.text("common.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(AppTheme.spaceLG)

            Divider()

            List(previews) { preview in
                HStack(alignment: .top, spacing: AppTheme.spaceMD) {
                    Toggle("", isOn: selectionBinding(for: preview))
                        .labelsHidden()
                        .disabled(preview.status != .different)

                    Image(systemName: statusIcon(preview.status))
                        .foregroundStyle(statusColor(preview.status))
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(preview.remote.title)
                            .font(.headline)
                        Text([preview.remote.artist, preview.remote.album]
                            .filter { !$0.isEmpty }
                            .joined(separator: " · "))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(statusText(preview.status))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(statusColor(preview.status))
                        if let local = preview.local, preview.status == .different {
                            Text(comparisonText(local: local, remote: preview.remote))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 132), alignment: .leading)],
                                alignment: .leading,
                                spacing: 6
                            ) {
                                ForEach(availableFields(for: preview), id: \.self) { field in
                                    Toggle(fieldTitle(field), isOn: fieldBinding(field, for: preview))
                                        .toggleStyle(.checkbox)
                                        .font(.caption)
                                }
                            }
                            .padding(.top, 3)
                        }
                    }
                    Spacer(minLength: AppTheme.spaceMD)
                }
                .padding(.vertical, AppTheme.spaceXS)
            }
            .scrollContentBackground(.hidden)

            Divider()

            HStack {
                Text(L10n.format(
                    "deviceSync.overlay.selectedSummary",
                    selectedApplications.count,
                    selectedFieldCount
                ))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("common.cancel")) { dismiss() }
                Button {
                    applySelected()
                } label: {
                    if isApplying {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(L10n.text("deviceSync.overlay.apply"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedApplications.isEmpty || isApplying)
            }
            .padding(AppTheme.spaceLG)
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(AppTheme.canvas)
        .onAppear {
            selectedFields = Dictionary(uniqueKeysWithValues: previews.compactMap { preview in
                let fields = availableFields(for: preview)
                return fields.isEmpty ? nil : (preview.id, Set(fields))
            })
        }
    }

    private func selectionBinding(for preview: DeviceSyncOverlayPreview) -> Binding<Bool> {
        Binding(
            get: {
                let available = Set(availableFields(for: preview))
                return !available.isEmpty && selectedFields[preview.id] == available
            },
            set: { isSelected in
                selectedFields[preview.id] = isSelected
                    ? Set(availableFields(for: preview))
                    : []
            }
        )
    }

    private func fieldBinding(
        _ field: DeviceSyncOverlayField,
        for preview: DeviceSyncOverlayPreview
    ) -> Binding<Bool> {
        Binding(
            get: { selectedFields[preview.id, default: []].contains(field) },
            set: { isSelected in
                if isSelected { selectedFields[preview.id, default: []].insert(field) }
                else { selectedFields[preview.id, default: []].remove(field) }
            }
        )
    }

    private func availableFields(for preview: DeviceSyncOverlayPreview) -> [DeviceSyncOverlayField] {
        guard preview.status == .different, let local = preview.local else { return [] }
        return DeviceSyncOverlayField.allCases.filter { field in
            switch field {
            case .favorite: return local.isFavorite != preview.remote.isFavorite
            case .rating: return local.rating != preview.remote.rating
            case .playCount: return preview.remote.playCount > local.playCount
            case .skipCount: return preview.remote.skipCount > local.skipCount
            case .lastPlayedAt:
                guard let remoteDate = preview.remote.lastPlayedAt else { return false }
                return local.lastPlayedAt.map { remoteDate > $0 } ?? true
            case .displayTags:
                return (local.displayTags ?? []) != (preview.remote.displayTags ?? [])
            }
        }
    }

    private func fieldTitle(_ field: DeviceSyncOverlayField) -> String {
        L10n.text("deviceSync.overlay.field.\(field.rawValue)")
    }

    private func applySelected() {
        let applications = selectedApplications
        let auditID = UUID()
        let changes = applications.compactMap { application -> DeviceSyncAuditChange? in
            guard let preview = previews.first(where: { $0.id == application.overlay.sourceKey }),
                  let local = preview.local else { return nil }
            return DeviceSyncAuditChange(
                trackID: application.trackID,
                title: application.overlay.title,
                before: local,
                after: application.overlay,
                fields: application.fields.sorted { $0.rawValue < $1.rawValue }
            )
        }
        let conflicts = previews.compactMap { preview -> DeviceSyncAuditConflict? in
            let reason: DeviceSyncAuditConflictReason?
            switch preview.status {
            case .ambiguous: reason = .ambiguous
            case .unmatched: reason = .unmatched
            case .different where availableFields(for: preview).isEmpty:
                reason = .noApplicableFields
            default: reason = nil
            }
            guard let reason else { return nil }
            return DeviceSyncAuditConflict(
                sourceKey: preview.remote.sourceKey,
                title: preview.remote.title,
                reason: reason
            )
        }
        isApplying = true
        Task {
            let applied = await library.applySyncedTrackOverlays(applications)
            sync.updateLocalTracks(
                library.tracks,
                playbackEvents: library.playbackEvents,
                playlists: library.playlists,
                displayTags: library.syncedDisplayTags
            )
            isApplying = false
            if applied > 0 {
                let receipt = DeviceSyncOverlayReceipt(
                    id: auditID,
                    appliedAt: .now,
                    items: applications.map { application in
                        DeviceSyncOverlayReceiptItem(
                            sourceKey: application.overlay.sourceKey,
                            fields: application.fields.sorted { $0.rawValue < $1.rawValue }
                        )
                    },
                    ignoredCount: previews.count - applications.count
                )
                sync.recordOverlayAudit(DeviceSyncAuditEntry(
                    id: auditID,
                    occurredAt: receipt.appliedAt,
                    deviceName: connectedDeviceName,
                    changes: changes,
                    conflicts: conflicts,
                    isUndone: false
                ))
                sync.sendOverlayReceipt(receipt)
                dismiss()
            }
        }
    }

    private var connectedDeviceName: String {
        if case .connected(let name) = sync.connectionState { return name }
        return "iPhone"
    }

    private func statusIcon(_ status: DeviceSyncOverlayMatchStatus) -> String {
        switch status {
        case .different: "arrow.triangle.2.circlepath"
        case .identical: "checkmark.circle.fill"
        case .ambiguous: "exclamationmark.triangle.fill"
        case .unmatched: "questionmark.circle"
        }
    }

    private func statusColor(_ status: DeviceSyncOverlayMatchStatus) -> Color {
        switch status {
        case .different: AppTheme.accent
        case .identical: AppTheme.good
        case .ambiguous: .orange
        case .unmatched: .secondary
        }
    }

    private func statusText(_ status: DeviceSyncOverlayMatchStatus) -> String {
        L10n.text("deviceSync.overlay.status.\(status.rawValue)")
    }

    private func comparisonText(
        local: DeviceSyncTrackOverlay,
        remote: DeviceSyncTrackOverlay
    ) -> String {
        L10n.format(
            "deviceSync.overlay.comparison",
            local.rating,
            remote.rating,
            local.playCount,
            remote.playCount,
            local.skipCount,
            remote.skipCount
        )
    }
}

private struct PlaylistSyncPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var sync: PhoneSyncController
    @State private var selectedIDs: Set<UUID> = []
    @State private var isApplying = false
    @State private var errorMessage: String?

    private var previews: [DeviceSyncPlaylistPreview] {
        sync.playlistPreviews(tracks: library.tracks, playlists: library.playlists)
    }

    private var selectedApplications: [DeviceSyncPlaylistApplication] {
        previews.compactMap { preview in
            guard selectedIDs.contains(preview.id),
                  preview.status == .new || preview.status == .different else { return nil }
            return DeviceSyncPlaylistApplication(
                remote: preview.remote,
                trackIDs: preview.matchedTrackIDs
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("deviceSync.playlist.title"))
                        .font(.title2.weight(.semibold))
                    Text(L10n.text("deviceSync.playlist.description"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(L10n.text("common.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(AppTheme.spaceLG)

            Divider()

            List(previews) { preview in
                HStack(alignment: .top, spacing: AppTheme.spaceMD) {
                    Toggle("", isOn: selectionBinding(for: preview))
                        .labelsHidden()
                        .disabled(preview.status != .new && preview.status != .different)

                    Image(systemName: statusIcon(preview.status))
                        .foregroundStyle(statusColor(preview.status))
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(preview.remote.name)
                            .font(.headline)
                        Text(L10n.format(
                            "deviceSync.playlist.trackCount",
                            preview.remote.tracks.count
                        ))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(statusText(preview))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(statusColor(preview.status))
                    }
                    Spacer(minLength: AppTheme.spaceMD)
                }
                .padding(.vertical, AppTheme.spaceXS)
            }
            .scrollContentBackground(.hidden)

            Divider()

            VStack(alignment: .leading, spacing: AppTheme.spaceSM) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                HStack {
                    Text(L10n.format(
                        "deviceSync.playlist.selectedSummary",
                        selectedApplications.count
                    ))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.text("common.cancel")) { dismiss() }
                    Button {
                        applySelected()
                    } label: {
                        if isApplying {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(L10n.text("deviceSync.playlist.apply"))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedApplications.isEmpty || isApplying)
                }
            }
            .padding(AppTheme.spaceLG)
        }
        .frame(minWidth: 680, minHeight: 540)
        .background(AppTheme.canvas)
        .onAppear {
            selectedIDs = Set(previews.compactMap { preview in
                preview.status == .new || preview.status == .different ? preview.id : nil
            })
        }
    }

    private func selectionBinding(for preview: DeviceSyncPlaylistPreview) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(preview.id) },
            set: { selected in
                if selected { selectedIDs.insert(preview.id) }
                else { selectedIDs.remove(preview.id) }
            }
        )
    }

    private func applySelected() {
        let applications = selectedApplications
        let previewSnapshot = previews
        isApplying = true
        errorMessage = nil
        Task {
            do {
                let changes = try await library.applySyncedPlaylistOverlays(applications)
                let conflicts = previewSnapshot.compactMap(auditConflict(for:))
                if !changes.isEmpty {
                    sync.recordOverlayAudit(DeviceSyncAuditEntry(
                        id: UUID(),
                        occurredAt: .now,
                        deviceName: connectedDeviceName,
                        changes: [],
                        playlistChanges: changes,
                        conflicts: conflicts,
                        isUndone: false
                    ))
                    sync.updateLocalTracks(
                        library.tracks,
                        playbackEvents: library.playbackEvents,
                        playlists: library.playlists,
                        displayTags: library.syncedDisplayTags
                    )
                    dismiss()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isApplying = false
        }
    }

    private func auditConflict(
        for preview: DeviceSyncPlaylistPreview
    ) -> DeviceSyncAuditConflict? {
        guard preview.status == .conflicted else { return nil }
        let reason: DeviceSyncAuditConflictReason
        if preview.local?.smartDefinition != nil {
            reason = .playlistSmartCollision
        } else if preview.ambiguousTrackCount > 0 {
            reason = .playlistTracksAmbiguous
        } else {
            reason = .playlistTracksUnmatched
        }
        return DeviceSyncAuditConflict(
            sourceKey: "playlist:\(preview.id.uuidString)",
            title: preview.remote.name,
            reason: reason
        )
    }

    private var connectedDeviceName: String {
        if case .connected(let name) = sync.connectionState { return name }
        return "iPhone"
    }

    private func statusText(_ preview: DeviceSyncPlaylistPreview) -> String {
        if preview.status == .conflicted {
            if preview.local?.smartDefinition != nil {
                return L10n.text("deviceSync.playlist.status.smartCollision")
            }
            return L10n.format(
                "deviceSync.playlist.status.trackConflict",
                preview.unmatchedTrackCount,
                preview.ambiguousTrackCount
            )
        }
        return L10n.text("deviceSync.playlist.status.\(preview.status.rawValue)")
    }

    private func statusIcon(_ status: DeviceSyncPlaylistMatchStatus) -> String {
        switch status {
        case .new: "plus.circle.fill"
        case .different: "arrow.triangle.2.circlepath"
        case .identical: "checkmark.circle.fill"
        case .conflicted: "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(_ status: DeviceSyncPlaylistMatchStatus) -> Color {
        switch status {
        case .new, .different: AppTheme.accent
        case .identical: AppTheme.good
        case .conflicted: .orange
        }
    }
}

private struct OverlaySyncAuditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var sync: PhoneSyncController
    @State private var undoingID: UUID?
    @State private var undoConflictCount = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("deviceSync.audit.title"))
                        .font(.title2.weight(.semibold))
                    Text(L10n.text("deviceSync.audit.description"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.text("common.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(AppTheme.spaceLG)

            Divider()

            List(sync.overlayAuditHistory) { entry in
                VStack(alignment: .leading, spacing: AppTheme.spaceSM) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.deviceName)
                            .font(.headline)
                        Text(entry.occurredAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if entry.isUndone {
                            Label(L10n.text("deviceSync.audit.undone"), systemImage: "arrow.uturn.backward.circle.fill")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(L10n.format(
                        "deviceSync.audit.summary",
                        entry.changes.count,
                        entry.appliedFieldCount,
                        entry.conflicts.count
                    ))
                        .font(.callout)

                    if entry.appliedPlaylistCount > 0 {
                        Text(L10n.format(
                            "deviceSync.audit.playlistSummary",
                            entry.appliedPlaylistCount
                        ))
                            .font(.callout)
                    }

                    ForEach(entry.conflicts, id: \.sourceKey) { conflict in
                        Label(
                            "\(conflict.title): \(conflictReason(conflict.reason))",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }

                    if !entry.isUndone {
                        Button(L10n.text("deviceSync.audit.undo"), systemImage: "arrow.uturn.backward") {
                            undo(entry)
                        }
                        .disabled(undoingID != nil)
                    }
                }
                .padding(.vertical, AppTheme.spaceXS)
            }
            .scrollContentBackground(.hidden)

            if undoConflictCount > 0 {
                Text(L10n.format("deviceSync.audit.undoConflicts", undoConflictCount))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(AppTheme.spaceMD)
            }
        }
        .frame(minWidth: 680, minHeight: 520)
        .background(AppTheme.canvas)
    }

    private func undo(_ entry: DeviceSyncAuditEntry) {
        undoingID = entry.id
        Task {
            let trackResult = await library.undoSyncedTrackOverlays(entry.changes)
            let playlistResult = await library.undoSyncedPlaylistChanges(
                entry.playlistChanges ?? []
            )
            undoConflictCount = trackResult.conflictFieldCount
                + playlistResult.conflictFieldCount
            if trackResult.restoredFieldCount + playlistResult.restoredFieldCount > 0 {
                sync.markOverlayAuditUndone(entry.id)
                sync.updateLocalTracks(
                    library.tracks,
                    playbackEvents: library.playbackEvents,
                    playlists: library.playlists,
                    displayTags: library.syncedDisplayTags
                )
            }
            undoingID = nil
        }
    }

    private func conflictReason(_ reason: DeviceSyncAuditConflictReason) -> String {
        L10n.text("deviceSync.audit.conflict.\(reason.rawValue)")
    }
}

#Preview("Device Sync") {
    DeviceSyncView()
        .environmentObject(LibraryStore())
        .environmentObject(PhoneSyncController())
        .frame(width: 820, height: 620)
}
