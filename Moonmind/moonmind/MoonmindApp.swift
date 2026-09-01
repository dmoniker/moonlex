import CloudKit
import CoreData
import OSLog
import SwiftData
import SwiftUI

@main
struct MoonmindApp: App {
    private static let syncLogger = Logger(subsystem: "com.moonmind.moonmind", category: "CloudSync")
    private static let syncSchema = Schema([
        SavedItem.self,
        UserCustomFeed.self,
        HiddenBuiltinFeedRecord.self,
        PlaybackProgressRecord.self,
        SyncedAppPreferences.self,
    ])

    private static let cloudStoreURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        /// New filename so installs that hit the unique-constraint failure aren’t stuck on a bad store file.
        return dir.appendingPathComponent("moonmind-sync-v2.store", isDirectory: false)
    }()

    /// If CloudKit fails, use a different file so we never reopen a half-built CloudKit store with `.none`.
    private static let localFallbackStoreURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("moonmind-local.store", isDirectory: false)
    }()

    /// Previous builds used SwiftData’s default on-disk store at this URL.
    private static var legacySwiftDataStoreURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("default.store", isDirectory: false)
    }

    private static let legacyDefaultStoreMigratedKey = "moonmind.legacyDefaultStoreMigrated"

    private static let sharedModelContainer: ModelContainer = makeModelContainer()

    private static func prefersICloudSync() -> Bool {
        if UserDefaults.standard.object(forKey: MoonmindSyncSettings.preferICloudSyncKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: MoonmindSyncSettings.preferICloudSyncKey)
    }

    /// Blocks briefly at launch so we never open a CloudKit-backed store when iCloud is not signed in.
    private static func synchronousCloudKitAccountStatus() -> CKAccountStatus {
        let container = CKContainer(identifier: MoonmindCloudKit.containerIdentifier)
        var status: CKAccountStatus = .couldNotDetermine
        let group = DispatchGroup()
        group.enter()
        container.accountStatus { accountStatus, _ in
            status = accountStatus
            group.leave()
        }
        _ = group.wait(timeout: .now() + 5)
        return status
    }

    private static func openLocalOnlyContainer(reason: String) -> ModelContainer {
        do {
            let config = ModelConfiguration(
                schema: syncSchema,
                url: localFallbackStoreURL,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: syncSchema, configurations: [config])
            UserDefaults.standard.set(true, forKey: MoonmindSyncSettings.cloudKitInactiveKey)
            syncLogger.notice("\(reason, privacy: .public) — local-only store at \(localFallbackStoreURL.lastPathComponent, privacy: .public)")
            return container
        } catch {
            logSwiftDataContainerFailure(error, label: "SwiftData local-only (\(localFallbackStoreURL.lastPathComponent))")
            fatalError("SwiftData could not open the on-device store.")
        }
    }

    private static func makeModelContainer() -> ModelContainer {
        guard prefersICloudSync() else {
            return openLocalOnlyContainer(reason: "iCloud sync disabled in settings")
        }

        if synchronousCloudKitAccountStatus() == .noAccount {
            return openLocalOnlyContainer(reason: "No iCloud account signed in")
        }

        do {
            let config = ModelConfiguration(
                schema: syncSchema,
                url: cloudStoreURL,
                cloudKitDatabase: .private(MoonmindCloudKit.containerIdentifier)
            )
            let container = try ModelContainer(for: syncSchema, configurations: [config])
            UserDefaults.standard.set(false, forKey: MoonmindSyncSettings.cloudKitInactiveKey)
            return container
        } catch {
            logSwiftDataContainerFailure(error, label: "SwiftData + CloudKit (\(cloudStoreURL.lastPathComponent))")
            print("""
            moonmind: ⚠️ CloudKit-backed store failed; using LOCAL-ONLY SwiftData at \(localFallbackStoreURL.path).
            • On device: Settings → Apple ID → iCloud — confirm iCloud is on for this device.
            • Xcode target Signing & Capabilities: iCloud + CloudKit, container \(MoonmindCloudKit.containerIdentifier) must match the App ID in developer.apple.com (Identifiers → your app → iCloud).
            """)
            return openLocalOnlyContainer(reason: "CloudKit store failed to open")
        }
    }

    private static func logSwiftDataContainerFailure(_ error: Error, label: String) {
        let ns = error as NSError
        print("────────────────────────────────────────")
        print("moonmind SwiftData failure: \(label)")
        print("localizedDescription: \(error.localizedDescription)")
        print("domain: \(ns.domain)  code: \(ns.code)")
        print("userInfo: \(ns.userInfo)")
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            print("underlying.domain: \(underlying.domain) underlying.code: \(underlying.code)")
            print("underlying.userInfo: \(underlying.userInfo)")
            if let u2 = underlying.userInfo[NSUnderlyingErrorKey] as? NSError {
                print("underlying²: \(u2) userInfo: \(u2.userInfo)")
            }
        }
        print("────────────────────────────────────────")
    }

    init() {
        PodcastArtworkCache.configure()
        _ = Self.sharedModelContainer
        Self.syncLogger.notice("app init: SwiftData container ready")
        Self.migrateLegacySavedItemsIfNeeded()
        Self.repairSavedItemFavoriteIdsIfNeeded()
        Self.dedupeSavedItemsIfNeeded()
        Self.mergeSyncedAppPreferencesAfterCloudKitImportIfNeeded()
        Self.logCloudSnapshot(reason: "app init post-repair")
        Self.observeCloudKitSyncEvents()
        Self.logCloudKitAccountStatusIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .modelContainer(Self.sharedModelContainer)
    }

    /// One-time copy of favorites from `default.store` (UUID `id`) into the current sync store (`favoriteId` String).
    private static func migrateLegacySavedItemsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: legacyDefaultStoreMigratedKey) else {
            scheduleLegacyDefaultStoreRemoval()
            return
        }

        let legacyURL = legacySwiftDataStoreURL
        guard FileManager.default.fileExists(atPath: legacyURL.path) else {
            UserDefaults.standard.set(true, forKey: legacyDefaultStoreMigratedKey)
            return
        }

        let legacySchema = Schema([LegacySavedItem.self])
        let legacyConfiguration = ModelConfiguration(
            schema: legacySchema,
            url: legacyURL,
            cloudKitDatabase: .none
        )
        let legacyItems: [LegacySavedItem] = {
            guard let legacyContainer = try? ModelContainer(for: legacySchema, configurations: [legacyConfiguration])
            else {
                syncLogger.error("legacy default.store exists but could not be opened for migration")
                return []
            }
            return (try? legacyContainer.mainContext.fetch(FetchDescriptor<LegacySavedItem>())) ?? []
        }()

        guard !legacyItems.isEmpty else {
            scheduleLegacyDefaultStoreRemoval()
            UserDefaults.standard.set(true, forKey: legacyDefaultStoreMigratedKey)
            return
        }

        let mainContext = Self.sharedModelContainer.mainContext
        let newStoreCount = (try? mainContext.fetchCount(FetchDescriptor<SavedItem>())) ?? 0
        guard newStoreCount == 0 else {
            scheduleLegacyDefaultStoreRemoval()
            UserDefaults.standard.set(true, forKey: legacyDefaultStoreMigratedKey)
            return
        }

        for item in legacyItems {
            let copy = SavedItem(
                favoriteId: item.id.uuidString,
                createdAt: item.createdAt,
                episodeKey: item.episodeKey,
                episodeTitle: item.episodeTitle,
                showTitle: item.showTitle,
                feedID: item.feedID,
                feedURLString: item.feedURLString,
                audioURLString: item.audioURLString,
                episodePubDate: item.episodePubDate,
                linkURLString: item.linkURLString,
                artworkURLString: nil,
                excerpt: item.excerpt,
                note: item.note
            )
            mainContext.insert(copy)
        }
        try? mainContext.save()
        scheduleLegacyDefaultStoreRemoval()
        UserDefaults.standard.set(true, forKey: legacyDefaultStoreMigratedKey)
        syncLogger.notice("migrated \(legacyItems.count) SavedItem rows from legacy default.store")
    }

    /// Delete legacy SQLite files only after the migration `ModelContainer` has been torn down.
    private static func scheduleLegacyDefaultStoreRemoval() {
        DispatchQueue.main.async {
            removeLegacyDefaultStoreFilesIfPresent()
        }
    }

    private static func removeLegacyDefaultStoreFilesIfPresent() {
        let base = legacySwiftDataStoreURL
        let dir = base.deletingLastPathComponent()
        let name = base.lastPathComponent
        for suffix in ["", "-shm", "-wal"] {
            let url = dir.appendingPathComponent(name + suffix)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// After UUID → String migration, rows can briefly have an empty `favoriteId`; ensure each has a unique value before deduping.
    private static func repairSavedItemFavoriteIdsIfNeeded() {
        let context = Self.sharedModelContainer.mainContext
        let all = (try? context.fetch(FetchDescriptor<SavedItem>())) ?? []
        var changed = false
        for item in all where item.favoriteId.isEmpty {
            item.favoriteId = UUID().uuidString
            changed = true
        }
        if changed { try? context.save() }
    }

    private static func dedupeSavedItemsIfNeeded() {
        let context = Self.sharedModelContainer.mainContext
        let all = (try? context.fetch(FetchDescriptor<SavedItem>())) ?? []
        var byFavoriteId: [String: [SavedItem]] = [:]
        for item in all { byFavoriteId[item.favoriteId, default: []].append(item) }
        for group in byFavoriteId.values where group.count > 1 {
            let sorted = group.sorted { $0.createdAt < $1.createdAt }
            for extra in sorted.dropFirst() { context.delete(extra) }
        }
        var byEpisodeFavorite: [String: [SavedItem]] = [:]
        for item in all where item.excerpt.isEmpty {
            byEpisodeFavorite[item.episodeKey, default: []].append(item)
        }
        for group in byEpisodeFavorite.values where group.count > 1 {
            let sorted = group.sorted { $0.createdAt < $1.createdAt }
            for extra in sorted.dropFirst() { context.delete(extra) }
        }
        try? context.save()
    }

    /// Collapse duplicate preference rows (common when `id` was not `"default"` on imported CloudKit rows).
    private static func mergeSyncedAppPreferencesAfterCloudKitImportIfNeeded() {
        let ctx = sharedModelContainer.mainContext
        SyncedAppPreferences.mergeDuplicatesIfNeeded(in: ctx)
        try? ctx.save()
    }

    @MainActor
    private static func logCloudSnapshot(reason: String) {
        let ctx = sharedModelContainer.mainContext
        let favoritesFD = FetchDescriptor<SavedItem>(predicate: #Predicate { $0.excerpt == "" })
        let favorites = (try? ctx.fetchCount(favoritesFD)) ?? -1
        let progress = (try? ctx.fetchCount(FetchDescriptor<PlaybackProgressRecord>())) ?? -1
        let prefs = (try? ctx.fetchCount(FetchDescriptor<SyncedAppPreferences>())) ?? -1
        let customFeeds = (try? ctx.fetchCount(FetchDescriptor<UserCustomFeed>())) ?? -1
        let hiddenFeeds = (try? ctx.fetchCount(FetchDescriptor<HiddenBuiltinFeedRecord>())) ?? -1
        let prefRow = (try? ctx.fetch(FetchDescriptor<SyncedAppPreferences>()))?.first
        syncLogger.notice(
            """
            snapshot[\(reason, privacy: .public)] favorites=\(favorites) progress=\(progress) prefs=\(prefs) customFeeds=\(customFeeds) hiddenBuiltinFeeds=\(hiddenFeeds) prefID=\(prefRow?.id ?? "nil", privacy: .public) prefUpdatedAt=\(String(describing: prefRow?.updatedAt), privacy: .public)
            """
        )
    }

    private static func logCloudKitAccountStatusIfNeeded() {
        guard prefersICloudSync(), UserDefaults.standard.bool(forKey: MoonmindSyncSettings.cloudKitInactiveKey) == false else { return }
        Task { @MainActor in
            let container = CKContainer(identifier: MoonmindCloudKit.containerIdentifier)
            do {
                let status = try await container.accountStatus()
                syncLogger.notice("iCloud account status: \(String(describing: status), privacy: .public)")
                switch status {
                case .available:
                    break
                case .couldNotDetermine, .restricted, .temporarilyUnavailable:
                    print("moonmind: iCloud for CloudKit is not fully available (status: \(String(describing: status))). Check Settings → Apple ID → iCloud.")
                case .noAccount:
                    break
                @unknown default:
                    print("moonmind: iCloud account status unknown: \(String(describing: status))")
                }
            } catch {
                print("moonmind: Could not read iCloud account status for CloudKit: \(error)")
            }
        }
    }

    private static func observeCloudKitSyncEvents() {
        NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: OperationQueue.main
        ) { notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event
            else { return }
            guard event.endDate != nil else { return }
            syncLogger.notice(
                "cloud event finished type=\(String(describing: event.type), privacy: .public) succeeded=\(event.succeeded, privacy: .public) error=\(String(describing: event.error), privacy: .public)"
            )
            if !event.succeeded {
                print("""
                moonmind: CloudKit sync event failed
                type: \(String(describing: event.type))
                error: \(event.error.map { "\($0)" } ?? "nil")
                """)
                return
            }
            guard event.type == .import else { return }
            Task { @MainActor in
                let ctx = Self.sharedModelContainer.mainContext
                SyncedAppPreferences.mergeDuplicatesIfNeeded(in: ctx)
                Self.logCloudSnapshot(reason: "cloud import event")
            }
        }
    }
}
