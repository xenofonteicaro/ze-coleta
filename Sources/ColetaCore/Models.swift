import Foundation

public enum ScanCategory: String, CaseIterable, Sendable, Codable {
    case caches, logs, developer, largeFiles, applications, appRelated
}

public struct ScanRoot: Hashable, Sendable {
    public let url: URL
    public let category: ScanCategory

    public init(url: URL, category: ScanCategory) {
        self.url = url
        self.category = category
    }
}

public struct ScanRequest: Sendable {
    public let roots: [ScanRoot]
    public let minimumLargeFileBytes: Int64
    public let maximumEntries: Int
    public let maximumResults: Int

    public init(roots: [ScanRoot], minimumLargeFileBytes: Int64 = 100_000_000,
                maximumEntries: Int = 250_000, maximumResults: Int = 1_000) {
        self.roots = roots
        self.minimumLargeFileBytes = max(0, minimumLargeFileBytes)
        self.maximumEntries = max(0, maximumEntries)
        self.maximumResults = max(0, maximumResults)
    }
}

public struct ScanItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let category: ScanCategory
    public var name: String { url.lastPathComponent }
    public let bytes: Int64
    public let detail: String
    public let ownerAppURL: URL?
    public let bundleIdentifier: String?

    // Only the scanner can mint a deletion authorization. Display fields are not authority.
    let authorization: ItemAuthorization

    init(id: String = UUID().uuidString, url: URL, category: ScanCategory, bytes: Int64, detail: String,
         ownerAppURL: URL? = nil, bundleIdentifier: String? = nil,
         authorization: ItemAuthorization) {
        self.id = id
        self.url = url
        self.category = category
        self.bytes = bytes
        self.detail = detail
        self.ownerAppURL = ownerAppURL
        self.bundleIdentifier = bundleIdentifier
        self.authorization = authorization
    }

    func associating(_ association: AppAssociation) -> ScanItem {
        var authorization = authorization
        authorization.supportingFiles.append(association.infoProof)
        return ScanItem(id: id, url: url, category: category, bytes: bytes,
                        detail: detail + " " + association.detail,
                        ownerAppURL: association.ownerAppURL, bundleIdentifier: association.bundleIdentifier,
                        authorization: authorization)
    }
}

struct AppAssociation {
    let ownerAppURL: URL
    let bundleIdentifier: String
    let infoProof: FileProof

    var detail: String {
        "Relação inferida pelo nome exato do bundle ID \(bundleIdentifier); confirme e selecione separadamente."
    }
}

public struct ScanReport: Sendable {
    public let items: [ScanItem]
    public let issues: [String]
    public let examinedEntries: Int
    public let isComplete: Bool
}

public struct TrashOutcome: Sendable {
    public let item: ScanItem
    public let destination: URL?
    public let error: String?
}

struct FileIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let kind: UInt16
}

struct AncestryIdentity: Hashable, Sendable {
    let url: URL
    let identity: FileIdentity
}

struct ItemAuthorization: Hashable, Sendable {
    let root: URL
    let leaf: FileIdentity
    let fingerprint: FileFingerprint
    let ancestors: [AncestryIdentity]
    var supportingFiles: [FileProof] = []
    var directoryEntryBudget = 250_000
}

struct FileFingerprint: Hashable, Sendable {
    let bytes: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
}

struct FileProof: Hashable, Sendable {
    let url: URL
    let identity: FileIdentity
    let fingerprint: FileFingerprint
    let ancestors: [AncestryIdentity]
}
