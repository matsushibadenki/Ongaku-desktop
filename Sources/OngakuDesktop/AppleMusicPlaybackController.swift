import Combine
import Foundation
@preconcurrency import MusicKit

struct AppleMusicPlaybackState: Equatable, Sendable {
    private(set) var currentItemID: String?
    private(set) var isPlaying = false
    private(set) var isWorking = false

    mutating func begin(itemID: String) {
        currentItemID = itemID
        isPlaying = false
        isWorking = true
    }

    mutating func didStart() {
        isPlaying = true
        isWorking = false
    }

    mutating func didPause() {
        isPlaying = false
        isWorking = false
    }

    mutating func didStop() {
        currentItemID = nil
        isPlaying = false
        isWorking = false
    }

    mutating func didFail() {
        isPlaying = false
        isWorking = false
    }
}

struct AppleMusicQueueItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let duration: TimeInterval
    let artworkURL: URL?
}

enum AppleMusicQueuePresentation {
    static func currentItem(
        in items: [AppleMusicQueueItem],
        currentEntryID: String?
    ) -> AppleMusicQueueItem? {
        items.first(where: { $0.id == currentEntryID }) ?? items.first
    }
}

enum AppleMusicQueueEditor {
    static func moving(
        _ items: [AppleMusicQueueItem],
        fromOffsets offsets: IndexSet,
        toOffset destination: Int,
        currentItemID: String?
    ) -> [AppleMusicQueueItem] {
        let validOffsets = offsets.filter { items.indices.contains($0) }
        guard !validOffsets.isEmpty,
              !validOffsets.contains(where: { items[$0].id == currentItemID }) else {
            return items
        }

        var result = items
        let movingItems = validOffsets.map { result[$0] }
        for index in validOffsets.sorted(by: >) {
            result.remove(at: index)
        }
        let removedBeforeDestination = validOffsets.count(where: { $0 < destination })
        let requestedInsertionIndex = min(
            max(destination - removedBeforeDestination, 0),
            result.count
        )
        let minimumInsertionIndex = items.firstIndex(where: { $0.id == currentItemID })
            .map { min($0 + 1, result.count) } ?? 0
        let insertionIndex = max(requestedInsertionIndex, minimumInsertionIndex)
        result.insert(contentsOf: movingItems, at: insertionIndex)
        return result
    }

    static func removing(
        _ items: [AppleMusicQueueItem],
        ids selectedIDs: Set<String>,
        currentItemID: String?
    ) -> [AppleMusicQueueItem] {
        guard !selectedIDs.isEmpty else { return items }
        return items.filter { item in
            item.id == currentItemID || !selectedIDs.contains(item.id)
        }
    }
}

@MainActor
final class AppleMusicPlaybackController: ObservableObject {
    private enum RetryOperation {
        case resume
        case previous
        case next
        case queueItem(String)
    }

    @Published private(set) var state = AppleMusicPlaybackState()
    @Published private(set) var currentItem: AppleMusicCatalogItem?
    @Published private(set) var errorMessage: String?
    @Published private(set) var queueItems: [AppleMusicQueueItem] = []
    @Published private(set) var currentQueueItem: AppleMusicQueueItem?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var isQueueEditing = false

    private let player = ApplicationMusicPlayer.shared
    private var queueObservation: AnyCancellable?
    private var playerStateObservation: AnyCancellable?
    private var progressTask: Task<Void, Never>?
    private var retryOperation: RetryOperation?

    var isPlaying: Bool { state.isPlaying }
    var isWorking: Bool { state.isWorking || isQueueEditing }
    var duration: TimeInterval { currentQueueItem?.duration ?? 0 }
    var canRetry: Bool { retryOperation != nil && errorMessage != nil }

    init() {
        observePlayerState()
    }

    func play(
        item: AppleMusicCatalogItem,
        queue: ApplicationMusicPlayer.Queue,
        suspendingLocalPlayback: () -> Void
    ) async {
        suspendingLocalPlayback()
        player.stop()
        currentItem = item
        state.begin(itemID: item.musicItemID)
        errorMessage = nil
        retryOperation = nil

        do {
            player.queue = queue
            observeQueue()
            refreshQueueSnapshot()
            try await player.play()
            state.didStart()
            refreshQueueSnapshot()
            startProgressUpdates()
        } catch {
            state.didFail()
            errorMessage = error.localizedDescription
            retryOperation = .resume
        }
    }

    func pause() {
        guard state.isPlaying else { return }
        player.pause()
        state.didPause()
        refreshProgress()
        stopProgressUpdates()
    }

    func resume() async {
        guard let currentItem, !state.isWorking else { return }
        state.begin(itemID: currentItem.musicItemID)
        do {
            try await player.play()
            state.didStart()
            errorMessage = nil
            retryOperation = nil
            startProgressUpdates()
        } catch {
            state.didFail()
            errorMessage = error.localizedDescription
            retryOperation = .resume
        }
    }

    func stopForLocalPlayback() {
        guard currentItem != nil || state.isPlaying else { return }
        player.stop()
        currentItem = nil
        state.didStop()
        errorMessage = nil
        retryOperation = nil
        queueObservation = nil
        queueItems = []
        currentQueueItem = nil
        elapsed = 0
        stopProgressUpdates()
    }

    func playPrevious() async {
        guard currentItem != nil, !state.isWorking else { return }
        do {
            try await player.skipToPreviousEntry()
            refreshQueueSnapshot()
            errorMessage = nil
            retryOperation = nil
        } catch {
            errorMessage = error.localizedDescription
            retryOperation = .previous
        }
    }

    func playNext() async {
        guard currentItem != nil, !state.isWorking else { return }
        do {
            try await player.skipToNextEntry()
            refreshQueueSnapshot()
            errorMessage = nil
            retryOperation = nil
        } catch {
            errorMessage = error.localizedDescription
            retryOperation = .next
        }
    }

    func seek(to position: TimeInterval) {
        guard currentItem != nil else { return }
        player.playbackTime = max(position, 0)
        refreshProgress()
    }

    func insert<PlayableItem: PlayableMusicItem>(
        _ playableItem: PlayableItem,
        position: MusicPlayer.Queue.EntryInsertionPosition
    ) async {
        guard currentItem != nil, !isQueueEditing else { return }
        isQueueEditing = true
        retryOperation = nil
        defer { isQueueEditing = false }
        do {
            try await player.queue.insert(playableItem, position: position)
            refreshQueueSnapshot()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func playQueueItem(id: String) async {
        guard currentItem != nil,
              let entry = player.queue.entries.first(where: { $0.id == id }) else { return }
        player.queue.currentEntry = entry
        do {
            try await player.play()
            state.didStart()
            refreshQueueSnapshot()
            startProgressUpdates()
            errorMessage = nil
            retryOperation = nil
        } catch {
            state.didFail()
            errorMessage = error.localizedDescription
            retryOperation = .queueItem(id)
        }
    }

    func retryLastOperation() async {
        guard let retryOperation, !isWorking else { return }
        switch retryOperation {
        case .resume:
            await resume()
        case .previous:
            await playPrevious()
        case .next:
            await playNext()
        case .queueItem(let id):
            await playQueueItem(id: id)
        }
    }

    func moveQueueItems(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let reorderedItems = AppleMusicQueueEditor.moving(
            queueItems,
            fromOffsets: offsets,
            toOffset: destination,
            currentItemID: currentQueueItem?.id
        )
        guard reorderedItems != queueItems else { return }

        let allEntries = Array(player.queue.entries)
        let entriesByID = Dictionary(uniqueKeysWithValues: allEntries.map { ($0.id, $0) })
        let visibleIDs = Set(queueItems.map(\.id))
        var reorderedEntries = reorderedItems.compactMap { entriesByID[$0.id] }
        let mergedEntries = allEntries.map { entry in
            visibleIDs.contains(entry.id) ? reorderedEntries.removeFirst() : entry
        }
        var entries = ApplicationMusicPlayer.Queue.Entries()
        entries.append(contentsOf: mergedEntries)
        player.queue.entries = entries
        refreshQueueSnapshot()
    }

    func moveQueueItem(id: String, offset: Int) {
        guard let index = queueItems.firstIndex(where: { $0.id == id }) else { return }
        let destination = min(max(index + offset, 0), queueItems.count - 1)
        guard destination != index else { return }
        moveQueueItems(
            fromOffsets: IndexSet(integer: index),
            toOffset: destination > index ? destination + 1 : destination
        )
    }

    func removeQueueItems(ids: Set<String>) {
        guard !isQueueEditing else { return }
        let retainedItems = AppleMusicQueueEditor.removing(
            queueItems,
            ids: ids,
            currentItemID: currentQueueItem?.id
        )
        guard retainedItems != queueItems else { return }

        let retainedIDs = Set(retainedItems.map(\.id))
        let visibleIDs = Set(queueItems.map(\.id))
        let retainedEntries = player.queue.entries.filter { entry in
            !visibleIDs.contains(entry.id) || retainedIDs.contains(entry.id)
        }
        var entries = ApplicationMusicPlayer.Queue.Entries()
        entries.append(contentsOf: retainedEntries)
        player.queue.entries = entries
        errorMessage = nil
        refreshQueueSnapshot()
    }

    func clearUpcomingQueue() {
        guard let currentID = currentQueueItem?.id else { return }
        removeQueueItems(ids: Set(queueItems.lazy.map(\.id).filter { $0 != currentID }))
    }

    func isCurrent(_ item: AppleMusicCatalogItem) -> Bool {
        state.currentItemID == item.musicItemID
    }

    private func observeQueue() {
        queueObservation = player.queue.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.refreshQueueSnapshot()
                }
            }
    }

    private func observePlayerState() {
        playerStateObservation = player.state.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.synchronizePlaybackStatus()
                }
            }
    }

    private func synchronizePlaybackStatus() {
        guard currentItem != nil else { return }
        switch player.state.playbackStatus {
        case .playing, .seekingForward, .seekingBackward:
            state.didStart()
            startProgressUpdates()
        case .paused, .interrupted, .stopped:
            state.didPause()
            refreshProgress()
            stopProgressUpdates()
        @unknown default:
            break
        }
        refreshQueueSnapshot()
    }

    private func refreshQueueSnapshot() {
        let currentEntryID = player.queue.currentEntry?.id
        let allItems = player.queue.entries.map { entry in
            AppleMusicQueueItem(
                id: entry.id,
                title: entry.title,
                subtitle: entry.subtitle ?? "Apple Music",
                duration: Self.duration(for: entry),
                artworkURL: entry.artwork?.url(width: 180, height: 180)
            )
        }
        if let currentIndex = allItems.firstIndex(where: { $0.id == currentEntryID }) {
            queueItems = Array(allItems[currentIndex...])
        } else {
            queueItems = allItems
        }
        currentQueueItem = AppleMusicQueuePresentation.currentItem(
            in: queueItems,
            currentEntryID: currentEntryID
        )
        refreshProgress()
    }

    private func refreshProgress() {
        elapsed = min(max(player.playbackTime, 0), max(duration, 0))
    }

    private func startProgressUpdates() {
        guard progressTask == nil else { return }
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.refreshProgress()
            }
        }
    }

    private func stopProgressUpdates() {
        progressTask?.cancel()
        progressTask = nil
    }

    private static func duration(for entry: MusicPlayer.Queue.Entry) -> TimeInterval {
        switch entry.item {
        case .song(let song):
            song.duration ?? 0
        case .musicVideo(let video):
            video.duration ?? 0
        case nil:
            max((entry.endTime ?? 0) - (entry.startTime ?? 0), 0)
        @unknown default:
            0
        }
    }
}
