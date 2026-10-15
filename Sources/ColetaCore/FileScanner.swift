import Foundation

public struct FileScanner: Sendable {
    private let homeDirectory: URL

    public init() { homeDirectory = FileManager.default.homeDirectoryForCurrentUser }
    init(homeDirectory: URL) { self.homeDirectory = homeDirectory }

    public func scan(_ request: ScanRequest, progress: @Sendable (Int) -> Void = { _ in }) throws -> ScanReport {
        try withoutActuallyEscaping(progress) { callback in
            var scan = ScanState(request: request, homeDirectory: homeDirectory, progress: callback)
            return try scan.run()
        }
    }
}

private struct AppRecord {
    let snapshot: FileSnapshot
    let identifier: BundleIdentifier?
}

private struct DirectoryVisit: Hashable {
    let identity: FileIdentity
    let purpose: ScanCategory
}

private struct ScanState: LogicalMeasurementContext {
    let request: ScanRequest
    let homeDirectory: URL
    let progress: @Sendable (Int) -> Void
    var examined = 0
    var complete = true
    var issues: [String] = []
    var additionalIssues = 0
    var issueKeys = Set<String>()
    var visitedPaths = Set<String>()
    var knownMissingPaths = Set<String>()
    var visitedDirectories = Set<DirectoryVisit>()
    var traversalPurpose = ScanCategory.caches
    var results = ResultHeap()
    var applications: [AppRecord] = []
    var entryLimitReached = false
    var resultLimitReached = false
    var candidatePaths = Set<String>()
    var appInfoProofs: [String: FileProof] = [:]
    var applicationInventoryComplete = true

    mutating func run() throws -> ScanReport {
        try Task.checkCancellation()
        var roots: [ScanRoot] = []
        // Only equivalent semantic passes can subsume a narrower requested root.
        let normalized = request.roots.compactMap { root -> ScanRoot? in
            do { return ScanRoot(url: try SafeFilesystem.normalized(root.url), category: root.category) }
            catch {
                if root.category == .applications { applicationInventoryComplete = false }
                issue(error.localizedDescription)
                return nil
            }
        }.sorted { $0.url.pathComponents.count < $1.url.pathComponents.count }
        for root in normalized {
            if let existing = roots.first(where: { $0.category == root.category && PathPolicy.isWithin(root.url, root: $0.url, allowRoot: true) }) {
                if existing != root {
                    issue("Raiz sobreposta não percorrida novamente: \(root.url.path) (coberta por \(existing.url.path)).")
                }
                continue
            }
            roots.append(root)
        }
        for root in roots {
            try Task.checkCancellation()
            guard !entryLimitReached else { break }
            traversalPurpose = root.category
            if root.category == .appRelated {
                issue("Arquivos relacionados exigem a análise de aplicativos para estabelecer o bundle ID: \(root.url.path).")
                continue
            }
            if let reason = PathPolicy.exclusion(root.url) {
                issue("\(root.url.path): \(reason).")
                if root.category == .applications { applicationInventoryComplete = false }
                continue
            }
            if root.category == .largeFiles, let reason = PathPolicy.largeFileExclusion(root.url, homeDirectory: homeDirectory) {
                issue("\(root.url.path): \(reason).")
                continue
            }
            guard let snapshot = try examine(root.url) else {
                if root.category == .applications, !knownMissingPaths.contains(root.url.path) { applicationInventoryComplete = false }
                continue
            }
            guard snapshot.isDirectory, !snapshot.isDataless else {
                issue("Raiz não é uma pasta local disponível: \(root.url.path).")
                if root.category == .applications { applicationInventoryComplete = false }
                continue
            }
            switch root.category {
            case .largeFiles:
                do {
                    if try snapshot.url.resourceValues(forKeys: [.isPackageKey]).isPackage == true {
                        issue("Pacote excluído da busca de arquivos grandes: \(snapshot.url.path).")
                    } else { try scanLargeFiles(snapshot, root: snapshot) }
                } catch is CancellationError { throw CancellationError() }
                catch { issue(error.localizedDescription) }
            case .applications:
                try scanApplications(snapshot)
            case .caches, .logs, .developer:
                try scanChildren(snapshot, category: root.category)
            case .appRelated:
                break
            }
        }
        traversalPurpose = .appRelated
        if !applications.isEmpty { try scanRelatedFiles() }
        if resultLimitReached { issue("Limite de \(request.maximumResults) resultados atingido; somente os maiores candidatos são exibidos.") }
        if additionalIssues > 0 { issues.append("Mais \(additionalIssues) avisos de cobertura foram omitidos.") }
        progress(examined)
        return ScanReport(items: results.sorted(), issues: issues, examinedEntries: examined, isComplete: complete)
    }

    mutating func issue(_ message: String) {
        complete = false
        guard !issueKeys.contains(message) else { return }
        if issues.count < 100 { issueKeys.insert(message); issues.append(message) }
        else { additionalIssues += 1 }
    }

    mutating func examine(_ url: URL, missingIsExpected: Bool = false) throws -> FileSnapshot? {
        try Task.checkCancellation()
        if !visitedPaths.contains(url.path) {
            guard examined < request.maximumEntries else {
                entryLimitReached = true
                issue("Limite global de \(request.maximumEntries) entradas atingido; análise parcial.")
                return nil
            }
            visitedPaths.insert(url.path)
            examined += 1
            if examined == 1 || examined % 128 == 0 { progress(examined) }
        }
        do {
            let snapshot = try SafeFilesystem.inspect(url)
            knownMissingPaths.remove(url.path)
            return snapshot
        }
        catch is CancellationError { throw CancellationError() }
        catch let error as FilesystemFailure where error.isMissing {
            knownMissingPaths.insert(url.path)
            if !missingIsExpected { issue(error.localizedDescription) }
            return nil
        }
        catch { issue(error.localizedDescription); return nil }
    }

    mutating func enumerate(_ directory: FileSnapshot, body: (inout ScanState, URL) throws -> Void) throws -> Bool {
        guard visitedDirectories.insert(DirectoryVisit(identity: directory.identity, purpose: traversalPurpose)).inserted else {
            issue("Pasta já percorrida; cobertura duplicada evitada: \(directory.url.path).")
            return false
        }
        do {
            try SafeFilesystem.forEachChild(of: directory) { url in
                guard !entryLimitReached else { return false }
                try body(&self, url)
                return !entryLimitReached
            }
            return !entryLimitReached
        } catch is CancellationError { throw CancellationError() }
        catch { issue(error.localizedDescription); return false }
    }

    mutating func measurementChild(_ url: URL) throws -> FileSnapshot? { try examine(url) }

    mutating func add(_ snapshot: FileSnapshot, root: FileSnapshot, category: ScanCategory,
                      bytes: Int64, detail: String, identifier: BundleIdentifier? = nil, association: AppAssociation? = nil) {
        guard candidatePaths.insert(snapshot.url.path).inserted else { return }
        do {
            var authorization = try PathPolicy.authorization(for: snapshot, root: root)
            authorization.directoryEntryBudget = min(250_000, request.maximumEntries)
            if category == .applications, let proof = appInfoProofs[snapshot.url.path] { authorization.supportingFiles = [proof] }
            var item = ScanItem(url: snapshot.url, category: category, bytes: bytes, detail: detail,
                                bundleIdentifier: identifier, authorization: authorization)
            if let association { item = item.associating(association) }
            if !results.insert(item, limit: request.maximumResults) { resultLimitReached = true }
        } catch { issue(error.localizedDescription) }
    }

    mutating func scanChildren(_ root: FileSnapshot, category: ScanCategory) throws {
        _ = try enumerate(root) { state, url in
            guard let child = try state.examine(url) else { return }
            guard !child.isSymlink else {
                state.issue("Link simbólico excluído: \(url.path).")
                return
            }
            let measurement = try state.measure(child)
            guard measurement.complete else {
                state.issue("Candidato omitido porque o tamanho não pôde ser medido por completo: \(url.path).")
                return
            }
            let reason: String
            switch category {
            case .caches: reason = "Cache; o aplicativo pode recriá-lo."
            case .logs: reason = "Registro de diagnóstico; revise antes de mover."
            default: reason = "Artefatos de desenvolvimento; a próxima compilação pode recriá-los."
            }
            state.add(child, root: root, category: category, bytes: measurement.bytes, detail: reason)
        }
    }

    mutating func scanLargeFiles(_ directory: FileSnapshot, root: FileSnapshot) throws {
        _ = try enumerate(directory) { state, url in
            guard let child = try state.examine(url) else { return }
            if let reason = PathPolicy.largeFileExclusion(url, homeDirectory: state.homeDirectory) {
                state.issue("\(url.path): \(reason).")
                return
            }
            if let reason = PathPolicy.exclusion(child) {
                state.issue("\(url.path): \(reason).")
                return
            }
            if child.isSymlink {
                state.issue("Link simbólico excluído: \(url.path).")
            } else if child.isDirectory {
                do {
                    let values = try url.resourceValues(forKeys: [.isPackageKey])
                    if values.isPackage == true {
                        state.issue("Pacote excluído da busca de arquivos grandes: \(url.path).")
                    } else { try state.scanLargeFiles(child, root: root) }
                } catch is CancellationError { throw CancellationError() }
                catch { state.issue("Não foi possível identificar o pacote \(url.path): \(error.localizedDescription)") }
            } else if child.isRegularFile, child.bytes >= state.request.minimumLargeFileBytes {
                state.add(child, root: root, category: .largeFiles, bytes: child.bytes,
                          detail: "Arquivo local com pelo menos \(state.request.minimumLargeFileBytes) bytes; revise seu conteúdo.")
            }
        }
    }

    mutating func scanApplications(_ root: FileSnapshot) throws {
        let inventoryComplete = try enumerate(root) { state, url in
            guard let child = try state.examine(url) else {
                if url.pathExtension.lowercased() == "app" { state.applicationInventoryComplete = false }
                return
            }
            guard url.pathExtension.lowercased() == "app" else { return }
            guard child.isDirectory, !child.isSymlink, PathPolicy.exclusion(child) == nil else {
                state.issue("Aplicativo não é uma pasta local disponível: \(url.path).")
                state.applicationInventoryComplete = false
                return
            }
            let identifier = try state.bundleIdentifier(child)
            if identifier?.comparisonKey == nil { state.applicationInventoryComplete = false }
            // Track all discovered identifiers, even protected apps, to avoid ambiguous relationships.
            state.applications.append(AppRecord(snapshot: child, identifier: identifier))
            guard !PathPolicy.isProtectedApp(child.url, bundleIdentifier: identifier) else {
                state.issue("Aplicativo Apple ou o próprio Zé Coleta protegido: \(url.path).")
                return
            }
            let measurement = try state.measure(child)
            guard measurement.complete else {
                state.issue("Aplicativo omitido porque o tamanho não pôde ser medido por completo: \(url.path).")
                return
            }
            state.add(child, root: root, category: .applications, bytes: measurement.bytes,
                      detail: "Pacote de aplicativo; arquivos relacionados exigem seleção separada.", identifier: identifier)
        }
        applicationInventoryComplete = applicationInventoryComplete && inventoryComplete
    }

    mutating func bundleIdentifier(_ app: FileSnapshot) throws -> BundleIdentifier? {
        let url = app.url.appendingPathComponent("Contents/Info.plist")
        do {
            guard let info = try examine(url) else { return nil }
            appInfoProofs[app.url.path] = info.proof
            guard info.ancestors.starts(with: app.ancestors + [AncestryIdentity(url: app.url, identity: app.identity)]) else {
                throw FilesystemFailure.rejected("O aplicativo mudou durante a leitura: \(app.url.path)")
            }
            let data = try SafeFilesystem.readSmallFile(info)
            guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let identifier = plist["CFBundleIdentifier"] as? String else {
                issue("Bundle ID ausente ou inválido: \(url.path).")
                return nil
            }
            let parsed = BundleIdentifier(rawValue: identifier)
            if parsed.comparisonKey == nil {
                issue("Bundle ID com alfabeto inválido; valor de origem preservado: \(identifier) em \(app.url.path).")
            }
            return parsed
        } catch is CancellationError { throw CancellationError() }
        catch { issue("Bundle ID desconhecido em \(app.url.path): \(error.localizedDescription)"); return nil }
    }

    mutating func scanRelatedFiles() throws {
        guard applicationInventoryComplete else {
            issue("Arquivos relacionados omitidos: o inventário de bundle IDs está incompleto; não é possível confirmar a exclusividade.")
            return
        }
        let counts = Dictionary(grouping: applications.compactMap { app in
            app.identifier?.comparisonKey.map { ($0, app) }
        }, by: { $0.0 })
        for app in applications {
            try Task.checkCancellation()
            guard !entryLimitReached else { break }
            guard let identifier = app.identifier, let key = identifier.comparisonKey,
                  !PathPolicy.isProtectedApp(app.snapshot.url, bundleIdentifier: identifier) else { continue }
            guard counts[key]?.count == 1 else {
                issue("Arquivos relacionados omitidos: mais de um aplicativo instalado usa \(identifier.rawValue) (comparação conservadora sem distinguir maiúsculas e minúsculas).")
                continue
            }
            guard let infoProof = appInfoProofs[app.snapshot.url.path] else {
                issue("Arquivos relacionados omitidos: prova do bundle ID indisponível em \(app.snapshot.url.path).")
                continue
            }
            let association = AppAssociation(ownerAppURL: app.snapshot.url, bundleIdentifier: identifier, infoProof: infoProof)
            let candidates = [
                ("Library/Caches", identifier.rawValue), ("Library/Logs", identifier.rawValue),
                ("Library/Preferences", identifier.rawValue + ".plist")
            ]
            for (relativeRoot, name) in candidates {
                guard !entryLimitReached else { break }
                let rootURL = homeDirectory.appendingPathComponent(relativeRoot)
                let candidateURL = rootURL.appendingPathComponent(name)
                // One physical candidate keeps its original category and authorization. Enrich
                // the retained record instead of re-enumerating or minting a second identity.
                if candidatePaths.contains(candidateURL.path) {
                    results.associate(candidateURL, with: association)
                    continue
                }
                // Absence is a known fact. Permission and identity failures remain visible.
                guard let root = try examine(rootURL, missingIsExpected: true), root.isDirectory,
                      let candidate = try examine(candidateURL, missingIsExpected: true) else { continue }
                guard !candidate.isSymlink else {
                    issue("Arquivo relacionado é um link simbólico e foi excluído: \(candidateURL.path).")
                    continue
                }
                let measurement = try measure(candidate)
                guard measurement.complete else {
                    issue("Arquivo relacionado omitido por cobertura incompleta: \(candidateURL.path).")
                    continue
                }
                add(candidate, root: root, category: .appRelated, bytes: measurement.bytes,
                    detail: "Arquivo relacionado ao aplicativo.", association: association)
            }
        }
    }
}

// The worst retained result is the heap root, so memory stays bounded while scanning.
private struct ResultHeap {
    var items: [ScanItem] = []

    mutating func associate(_ url: URL, with association: AppAssociation) {
        guard let index = items.firstIndex(where: { $0.url.path == url.path }) else { return }
        // Association does not change either ranking key (size and source path).
        items[index] = items[index].associating(association)
    }

    static func better(_ lhs: ScanItem, _ rhs: ScanItem) -> Bool {
        lhs.bytes == rhs.bytes ? lhs.url.path < rhs.url.path : lhs.bytes > rhs.bytes
    }

    mutating func insert(_ item: ScanItem, limit: Int) -> Bool {
        guard limit > 0 else { return false }
        if items.count >= limit {
            if Self.better(item, items[0]) {
                items[0] = item
                sink()
            }
            return false
        }
        items.append(item)
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard Self.better(items[parent], items[child]) else { break }
            items.swapAt(parent, child)
            child = parent
        }
        return true
    }

    mutating func sink() {
        var parent = 0
        while parent * 2 + 1 < items.count {
            var child = parent * 2 + 1
            if child + 1 < items.count, Self.better(items[child], items[child + 1]) { child += 1 }
            guard Self.better(items[parent], items[child]) else { break }
            items.swapAt(parent, child)
            parent = child
        }
    }

    func sorted() -> [ScanItem] { items.sorted(by: Self.better) }
}
