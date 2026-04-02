import SwiftUI
import SwiftData

@main
struct MoonmindApp: App {
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
            // `.automatic` uses the first CloudKit container from entitlements (matches Xcode capability UI).
            let config = ModelConfiguration(
                schema: syncSchema,
                url: cloudStoreURL,
                cloudKitDatabase: .automatic
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
        Self.migrateLegacySavedItemsIfNeeded()
        Self.dedupeSavedItemsIfNeeded()
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
                id: item.id,
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

    private static func dedupeSavedItemsIfNeeded() {
        let context = Self.sharedModelContainer.mainContext
        let all = (try? context.fetch(FetchDescriptor<SavedItem>())) ?? []
        var byId: [UUID: [SavedItem]] = [:]
        for item in all { byId[item.id, default: []].append(item) }
        for group in byId.values where group.count > 1 {
            let sorted = group.sorted { $0.createdAt < $1.createdAt }
            for extra in sorted.dropFirst() { context.delete(extra) }
        }
        try? context.save()
    }
}
