import Darwin
import Foundation
import Testing
@testable import ColetaCore

private struct Fixture {
    let root: URL

    init() throws {
        // Keep owned fixtures outside /private even when the checkout itself lives under /tmp.
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        var pattern = Array(home.appendingPathComponent(".ze-coleta-tests.XXXXXX").path.utf8CString)
        guard let result = mkdtemp(&pattern) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        root = URL(fileURLWithPath: String(cString: result), isDirectory: true)
    }

    func clean() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func directory(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func file(_ relative: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 65, count: bytes).write(to: url)
        return url
    }

    @discardableResult
    func app(_ relative: String, identifier: String) throws -> URL {
        let url = try directory(relative + "/Contents")
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier], format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Info.plist"))
        try file(relative + "/Contents/payload", bytes: 100)
        return url.deletingLastPathComponent()
    }
}

struct ColetaCoreTests {
    @Test func realTrashMovesOnlyTheDisposableFixtureAndRestoresItsExactDestination() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let original = try fixture.file("trash-fixture-\(UUID().uuidString)", bytes: 8)
        let report = try FileScanner().scan(ScanRequest(roots: [.init(url: fixture.root, category: .largeFiles)], minimumLargeFileBytes: 1))
        let item = try #require(report.items.first)
        var restoreFrom: URL?
        defer {
            if let restoreFrom { try? FileManager.default.moveItem(at: restoreFrom, to: original) }
        }
        let outcomes = TrashService().moveToTrash([item, item])
        let moved = try #require(outcomes.first)
        #expect(moved.error == nil)
        let destination = try #require(moved.destination)
        restoreFrom = destination
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(try SafeFilesystem.inspect(destination).identity == item.authorization.leaf)
        #expect(outcomes.count == 2)
        #expect(outcomes[1].error?.contains("sobreposta") == true)
        #expect(outcomes[1].destination == nil)
        try FileManager.default.moveItem(at: destination, to: original)
        restoreFrom = nil
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func associatedCleanupMovesBeforeSelectedOwnerAndBothTrashDestinationsAreRestored() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let identifier = "org.example.coleta-fixture-" + UUID().uuidString
        let app = try fixture.app("Applications/Disposable-\(UUID().uuidString).app", identifier: identifier)
        let home = try fixture.directory("home")
        let cache = try fixture.file("home/Library/Caches/\(identifier)/data", bytes: 8).deletingLastPathComponent()
        let report = try FileScanner(homeDirectory: home).scan(ScanRequest(roots: [
            .init(url: cache.deletingLastPathComponent(), category: .caches),
            .init(url: app.deletingLastPathComponent(), category: .applications)
        ]))
        let appItem = try #require(report.items.first { $0.category == .applications })
        let cacheItem = try #require(report.items.first { $0.category == .caches })
        #expect(cacheItem.ownerAppURL?.path == app.path)
        var restorePairs: [(source: URL, original: URL)] = []
        defer {
            for pair in restorePairs { try? FileManager.default.moveItem(at: pair.source, to: pair.original) }
        }
        let outcomes = TrashService().moveToTrash([appItem, cacheItem])
        for outcome in outcomes {
            if let destination = outcome.destination { restorePairs.append((destination, outcome.item.url)) }
        }
        #expect(outcomes.allSatisfy { $0.error == nil && $0.destination != nil })
        #expect(!FileManager.default.fileExists(atPath: app.path))
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        while let pair = restorePairs.first {
            try FileManager.default.moveItem(at: pair.source, to: pair.original)
            restorePairs.removeFirst()
            #expect(!FileManager.default.fileExists(atPath: pair.source.path))
            #expect(FileManager.default.fileExists(atPath: pair.original.path))
        }
    }

    @Test func immediateChildrenAreAggregatedAndCategoriesArePreserved() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        try fixture.file("cache/one/a", bytes: 31)
        try fixture.file("cache/one/sub/b", bytes: 19)
        try fixture.file("cache/two", bytes: 7)
        for category in [ScanCategory.caches, .logs, .developer] {
            let report = try FileScanner().scan(ScanRequest(roots: [ScanRoot(url: fixture.root.appendingPathComponent("cache"), category: category)]))
            #expect(report.isComplete)
            #expect(report.items.map(\.bytes) == [50, 7])
            #expect(report.items.allSatisfy { $0.category == category })
            #expect(report.items.map(\.name) == ["one", "two"])
            for item in report.items { try TrashService.validate(item) }
        }
    }

    @Test func largeFilesApplyThresholdOrderingAndPackageCloudPhotoExclusions() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        try fixture.file("chosen/big", bytes: 200)
        try fixture.file("chosen/deeper/medium", bytes: 100)
        try fixture.file("chosen/small", bytes: 99)
        try fixture.file("chosen/Fake.app/payload", bytes: 800)
        try fixture.file("chosen/CloudStorage/cloud", bytes: 900)
        try fixture.file("chosen/Pictures.photoslibrary/original", bytes: 900)
        let report = try FileScanner().scan(ScanRequest(roots: [.init(url: fixture.root.appendingPathComponent("chosen"), category: .largeFiles)], minimumLargeFileBytes: 100))
        #expect(report.items.map(\.bytes) == [200, 100])
        #expect(report.items.allSatisfy { $0.category == .largeFiles })
        #expect(!report.isComplete)
        #expect(report.issues.contains { $0.contains("nuvem") })
        #expect(report.issues.contains { $0.contains("fotos") })
        #expect(report.issues.contains { $0.contains("Pacote") })
    }

    @Test func resultLimitRetainsLargestItemsAndEntryLimitNeverReturnsPartialAggregate() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        for index in 1...8 { try fixture.file("large/file-\(index)", bytes: index * 20) }
        let root = ScanRoot(url: fixture.root.appendingPathComponent("large"), category: .largeFiles)
        let limited = try FileScanner().scan(ScanRequest(roots: [root], minimumLargeFileBytes: 1, maximumResults: 2))
        #expect(limited.items.map(\.bytes) == [160, 140])
        #expect(!limited.isComplete)
        #expect(limited.examinedEntries == 9)
        let bounded = try FileScanner().scan(ScanRequest(roots: [root], minimumLargeFileBytes: 1, maximumEntries: 3))
        #expect(bounded.examinedEntries == 3)
        #expect(!bounded.isComplete)
        try fixture.file("cache/folder/one", bytes: 10)
        try fixture.file("cache/folder/two", bytes: 10)
        let aggregate = try FileScanner().scan(ScanRequest(roots: [.init(url: fixture.root.appendingPathComponent("cache"), category: .caches)], maximumEntries: 3))
        #expect(aggregate.items.isEmpty)
        #expect(!aggregate.isComplete)
        let zero = try FileScanner().scan(ScanRequest(roots: [root], maximumEntries: 0))
        #expect(zero.items.isEmpty)
        #expect(zero.examinedEntries == 0)
        #expect(!zero.isComplete)
    }

    @Test func symlinkLeavesAndAncestorsAreNeverFollowed() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let real = try fixture.directory("real")
        try fixture.file("real/data", bytes: 500)
        let root = try fixture.directory("chosen")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: real)
        let report = try FileScanner().scan(ScanRequest(roots: [.init(url: root, category: .largeFiles)], minimumLargeFileBytes: 1))
        #expect(report.items.isEmpty)
        #expect(!report.isComplete)
        let indirect = root.appendingPathComponent("link/deeper")
        try fixture.file("real/deeper/file", bytes: 50)
        let ancestor = try FileScanner().scan(ScanRequest(roots: [.init(url: indirect, category: .caches)]))
        #expect(ancestor.items.isEmpty)
        #expect(!ancestor.isComplete)
    }

    @Test func symbolicLinksInsideAggregatesCountOnlyTheirOwnBytes() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        try fixture.file("outside/payload", bytes: 5_000)
        try fixture.file("cache/folder/own", bytes: 10)
        let link = fixture.root.appendingPathComponent("cache/folder/link")
        let target = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let report = try FileScanner().scan(ScanRequest(roots: [.init(url: fixture.root.appendingPathComponent("cache"), category: .caches)]))
        let linkSize = try SafeFilesystem.inspect(link).bytes
        #expect(report.isComplete)
        #expect(report.items.map(\.bytes) == [10 + linkSize])
    }

    @Test func identityChangesAndAncestorSubstitutionInvalidateTrashAuthority() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let file = try fixture.file("chosen/file", bytes: 50)
        let root = fixture.root.appendingPathComponent("chosen")
        let report = try FileScanner().scan(ScanRequest(roots: [.init(url: root, category: .caches)]))
        let item = try #require(report.items.first)
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("original"))
        try fixture.file("chosen/file", bytes: 50)
        #expect(throws: (any Error).self) { try TrashService.validate(item) }

        let fresh = try FileScanner().scan(ScanRequest(roots: [.init(url: root, category: .caches)]))
        let freshItem = try #require(fresh.items.first)
        let old = fixture.root.appendingPathComponent("old-root")
        try FileManager.default.moveItem(at: root, to: old)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: old)
        #expect(throws: (any Error).self) { try TrashService.validate(freshItem) }
    }

    @Test func inPlaceWritesAndBundleMetadataChangesInvalidateTrashAuthority() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let file = try fixture.file("chosen/file", bytes: 50)
        let report = try FileScanner().scan(ScanRequest(roots: [.init(url: file.deletingLastPathComponent(), category: .caches)]))
        let item = try #require(report.items.first)
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data([66]))
        try handle.close()
        #expect(try SafeFilesystem.inspect(file).identity == item.authorization.leaf)
        #expect(throws: (any Error).self) { try TrashService.validate(item) }
        let outcomes = TrashService().moveToTrash([item, item])
        #expect(outcomes.count == 2)
        #expect(outcomes.allSatisfy { $0.error != nil && $0.destination == nil })
        #expect(FileManager.default.fileExists(atPath: file.path))

        let app = try fixture.app("Applications/Test.app", identifier: "org.example.before")
        let apps = try FileScanner(homeDirectory: fixture.root.appendingPathComponent("absent-home")).scan(ScanRequest(roots: [.init(url: app.deletingLastPathComponent(), category: .applications)]))
        let appItem = try #require(apps.items.first { $0.category == .applications })
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.example.after"], format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        #expect(throws: (any Error).self) { try TrashService.validate(appItem) }
    }

    @Test func nestedGrowthAndNewProtectedDescendantsInvalidateDirectoryApproval() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let payload = try fixture.file("cache/growing/nested/file", bytes: 5)
        let root = fixture.root.appendingPathComponent("cache")
        let initial = try FileScanner().scan(ScanRequest(roots: [.init(url: root, category: .caches)]))
        let growing = try #require(initial.items.first)
        try Data(repeating: 66, count: 50).write(to: payload)
        #expect(try SafeFilesystem.inspect(growing.url).fingerprint == growing.authorization.fingerprint)
        #expect(throws: (any Error).self) { try TrashService.validate(growing) }
        let growthOutcome = try #require(TrashService().moveToTrash([growing]).first)
        #expect(growthOutcome.error?.contains("tamanho") == true)
        #expect(FileManager.default.fileExists(atPath: growing.url.path))

        let refreshed = try FileScanner().scan(ScanRequest(roots: [.init(url: root, category: .caches)]))
        let protected = try #require(refreshed.items.first)
        try fixture.file("cache/growing/nested/CloudStorage/placeholder", bytes: 0)
        #expect(try SafeFilesystem.inspect(protected.url).fingerprint == protected.authorization.fingerprint)
        #expect(throws: (any Error).self) { try TrashService.validate(protected) }
        let protectedOutcome = try #require(TrashService().moveToTrash([protected]).first)
        #expect(protectedOutcome.error?.contains("nuvem") == true)
        #expect(FileManager.default.fileExists(atPath: protected.url.path))
    }

    @Test func directoryRevalidationHonorsRecordedEntryBudget() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        try fixture.file("cache/folder/nested/file", bytes: 5)
        let report = try FileScanner().scan(ScanRequest(roots: [.init(url: fixture.root.appendingPathComponent("cache"), category: .caches)], maximumEntries: 4))
        #expect(report.isComplete)
        let item = try #require(report.items.first)
        try TrashService.validate(item)
        // Empty additions preserve the reviewed logical size and top-level fingerprint,
        // but a new unbounded descendant tree cannot inherit the old approval.
        try fixture.directory("cache/folder/nested/new/deeper")
        #expect(try SafeFilesystem.inspect(item.url).fingerprint == item.authorization.fingerprint)
        #expect(throws: (any Error).self) { try TrashService.validate(item) }
        let outcome = try #require(TrashService().moveToTrash([item]).first)
        #expect(outcome.error?.contains("Limite") == true)
        #expect(FileManager.default.fileExists(atPath: item.url.path))
    }

    @Test func inaccessibleDirectoryIsReportedAndNeverAggregatedAsZero() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let folder = try fixture.directory("cache/inaccessible")
        try fixture.file("cache/inaccessible/file", bytes: 100)
        #expect(chmod(folder.path, 0) == 0)
        defer { _ = chmod(folder.path, 0o700) }
        let report = try FileScanner().scan(ScanRequest(roots: [.init(url: folder.deletingLastPathComponent(), category: .caches)]))
        #expect(report.items.isEmpty)
        #expect(!report.isComplete)
        #expect(report.issues.contains { $0.contains("inaccessible") })
    }

    @Test func rootAuthorityUsesComponentsAndRejectsTheRootItself() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let root = try fixture.directory("chosen")
        let outside = try fixture.file("chosen-other/file", bytes: 2)
        let snapshot = try SafeFilesystem.inspect(outside)
        let rootSnapshot = try SafeFilesystem.inspect(root)
        #expect(!PathPolicy.isWithin(outside, root: root))
        #expect(throws: (any Error).self) { try PathPolicy.authorization(for: snapshot, root: rootSnapshot) }
        let forged = ScanItem(url: root, category: .caches, bytes: 0, detail: "test", authorization: ItemAuthorization(root: root, leaf: rootSnapshot.identity, fingerprint: rootSnapshot.fingerprint, ancestors: rootSnapshot.ancestors))
        #expect(throws: (any Error).self) { try TrashService.validate(forged) }
    }

    @Test func exactBundleIdentifiersProduceSeparateInferredRelatedCandidates() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let app = try fixture.app("Applications/Example.app", identifier: "org.example.test-coleta")
        let home = try fixture.directory("home")
        try fixture.file("home/Library/Caches/org.example.test-coleta/data", bytes: 42)
        try fixture.file("home/Library/Logs/org.example.test-coleta/log", bytes: 12)
        try fixture.file("home/Library/Preferences/org.example.test-coleta.plist", bytes: 7)
        try fixture.file("home/Library/Caches/org.example.test-coleta-helper/data", bytes: 100)
        try fixture.file("home/Library/Application Support/org.example.test-coleta/data", bytes: 100)
        try fixture.file("home/Library/Containers/org.example.test-coleta/data", bytes: 100)
        let report = try FileScanner(homeDirectory: home).scan(ScanRequest(roots: [.init(url: app.deletingLastPathComponent(), category: .applications)]))
        #expect(report.isComplete)
        #expect(report.items.filter { $0.category == .applications }.count == 1)
        let related = report.items.filter { $0.category == .appRelated }
        #expect(related.map(\.bytes) == [42, 12, 7])
        #expect(related.allSatisfy { $0.ownerAppURL?.path == app.path && $0.detail.contains("inferida") })
        for item in report.items { try TrashService.validate(item) }
    }

    @Test func overviewAssociatesExistingCleanupCandidatesWithoutDuplicatingIdentityOrCategory() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let app = try fixture.app("Applications/Example.app", identifier: "org.example.overview")
        let home = try fixture.directory("home")
        let cache = try fixture.file("home/Library/Caches/org.example.overview/data", bytes: 42).deletingLastPathComponent()
        let log = try fixture.file("home/Library/Logs/org.example.overview/log", bytes: 12).deletingLastPathComponent()
        try fixture.file("home/Library/Preferences/org.example.overview.plist", bytes: 7)
        let scanner = FileScanner(homeDirectory: home)
        let appRoot = ScanRoot(url: app.deletingLastPathComponent(), category: .applications)
        let appsOnly = try scanner.scan(ScanRequest(roots: [appRoot]))
        let overview = try scanner.scan(ScanRequest(roots: [
            .init(url: cache.deletingLastPathComponent(), category: .caches),
            .init(url: log.deletingLastPathComponent(), category: .logs), appRoot
        ]))
        #expect(overview.isComplete)
        #expect(overview.items.count == appsOnly.items.count)
        #expect(Set(overview.items.map(\.url)).count == overview.items.count)
        #expect(overview.items.first { $0.url.path == cache.path }?.category == .caches)
        #expect(overview.items.first { $0.url.path == log.path }?.category == .logs)
        let associated = overview.items.filter { $0.ownerAppURL != nil }
        #expect(associated.count == 3)
        for item in associated {
            let other = try #require(appsOnly.items.first { $0.url == item.url })
            #expect(item.ownerAppURL?.path == app.path)
            #expect(item.ownerAppURL == other.ownerAppURL)
            #expect(item.bundleIdentifier == other.bundleIdentifier)
            #expect(item.authorization.supportingFiles == other.authorization.supportingFiles)
            #expect(item.authorization.supportingFiles.count == 1)
            try TrashService.validate(item)
        }
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.example.changed"], format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        for item in associated + appsOnly.items.filter({ $0.ownerAppURL != nil }) {
            #expect(throws: (any Error).self) { try TrashService.validate(item) }
        }
    }

    @Test func absentApplicationRootIsKnownWhileUnreadableInventorySuppressesAssociations() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let app = try fixture.app("Applications/Example.app", identifier: "org.example.optional-root")
        let home = try fixture.directory("home")
        let cache = try fixture.file("home/Library/Caches/org.example.optional-root/data", bytes: 42).deletingLastPathComponent()
        let scanner = FileScanner(homeDirectory: home)
        let appRoot = ScanRoot(url: app.deletingLastPathComponent(), category: .applications)
        let missing = ScanRoot(url: home.appendingPathComponent("Applications"), category: .applications)
        let report = try scanner.scan(ScanRequest(roots: [appRoot, missing]))
        #expect(report.items.filter { $0.ownerAppURL?.path == app.path }.count == 1)
        #expect(report.issues.contains { $0.contains(missing.url.path) })
        #expect(!report.issues.contains { $0.contains("inventário") && $0.contains("incompleto") })

        let unreadable = try fixture.directory("unreadable-applications")
        #expect(chmod(unreadable.path, 0) == 0)
        defer { _ = chmod(unreadable.path, 0o700) }
        let uncertain = try scanner.scan(ScanRequest(roots: [
            .init(url: cache.deletingLastPathComponent(), category: .caches), appRoot,
            .init(url: unreadable, category: .applications)
        ]))
        #expect(uncertain.items.first { $0.url.path == cache.path }?.category == .caches)
        #expect(uncertain.items.allSatisfy { $0.ownerAppURL == nil })
        #expect(uncertain.issues.contains { $0.contains("inventário") && $0.contains("incompleto") })
    }

    @Test func invalidApplicationRootLeavesInventoryUnknownAndSuppressesAssociations() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let app = try fixture.app("Applications/Example.app", identifier: "org.example.invalid-root")
        let home = try fixture.directory("home")
        let cache = try fixture.file("home/Library/Caches/org.example.invalid-root/data", bytes: 42).deletingLastPathComponent()
        let invalid = try #require(URL(string: "https://example.test/apps"))
        let report = try FileScanner(homeDirectory: home).scan(ScanRequest(roots: [
            .init(url: cache.deletingLastPathComponent(), category: .caches),
            .init(url: app.deletingLastPathComponent(), category: .applications),
            .init(url: invalid, category: .applications)
        ]))
        #expect(!report.isComplete)
        #expect(report.items.first { $0.url.path == app.path }?.category == .applications)
        #expect(report.items.first { $0.url.path == cache.path }?.category == .caches)
        #expect(report.items.allSatisfy { $0.ownerAppURL == nil && $0.category != .appRelated })
        #expect(report.issues.contains { $0.contains(invalid.absoluteString) })
        #expect(report.issues.contains { $0.contains("inventário") && $0.contains("incompleto") })
    }

    @Test func duplicateBundleIdentifiersSuppressAmbiguousRelatedCandidates() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        try fixture.app("Applications/One.app", identifier: "org.example.duplicate")
        try fixture.app("Applications/Two.app", identifier: "org.example.duplicate")
        let home = try fixture.directory("home")
        try fixture.file("home/Library/Caches/org.example.duplicate/data", bytes: 20)
        let report = try FileScanner(homeDirectory: home).scan(ScanRequest(roots: [
            .init(url: home.appendingPathComponent("Library/Caches"), category: .caches),
            .init(url: fixture.root.appendingPathComponent("Applications"), category: .applications)
        ]))
        #expect(report.items.filter { $0.category == .applications }.count == 2)
        #expect(report.items.allSatisfy { $0.category != .appRelated })
        #expect(report.items.allSatisfy { $0.ownerAppURL == nil })
        #expect(!report.isComplete)
        #expect(report.issues.contains { $0.contains("mais de um") })
    }

    @Test func partialApplicationInventoryCannotAuthorizeRelatedFiles() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        try fixture.app("Applications/One.app", identifier: "org.example.one")
        try fixture.app("Applications/Two.app", identifier: "org.example.two")
        let home = try fixture.directory("home")
        try fixture.file("home/Library/Caches/org.example.one/data", bytes: 20)
        try fixture.file("home/Library/Caches/org.example.two/data", bytes: 20)
        let report = try FileScanner(homeDirectory: home).scan(ScanRequest(roots: [.init(url: fixture.root.appendingPathComponent("Applications"), category: .applications)], maximumEntries: 5))
        #expect(report.examinedEntries == 5)
        #expect(!report.isComplete)
        #expect(report.items.allSatisfy { $0.category != .appRelated })
        #expect(report.issues.contains { $0.contains("inventário") && $0.contains("incompleto") })
    }

    @Test func largeFilesNeverEnterUserLibraryOrChosenPackages() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        try fixture.file("Library/Containers/org.example.app/data", bytes: 100)
        try fixture.file("Library/Group Containers/org.example.app/data", bytes: 100)
        try fixture.file("Library/Application Support/org.example.app/data", bytes: 100)
        try fixture.file("Downloads/ordinary", bytes: 100)
        let scanner = FileScanner(homeDirectory: fixture.root)
        let report = try scanner.scan(ScanRequest(roots: [.init(url: fixture.root, category: .largeFiles)], minimumLargeFileBytes: 1))
        #expect(report.items.map(\.name) == ["ordinary"])
        #expect(!report.isComplete)
        #expect(report.issues.contains { $0.contains("Library") })
        let app = try fixture.app("Downloads/Example.app", identifier: "org.example.package")
        let package = try scanner.scan(ScanRequest(roots: [.init(url: app, category: .largeFiles)], minimumLargeFileBytes: 1))
        #expect(package.items.isEmpty)
        #expect(!package.isComplete)
    }

    @Test func ownAppAppleAppsAndSystemRootsAreProtected() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        try fixture.app("Applications/Self.app", identifier: PathPolicy.ownBundleIdentifier)
        try fixture.app("Applications/Apple.app", identifier: "com.apple.example")
        let report = try FileScanner(homeDirectory: fixture.root).scan(ScanRequest(roots: [.init(url: fixture.root.appendingPathComponent("Applications"), category: .applications)]))
        #expect(report.items.isEmpty)
        let system = try FileScanner().scan(ScanRequest(roots: [.init(url: URL(fileURLWithPath: "/System"), category: .caches)]))
        #expect(system.items.isEmpty)
        #expect(!system.isComplete)
        #expect(system.examinedEntries == 0)
    }

    @Test func duplicateAndOverlappingRootsDoNotRepeatTraversal() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        try fixture.file("chosen/nested/file", bytes: 11)
        let broad = ScanRoot(url: fixture.root.appendingPathComponent("chosen"), category: .largeFiles)
        let narrow = ScanRoot(url: fixture.root.appendingPathComponent("chosen/nested"), category: .largeFiles)
        let report = try FileScanner().scan(ScanRequest(roots: [narrow, broad, broad], minimumLargeFileBytes: 1))
        #expect(report.items.count == 1)
        #expect(report.examinedEntries == 3)
        #expect(!report.isComplete)
    }

    @Test func overlappingRootsWithDistinctPurposesPreserveCleanupAndApplicationPasses() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let home = try fixture.directory("home")
        let app = try fixture.app("home/Applications/Example.app", identifier: "org.example.distinct-purposes")
        let cache = try fixture.file("home/Library/Caches/org.example.distinct-purposes/data", bytes: 10).deletingLastPathComponent()
        let ordinary = try fixture.file("home/Downloads/ordinary", bytes: 50)
        let report = try FileScanner(homeDirectory: home).scan(ScanRequest(roots: [
            .init(url: home, category: .largeFiles),
            .init(url: cache.deletingLastPathComponent(), category: .caches),
            .init(url: app.deletingLastPathComponent(), category: .applications)
        ], minimumLargeFileBytes: 1))
        #expect(report.items.first { $0.url.path == ordinary.path }?.category == .largeFiles)
        #expect(report.items.first { $0.url.path == cache.path }?.category == .caches)
        #expect(report.items.first { $0.url.path == cache.path }?.ownerAppURL?.path == app.path)
        #expect(report.items.first { $0.url.path == app.path }?.category == .applications)
        #expect(!report.issues.contains { $0.contains("coberta por") })
        #expect(!report.issues.contains { $0.contains("Pasta já percorrida") })
    }

    @Test func missingRootsRemainVisibleAndCancellationThrows() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let missing = fixture.root.appendingPathComponent("missing")
        let report = try FileScanner().scan(ScanRequest(roots: [.init(url: missing, category: .logs)]))
        #expect(report.items.isEmpty)
        #expect(!report.isComplete)
        #expect(!report.issues.isEmpty)
        let task = Task.detached {
            // Yield until the caller has requested cancellation, avoiding a timing-dependent test.
            while !Task.isCancelled { await Task.yield() }
            return try FileScanner().scan(ScanRequest(roots: [.init(url: missing, category: .logs)]))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
