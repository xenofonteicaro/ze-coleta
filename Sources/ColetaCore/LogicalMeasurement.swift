import Foundation

struct Measurement {
    var bytes: Int64 = 0
    var complete = true
}

// Scanning and final mutation validation share the same logical-size and exclusion rules.
// Each caller owns its coverage budget and failure reporting at the enumeration boundary.
protocol LogicalMeasurementContext {
    mutating func measurementChild(_ url: URL) throws -> FileSnapshot?
    mutating func enumerate(_ directory: FileSnapshot, body: (inout Self, URL) throws -> Void) throws -> Bool
    mutating func issue(_ message: String)
}

extension LogicalMeasurementContext {
    mutating func measure(_ snapshot: FileSnapshot) throws -> Measurement {
        try Task.checkCancellation()
        if let reason = PathPolicy.exclusion(snapshot) {
            issue("\(snapshot.url.path): \(reason); tamanho agregado indisponível.")
            return Measurement(complete: false)
        }
        // A link's own bytes are known from lstat; its destination is never traversed.
        if snapshot.isRegularFile || snapshot.isSymlink { return Measurement(bytes: snapshot.bytes) }
        guard snapshot.isDirectory else {
            issue("Tipo de arquivo especial ignorado: \(snapshot.url.path).")
            return Measurement(complete: false)
        }
        var measurement = Measurement()
        let directoryComplete = try enumerate(snapshot) { context, url in
            guard let child = try context.measurementChild(url) else { measurement.complete = false; return }
            let childMeasurement = try context.measure(child)
            measurement.complete = measurement.complete && childMeasurement.complete
            let sum = measurement.bytes.addingReportingOverflow(childMeasurement.bytes)
            if sum.overflow {
                context.issue("Tamanho excede o intervalo representável: \(snapshot.url.path).")
                measurement.complete = false
            } else { measurement.bytes = sum.partialValue }
        }
        measurement.complete = measurement.complete && directoryComplete
        return measurement
    }
}

struct DirectoryVerification: LogicalMeasurementContext {
    let maximumEntries: Int
    var examined = 1
    var failure: String?
    var visited = Set<FileIdentity>()

    mutating func issue(_ message: String) { if failure == nil { failure = message } }

    mutating func measurementChild(_ url: URL) throws -> FileSnapshot? {
        try Task.checkCancellation()
        guard examined < maximumEntries else {
            issue("Limite de \(maximumEntries) entradas atingido ao revalidar a pasta; analise novamente.")
            return nil
        }
        examined += 1
        do { return try SafeFilesystem.inspect(url) }
        catch { issue(error.localizedDescription); return nil }
    }

    mutating func enumerate(_ directory: FileSnapshot, body: (inout DirectoryVerification, URL) throws -> Void) throws -> Bool {
        guard maximumEntries > 0 else {
            issue("Orçamento de revalidação esgotado; analise novamente.")
            return false
        }
        guard visited.insert(directory.identity).inserted else {
            issue("Identidade de pasta repetida durante a revalidação: \(directory.url.path).")
            return false
        }
        do {
            try SafeFilesystem.forEachChild(of: directory) { url in
                guard failure == nil else { return false }
                try body(&self, url)
                return failure == nil
            }
            return failure == nil
        } catch is CancellationError { throw CancellationError() }
        catch { issue(error.localizedDescription); return false }
    }
}
