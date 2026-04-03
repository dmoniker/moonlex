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

    private static let sharedModelContainer: ModelContainer = {
        let prefersCloud: Bool = {
            if UserDefaults.standard.object(forKey: MoonmindSyncSettings.preferICloudSyncKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: MoonmindSyncSettings.preferICloudSyncKey)
        }()

        if !prefersCloud {
            do {
                let config = ModelConfiguration(
                    schema: syncSchema,
                    url: localFallbackStoreURL,
                    cloudKitDatabase: .none
                )
                let container = try ModelContainer(for: syncSchema, configurations: [config])
                UserDefaults.standard.set(true, forKey: MoonmindSyncSettings.cloudKitInactiveKey)
                return container
            } catch {
                logSwiftDataContainerFailure(error, label: "SwiftData local-only (\(localFallbackStoreURL.lastPathComponent))")
                fatalError("SwiftData could not open the on-device store.")
            }
        }

        do {
            // Explicit container avoids rare `.automatic` resolution issues; must match `moonmind.entitlements`.
            let config = ModelConfiguration(
                schema: syncSchema,
                url: cloudStoreURL,
                cloudKitDatabase: .private(MoonmindCloudKit.containerIdentifier)
            )
            let container = try ModelContainer(for: syncSchema, configurations: [config])
            UserDefaults.standard.set(false, forKey: MoonmindSyncSettings.cloudKitInactiveKey)
            return container
        } catch {
            logSwiftDataContainerFailure(error, label: "SwiftData + CloudKit (.automatic, \(cloudStoreURL.lastPathComponent))")
            do {
                let fallback = ModelConfiguration(
                    schema: syncSchema,
                    url: localFallbackStoreURL,
                    cloudKitDatabase: .none
                )
                let container = try ModelContainer(for: syncSchema, configurations: [fallback])
                UserDefaults.standard.set(true, forKey: MoonmindSyncSettings.cloudKitInactiveKey)
                print("""
                moonmind: ⚠️ CloudKit-backed store failed; using LOCAL-ONLY SwiftData at \(localFallbackStoreURL.path).
                • On device: Settings → Apple ID → iCloud — confirm iCloud is on for this device.
                • Xcode target Signing & Capabilities: iCloud + CloudKit, container \(MoonmindCloudKit.containerIdentifier) must match the App ID in developer.apple.com (Identifiers → your app → iCloud).
                • Delete derived/local store files only if you understand data loss: uninstall app or remove the `.store` siblings under Application Support.
                """)
                return container
            } catch {
                logSwiftDataContainerFailure(error, label: "SwiftData local fallback (\(localFallbackStoreURL.lastPathComponent))")
                fatalError(
                    "SwiftData could not open CloudKit store OR local fallback. Read the NSError logs above in the Xcode console."
                )
            }
        }
    }()

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

    /// One-time copy of favorites from the store used before CloudKit + expanded schema.
    private static func migrateLegacySavedItemsIfNeeded() {
        let legacyURL = legacySwiftDataStoreURL
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }

        let legacySchema = Schema([SavedItem.self])
        let legacyConfiguration = ModelConfiguration(
            schema: legacySchema,
            url: legacyURL,
            cloudKitDatabase: .none
        )
        guard let legacyContainer = try? ModelContainer(for: legacySchema, configurations: [legacyConfiguration])
        else { return }

        let legacyContext = legacyContainer.mainContext
        let legacyItems = (try? legacyContext.fetch(FetchDescriptor<SavedItem>())) ?? []
        guard !legacyItems.isEmpty else { return }

        let mainContext = Self.sharedModelContainer.mainContext
        let newStoreCount = (try? mainContext.fetchCount(FetchDescriptor<SavedItem>())) ?? 0
        guard newStoreCount == 0 else { return }

        for item in legacyItems {
            let copy = SavedItem(
                favoriteId: item.favoriteId.isEmpty ? UUID().uuidString : item.favoriteId,
                createdAt: item.createdAt,
                episodeKey: item.episodeKey,
                episodeTitle: item.episodeTitle,
                showTitle: item.showTitle,
                feedID: item.feedID,
                feedURLString: item.feedURLString,
                audioURLString: item.audioURLString,
                episodePubDate: item.episodePubDate,
                linkURLString: item.linkURLString,
                excerpt: item.excerpt,
                note: item.note
            )
            mainContext.insert(copy)
        }
        try? mainContext.save()
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
        let prefersCloud: Bool = {
            if UserDefaults.standard.object(forKey: MoonmindSyncSettings.preferICloudSyncKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: MoonmindSyncSettings.preferICloudSyncKey)
        }()
        guard prefersCloud, UserDefaults.standard.bool(forKey: MoonmindSyncSettings.cloudKitInactiveKey) == false else { return }
        Task { @MainActor in
            let container = CKContainer(identifier: MoonmindCloudKit.containerIdentifier)
            do {
                let status = try await container.accountStatus()
                syncLogger.notice("iCloud account status: \(String(describing: status), privacy: .public)")
                switch status {
                case .available:
                    break
                case .couldNotDetermine, .restricted, .noAccount, .temporarilyUnavailable:
                    print("moonmind: iCloud for CloudKit is not fully available (status: \(String(describing: status))). Check Settings → Apple ID → iCloud.")
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
                try? ctx.save()
                Self.logCloudSnapshot(reason: "cloud import event")
            }
        }
    }
}
