import SwiftUI
import UniformTypeIdentifiers

struct MobileContentView: View {
    @EnvironmentObject private var sync: MobileSyncController
    @State private var isImporting = false
    @State private var isConfirmingCheckpointDeletion = false

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                phoneLibrarySection
                macLibrarySection
                transferSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle(String(localized: "mobile.title"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isImporting = true
                    } label: {
                        Label(String(localized: "mobile.import"), systemImage: "plus")
                    }
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: true
            ) { result in
                guard case .success(let urls) = result else { return }
                Task { await sync.importFiles(urls) }
            }
            .confirmationDialog(
                String(localized: "mobile.pairing.title"),
                isPresented: Binding(
                    get: { sync.pairingRequest != nil },
                    set: { if !$0 { sync.pairingRequest = nil } }
                ),
                presenting: sync.pairingRequest
            ) { request in
                Button(String(localized: "mobile.pairing.accept")) {
                    sync.acceptPairing(request)
                }
                Button(String(localized: "mobile.pairing.decline"), role: .cancel) {
                    sync.declinePairing(request)
                }
            } message: { request in
                Text(String(format: String(localized: "mobile.pairing.message"), request.deviceName, request.pairingCode))
            }
            .confirmationDialog(
                String(localized: "mobile.resume.delete.title"),
                isPresented: $isConfirmingCheckpointDeletion,
                titleVisibility: .visible
            ) {
                Button(String(localized: "mobile.resume.delete.action"), role: .destructive) {
                    sync.discardResumableTransfers()
                }
                Button(String(localized: "mobile.cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "mobile.resume.delete.message"))
            }
        }
    }

    private var connectionSection: some View {
        Section {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: connectionIcon)
                    .font(.title2)
                    .foregroundStyle(connectionColor)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 6) {
                    Text(connectionTitle)
                        .font(.headline)
                    Text(connectionDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 6)

            if case .connected = sync.connectionState {
                Button(String(localized: "mobile.disconnect"), role: .destructive) {
                    sync.disconnect()
                }
            } else {
                Button {
                    sync.retryDiscovery()
                } label: {
                    Label(String(localized: "mobile.retryDiscovery"), systemImage: "arrow.clockwise")
                }
            }
        } header: {
            Text(String(localized: "mobile.connection"))
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(format: String(localized: "mobile.pairing.code"), sync.pairingCode))
                Text(String(localized: "mobile.networkHelp"))
            }
        }
    }

    private var phoneLibrarySection: some View {
        Section(String(localized: "mobile.onPhone")) {
            if sync.localItems.isEmpty {
                Text(String(localized: "mobile.phone.empty"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sync.localItems) { item in
                    trackRow(item: item) {
                        Button {
                            sync.uploadToMac(item)
                        } label: {
                            Image(systemName: "arrow.up.to.line")
                        }
                        .accessibilityLabel(String(localized: "mobile.sendToMac"))
                        .disabled(!isConnected)
                    }
                }
            }
        }
    }

    private var macLibrarySection: some View {
        Section(String(localized: "mobile.onMac")) {
            if !isConnected {
                Text(String(localized: "mobile.mac.connectFirst"))
                    .foregroundStyle(.secondary)
            } else if sync.remoteItems.isEmpty {
                Text(String(localized: "mobile.mac.empty"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sync.remoteItems) { item in
                    trackRow(item: item) {
                        Button {
                            sync.downloadFromMac(item)
                        } label: {
                            Image(systemName: sync.hasLocalCopy(of: item) ? "checkmark.circle.fill" : "arrow.down.to.line")
                        }
                        .accessibilityLabel(String(localized: "mobile.downloadFromMac"))
                        .disabled(sync.hasLocalCopy(of: item))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var transferSection: some View {
        if let transfer = sync.transfers.first {
            Section(String(localized: "mobile.latestTransfer")) {
                HStack(spacing: 12) {
                    if transfer.phase == .transferring || transfer.phase == .paused {
                        ProgressView(value: transfer.fractionCompleted)
                    } else if transfer.phase == .preparing || transfer.phase == .verifying {
                        ProgressView()
                    } else {
                        Image(systemName: transfer.phase == .completed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(transfer.phase == .completed ? .green : .red)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(transfer.item.title)
                            .lineLimit(1)
                        Text(transferDescription(transfer.phase))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if transfer.phase == .transferring || transfer.phase == .paused {
                            Text(transferProgressText(transfer))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            if transfer.resumedFromCheckpoint {
                                Text(String(localized: "mobile.transfer.resumedCheckpoint"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    if transfer.phase == .transferring {
                        Button {
                            sync.pauseTransfer(transfer.id)
                        } label: {
                            Image(systemName: "pause.fill")
                        }
                        .accessibilityLabel(String(localized: "mobile.transfer.pause"))
                    } else if transfer.phase == .paused {
                        Button {
                            sync.resumeTransfer(transfer.id)
                        } label: {
                            Image(systemName: "play.fill")
                        }
                        .accessibilityLabel(String(localized: "mobile.transfer.resume"))
                    }
                    if transfer.isActive {
                        Button(role: .destructive) {
                            sync.cancelTransfer(transfer.id)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel(String(localized: "mobile.transfer.cancel"))
                    }
                }
            }
        }
        if !sync.resumableTransfers.isEmpty {
            Section {
                ForEach(sync.resumableTransfers.prefix(3)) { checkpoint in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(checkpoint.title)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(Int((checkpoint.fractionCompleted * 100).rounded()))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: checkpoint.fractionCompleted)
                    }
                    .padding(.vertical, 2)
                }
                Text(String(localized: "mobile.resume.description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(String(localized: "mobile.resume.delete.action"), role: .destructive) {
                    isConfirmingCheckpointDeletion = true
                }
                .disabled(sync.transfers.contains(where: \.isActive))
            } header: {
                Text(String(format: String(localized: "mobile.resume.title"), sync.resumableTransfers.count))
            }
        }
    }

    private func trackRow<Accessory: View>(
        item: DeviceSyncItem,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note")
                .foregroundStyle(.orange)
                .frame(width: 28, height: 28)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .lineLimit(1)
                Text(trackDetail(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.vertical, 4)
    }

    private var isConnected: Bool {
        if case .connected = sync.connectionState { return true }
        return false
    }

    private var connectionTitle: String {
        switch sync.connectionState {
        case .connected(let name): String(format: String(localized: "mobile.connected"), name)
        case .connecting(let name): String(format: String(localized: "mobile.connecting"), name)
        case .failed: String(localized: "mobile.failed")
        case .searching, .disconnected: String(localized: "mobile.ready")
        }
    }

    private var connectionDetail: String {
        switch sync.connectionState {
        case .connected: String(localized: "mobile.connected.detail")
        case .connecting: String(localized: "mobile.connecting.detail")
        case .failed(let message): message
        case .searching, .disconnected: String(localized: "mobile.ready.detail")
        }
    }

    private var connectionIcon: String {
        isConnected ? "iphone.and.arrow.forward" : "wifi"
    }

    private var connectionColor: Color {
        if case .failed = sync.connectionState { return .red }
        return isConnected ? .green : .orange
    }

    private func trackDetail(_ item: DeviceSyncItem) -> String {
        let metadata = [item.artist, item.album].filter { !$0.isEmpty }.joined(separator: " · ")
        return metadata.isEmpty
            ? ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file)
            : metadata
    }

    private func transferDescription(_ phase: DeviceTransferState.Phase) -> String {
        switch phase {
        case .preparing: String(localized: "mobile.transfer.preparing")
        case .transferring: String(localized: "mobile.transfer.transferring")
        case .paused: String(localized: "mobile.transfer.paused")
        case .verifying: String(localized: "mobile.transfer.verifying")
        case .completed: String(localized: "mobile.transfer.completed")
        case .cancelled: String(localized: "mobile.transfer.cancelled")
        case .interrupted: String(localized: "mobile.transfer.interrupted")
        case .insufficientStorage: String(localized: "mobile.transfer.insufficientStorage")
        case .failed(let message): message
        }
    }

    private func transferProgressText(_ transfer: DeviceTransferState) -> String {
        String(
            format: String(localized: "mobile.transfer.progress"),
            Int((transfer.fractionCompleted * 100).rounded()),
            ByteCountFormatter.string(fromByteCount: transfer.bytesTransferred, countStyle: .file),
            ByteCountFormatter.string(fromByteCount: transfer.item.fileSize, countStyle: .file)
        )
    }
}

struct MobileContentView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            MobileContentView()
                .environmentObject(MobileSyncController())
                .previewDevice("iPhone SE (3rd generation)")
                .previewDisplayName("iPhone SE")

            MobileContentView()
                .environmentObject(MobileSyncController())
                .previewDevice("iPhone 16 Pro Max")
                .previewDisplayName("iPhone 16 Pro Max")
        }
    }
}
