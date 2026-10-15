import AppKit
import Foundation

public struct TrashService: Sendable {
    public init() {}

    public func moveToTrash(_ items: [ScanItem]) -> [TrashOutcome] {
        // Validate each authorization before letting an ancestor selection cover it.
        var outcomes = [TrashOutcome?](repeating: nil, count: items.count)
        var valid: [(index: Int, item: ScanItem)] = []
        var remainingDirectoryEntries = 250_000
        for (index, item) in items.enumerated() {
            do {
                try Self.validate(item, revalidateDirectoryContents: false, remainingEntries: &remainingDirectoryEntries)
                valid.append((index, item))
            } catch { outcomes[index] = TrashOutcome(item: item, destination: nil, error: error.localizedDescription) }
        }
        let normalized = valid.sorted {
            if $0.item.url.pathComponents.count == $1.item.url.pathComponents.count {
                return $0.item.url.path == $1.item.url.path ? $0.index < $1.index : $0.item.url.path < $1.item.url.path
            }
            return $0.item.url.pathComponents.count < $1.item.url.pathComponents.count
        }.reduce(into: [(index: Int, item: ScanItem)]()) { selected, entry in
            if let ancestor = selected.first(where: { PathPolicy.isWithin(entry.item.url, root: $0.item.url, allowRoot: true) }) {
                outcomes[entry.index] = TrashOutcome(item: entry.item, destination: nil,
                    error: "Seleção sobreposta ignorada; já incluída em \(ancestor.item.url.path).")
            } else { selected.append(entry) }
        }
        // Associated cleanup candidates depend on their owner's metadata proof. Move them
        // before any selected app bundle, retaining the preceding overlap normalization.
        let mutationOrder = normalized.filter { $0.item.category != .applications } +
                            normalized.filter { $0.item.category == .applications }
        for (index, item) in mutationOrder {
            do {
                // Revalidate immediately before this mutation, after any earlier Trash operations.
                try Self.validate(item, revalidateDirectoryContents: true, remainingEntries: &remainingDirectoryEntries)
                // Foundation accepts a path, not our descriptor/proof. Revalidation reduces the
                // race window but cannot make a concurrent rename/replacement OS-atomic.
                var destination: NSURL?
                try FileManager.default.trashItem(at: item.url, resultingItemURL: &destination)
                outcomes[index] = TrashOutcome(item: item, destination: destination as URL?, error: nil)
            } catch {
                outcomes[index] = TrashOutcome(item: item, destination: nil, error: error.localizedDescription)
            }
        }
        return items.enumerated().map { index, item in
            outcomes[index] ?? TrashOutcome(item: item, destination: nil, error: "Item não autorizado.")
        }
    }

    // Exposed internally for policy tests that do not mutate user data.
    static func validate(_ item: ScanItem) throws {
        var remaining = 250_000
        try validate(item, revalidateDirectoryContents: true, remainingEntries: &remaining)
    }

    private static func validate(_ item: ScanItem, revalidateDirectoryContents: Bool, remainingEntries: inout Int) throws {
        try Task.checkCancellation()
        let url = try SafeFilesystem.normalized(item.url)
        let root = try SafeFilesystem.normalized(item.authorization.root)
        guard PathPolicy.isWithin(url, root: root) else {
            throw FilesystemFailure.rejected("Item fora da raiz autorizada, ou a própria raiz: \(url.path)")
        }
        if let reason = PathPolicy.exclusion(url) {
            throw FilesystemFailure.rejected("Remoção recusada: \(reason): \(url.path)")
        }
        if item.category == .largeFiles,
           let reason = PathPolicy.largeFileExclusion(url, homeDirectory: FileManager.default.homeDirectoryForCurrentUser) {
            throw FilesystemFailure.rejected("Remoção recusada: \(reason): \(url.path)")
        }
        let components = url.pathComponents
        let protectedExact = ["/", "/Users", "/Applications", "/Volumes", FileManager.default.homeDirectoryForCurrentUser.path]
        if protectedExact.contains(url.path) ||
            (components.count == 3 && components[1] == "Users") ||
            (components.count == 4 && components[1] == "Users" && components[3] == "Library") {
            throw FilesystemFailure.rejected("Pasta essencial protegida: \(url.path)")
        }
        let current = try SafeFilesystem.inspect(url)
        guard !current.isSymlink, !current.isDataless,
              current.isDirectory || current.isRegularFile else {
            throw FilesystemFailure.rejected("Item não é um arquivo ou pasta local elegível: \(url.path)")
        }
        guard current.identity == item.authorization.leaf, current.fingerprint == item.authorization.fingerprint,
              current.ancestors == item.authorization.ancestors else {
            throw FilesystemFailure.rejected("O item ou seus ancestrais mudaram após a análise: \(url.path)")
        }
        if current.isDirectory, revalidateDirectoryContents {
            var verification = DirectoryVerification(maximumEntries: min(remainingEntries, item.authorization.directoryEntryBudget))
            defer { remainingEntries -= min(remainingEntries, verification.examined) }
            let measurement = try verification.measure(current)
            guard measurement.complete, measurement.bytes == item.bytes else {
                throw FilesystemFailure.rejected(verification.failure ??
                    "O tamanho do conteúdo da pasta mudou após a análise; analise novamente: \(url.path)")
            }
            guard try SafeFilesystem.inspect(url).proof == current.proof else {
                throw FilesystemFailure.rejected("A pasta mudou durante a revalidação: \(url.path)")
            }
        }
        // Recheck supporting metadata and live app state after a potentially long directory walk.
        for proof in item.authorization.supportingFiles {
            let current = try SafeFilesystem.inspect(proof.url)
            guard current.proof == proof else {
                throw FilesystemFailure.rejected("Os metadados do aplicativo mudaram após a análise: \(proof.url.path)")
            }
        }
        if item.category == .caches || item.category == .logs {
            if !NSRunningApplication.runningApplications(withBundleIdentifier: item.name).isEmpty {
                throw FilesystemFailure.rejected("Feche o aplicativo que usa este cache ou log antes de movê-lo: \(item.name).")
            }
        }
        if item.ownerAppURL != nil || item.category == .applications || item.category == .appRelated {
            let appURL = item.ownerAppURL ?? item.url
            if PathPolicy.isProtectedApp(appURL, bundleIdentifier: item.bundleIdentifier) {
                throw FilesystemFailure.rejected("Aplicativo Apple ou o próprio Zé Coleta protegido: \(appURL.path)")
            }
            let running: Bool
            if let identifier = item.bundleIdentifier {
                running = !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty
            } else {
                running = NSWorkspace.shared.runningApplications.contains {
                    $0.bundleURL?.standardizedFileURL == appURL.standardizedFileURL
                }
            }
            if running { throw FilesystemFailure.rejected("Feche o aplicativo antes de mover seus arquivos: \(appURL.lastPathComponent).") }
        }
    }
}
