import AppKit
import ColetaCore
import Foundation
import SwiftUI

enum Destination: String, CaseIterable, Identifiable {
    case overview, cleanup, large, applications

    var id: Self { self }
    var title: String {
        switch self {
        case .overview: "Visão geral"
        case .cleanup: "Limpeza"
        case .large: "Arquivos grandes"
        case .applications: "Aplicativos"
        }
    }
    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .cleanup: "sparkles"
        case .large: "doc.zipper"
        case .applications: "app.badge"
        }
    }
    var categories: Set<ScanCategory> {
        switch self {
        case .overview: Set(ScanCategory.allCases)
        case .cleanup: [.caches, .logs, .developer]
        case .large: [.largeFiles]
        case .applications: [.applications, .appRelated]
        }
    }
}

struct DiskSpace {
    let total: Int64
    let available: Int64

    static func read() -> DiskSpace? {
        guard let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(
            forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        ), let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }
        return DiskSpace(total: Int64(total), available: available)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var destination = Destination.overview
    @Published private(set) var report: ScanReport?
    @Published private(set) var analyzedCategories = Set<ScanCategory>()
    @Published private(set) var reportDate: Date?
    @Published private(set) var isScanning = false
    @Published private(set) var isMoving = false
    @Published private(set) var examinedEntries = 0
    @Published private(set) var status = "Pronto para analisar."
    @Published private(set) var disk = DiskSpace.read()
    @Published var selectedIDs = Set<String>()
    @Published var largeRoots: [URL] = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)]
    @Published var minimumSize: Int64 = 100_000_000 {
        didSet { if minimumSize != oldValue { invalidateReport() } }
    }
    @Published var isReviewPresented = false
    @Published var message: String?
    @Published private(set) var outcomes: [TrashOutcome] = []
    private var worker: Task<ScanReport, Error>?
    private var completion: Task<Void, Never>?
    private var scanID = UUID()

    var isBusy: Bool { isScanning || isMoving }
    var allItems: [ScanItem] { report?.items ?? [] }
    var visibleItems: [ScanItem] {
        allItems.filter { destination.categories.contains($0.category) && $0.category != .appRelated }
    }
    var selectedItems: [ScanItem] { allItems.filter { selectedIDs.contains($0.id) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }
    var orphanRelatedItems: [ScanItem] {
        let listedApps = Set(allItems.filter { $0.category == .applications }.map { $0.url.standardizedFileURL })
        return allItems.filter { item in
            guard let owner = item.ownerAppURL?.standardizedFileURL else { return false }
            return !listedApps.contains(owner)
        }
    }

    func hasReport(for destination: Destination) -> Bool {
        guard report != nil else { return false }
        let required = destination.categories.subtracting([.appRelated])
        return required.isSubset(of: analyzedCategories)
    }

    private func invalidateReport() {
        selectedIDs.removeAll()
        analyzedCategories.removeAll()
        report = nil
        reportDate = nil
        outcomes = []
        status = "Opções alteradas. Inicie uma nova análise."
    }

    func items(for destination: Destination) -> [ScanItem] {
        allItems.filter { destination.categories.contains($0.category) && $0.category != .appRelated }
    }

    func related(to item: ScanItem) -> [ScanItem] {
        allItems.filter { $0.ownerAppURL?.standardizedFileURL == item.url.standardizedFileURL }
    }

    func selection(_ item: ScanItem) -> Binding<Bool> {
        Binding(get: { self.selectedIDs.contains(item.id) }, set: { value in
            if value { self.selectedIDs.insert(item.id) }
            else { self.selectedIDs.remove(item.id) }
        })
    }

    func chooseFolders() {
        let panel = NSOpenPanel()
        panel.title = "Pastas para encontrar arquivos grandes"
        panel.message = "Selecione apenas as pastas que você deseja analisar."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = false
        panel.prompt = "Escolher pastas"
        if panel.runModal() == .OK {
            largeRoots = panel.urls
            // A previous report binds different roots; never reuse its selection.
            invalidateReport()
        }
    }

    func startScan() {
        guard !isBusy else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots: [ScanRoot] = []
        if destination == .overview || destination == .cleanup {
            roots += [
                ScanRoot(url: home.appendingPathComponent("Library/Caches"), category: .caches),
                ScanRoot(url: home.appendingPathComponent("Library/Logs"), category: .logs),
                ScanRoot(url: home.appendingPathComponent("Library/Developer/Xcode/DerivedData"), category: .developer),
            ]
        }
        if destination == .overview || destination == .large {
            roots += largeRoots.map { ScanRoot(url: $0, category: .largeFiles) }
        }
        if destination == .overview || destination == .applications {
            roots += [
                ScanRoot(url: URL(fileURLWithPath: "/Applications", isDirectory: true), category: .applications),
                ScanRoot(url: home.appendingPathComponent("Applications", isDirectory: true), category: .applications),
            ]
        }
        let request = ScanRequest(roots: roots, minimumLargeFileBytes: minimumSize)
        let categories = Set(roots.map(\.category))
        let id = UUID()
        scanID = id
        isScanning = true
        examinedEntries = 0
        selectedIDs.removeAll()
        outcomes = []
        status = "Analisando os locais escolhidos…"
        let model = self
        let task = Task.detached(priority: .userInitiated) {
            try FileScanner().scan(request, progress: { count in
                Task { @MainActor in
                    guard model.scanID == id, model.isScanning else { return }
                    model.examinedEntries = count
                }
            })
        }
        worker = task
        completion = Task { [weak self] in
            do {
                let result = try await task.value
                guard let self, self.scanID == id else { return }
                self.report = result
                self.reportDate = Date()
                self.analyzedCategories = categories
                self.examinedEntries = result.examinedEntries
                self.status = result.isComplete ? "Análise concluída. Revise os resultados." : "Análise parcial. Consulte os detalhes de cobertura."
                self.isScanning = false
                self.worker = nil
            } catch {
                guard let self, self.scanID == id else { return }
                self.status = error is CancellationError
                    ? "Análise cancelada. Nenhum arquivo foi alterado. Resultados anteriores, se houver, continuam visíveis."
                    : "Falha na análise: \(error.localizedDescription)"
                self.isScanning = false
                self.worker = nil
            }
        }
    }

    func cancelScan() {
        worker?.cancel()
        status = "Cancelando análise…"
    }

    func reviewSelection() {
        guard !isBusy, !selectedItems.isEmpty else { return }
        isReviewPresented = true
    }

    func reveal(_ item: ScanItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func moveSelectionToTrash() {
        let items = selectedItems
        guard !isBusy, !items.isEmpty else { return }
        let runningURLs = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL })
        if let running = items.first(where: { item in
            let appURL = item.category == .applications ? item.url : item.ownerAppURL
            return appURL.map { runningURLs.contains($0.standardizedFileURL) } ?? false
        }) {
            message = "Feche o aplicativo relacionado a “\(running.name)” e tente novamente."
            return
        }
        isReviewPresented = false
        isMoving = true
        status = "Movendo os itens aprovados para a Lixeira…"
        completion = Task { [weak self] in
            let results = await Task.detached(priority: .userInitiated) {
                TrashService().moveToTrash(items)
            }.value
            guard let self else { return }
            self.outcomes = results
            let succeeded = results.filter { $0.error == nil }
            self.selectedIDs.subtract(succeeded.map { $0.item.id })
            // Keep the immutable report as evidence; hide successful items from
            // selection until a fresh scan establishes the current filesystem.
            self.selectedIDs.removeAll()
            self.report = nil
            self.reportDate = nil
            self.analyzedCategories.removeAll()
            self.disk = DiskSpace.read()
            self.isMoving = false
            self.status = "\(succeeded.count) de \(results.count) item(ns) movido(s) para a Lixeira. Faça uma nova análise para atualizar os resultados."
        }
    }
}

func byteLabel(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

extension ScanCategory {
    var title: String {
        switch self {
        case .caches: "Cache de aplicativos"
        case .logs: "Registros de diagnóstico"
        case .developer: "Builds gerados pelo Xcode"
        case .largeFiles: "Arquivo grande"
        case .applications: "Aplicativo"
        case .appRelated: "Arquivo relacionado por bundle ID"
        }
    }
}
