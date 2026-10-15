import Darwin
import Foundation

enum FilesystemFailure: Error, LocalizedError {
    case rejected(String)
    case operation(String, Int32)

    var errorDescription: String? {
        switch self {
        case .rejected(let reason): reason
        case .operation(let path, let code): "\(path): \(String(cString: strerror(code)))"
        }
    }

    var isMissing: Bool {
        if case .operation(_, let code) = self { return code == ENOENT }
        return false
    }
}

struct FileSnapshot {
    let url: URL
    let identity: FileIdentity
    let fingerprint: FileFingerprint
    let ancestors: [AncestryIdentity]
    let bytes: Int64
    let flags: UInt32

    var isDirectory: Bool { identity.kind == UInt16(S_IFDIR) }
    var isRegularFile: Bool { identity.kind == UInt16(S_IFREG) }
    var isSymlink: Bool { identity.kind == UInt16(S_IFLNK) }
    var isDataless: Bool { flags & UInt32(SF_DATALESS) != 0 }
    var proof: FileProof { FileProof(url: url, identity: identity, fingerprint: fingerprint, ancestors: ancestors) }
}

enum SafeFilesystem {
    static func normalized(_ url: URL) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/"), url.host == nil || url.host == "" || url.host == "localhost" else {
            throw FilesystemFailure.rejected("É necessário um caminho local absoluto: \(url.absoluteString)")
        }
        return URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: false)
    }

    static func identity(_ value: stat) -> FileIdentity {
        FileIdentity(device: UInt64(bitPattern: Int64(value.st_dev)), inode: UInt64(value.st_ino),
                     kind: UInt16(value.st_mode & mode_t(S_IFMT)))
    }

    // Walk with descriptor-relative lookups. Intermediate links cannot redirect the walk.
    private static func withParent<T>(_ url: URL, _ body: (Int32, String, [AncestryIdentity]) throws -> T) throws -> T {
        let components = url.pathComponents.filter { $0 != "/" }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw FilesystemFailure.operation("/", errno) }
        defer { close(descriptor) }
        var rootStat = stat()
        guard fstat(descriptor, &rootStat) == 0 else { throw FilesystemFailure.operation("/", errno) }
        var ancestry = [AncestryIdentity(url: URL(fileURLWithPath: "/"), identity: identity(rootStat))]
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in components.dropLast() {
            current.appendPathComponent(component, isDirectory: true)
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard next >= 0 else { throw FilesystemFailure.operation(current.path, errno) }
            var value = stat()
            guard fstat(next, &value) == 0 else {
                let code = errno
                close(next)
                throw FilesystemFailure.operation(current.path, code)
            }
            close(descriptor)
            descriptor = next
            ancestry.append(AncestryIdentity(url: URL(fileURLWithPath: current.path, isDirectory: false), identity: identity(value)))
        }
        return try body(descriptor, components.last ?? ".", components.isEmpty ? [] : ancestry)
    }

    static func inspect(_ originalURL: URL) throws -> FileSnapshot {
        let url = try normalized(originalURL)
        return try withParent(url) { descriptor, leaf, ancestors in
            var value = stat()
            guard fstatat(descriptor, leaf, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw FilesystemFailure.operation(url.path, errno)
            }
            return FileSnapshot(url: url, identity: identity(value),
                                fingerprint: FileFingerprint(bytes: Int64(value.st_size),
                                    modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
                                    changedSeconds: Int64(value.st_ctimespec.tv_sec), changedNanoseconds: Int64(value.st_ctimespec.tv_nsec)), ancestors: ancestors,
                                bytes: max(0, Int64(value.st_size)), flags: value.st_flags)
        }
    }

    private static func openVerified(_ snapshot: FileSnapshot, directory: Bool) throws -> Int32 {
        try withParent(snapshot.url) { descriptor, leaf, ancestors in
            guard ancestors == snapshot.ancestors else {
                throw FilesystemFailure.rejected("Os ancestrais mudaram: \(snapshot.url.path)")
            }
            let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (directory ? O_DIRECTORY : 0)
            let result = openat(descriptor, leaf, flags)
            guard result >= 0 else { throw FilesystemFailure.operation(snapshot.url.path, errno) }
            var value = stat()
            guard fstat(result, &value) == 0 else {
                let code = errno
                close(result)
                throw FilesystemFailure.operation(snapshot.url.path, code)
            }
            guard identity(value) == snapshot.identity else {
                close(result)
                throw FilesystemFailure.rejected("A identidade mudou: \(snapshot.url.path)")
            }
            return result
        }
    }

    static func forEachChild(of snapshot: FileSnapshot, _ body: (URL) throws -> Bool) throws {
        guard snapshot.isDirectory else { throw FilesystemFailure.rejected("Não é uma pasta: \(snapshot.url.path)") }
        let descriptor = try openVerified(snapshot, directory: true)
        guard let stream = fdopendir(descriptor) else {
            let code = errno
            close(descriptor)
            throw FilesystemFailure.operation(snapshot.url.path, code)
        }
        defer { closedir(stream) }
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw FilesystemFailure.operation(snapshot.url.path, errno) }
                break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            if try !body(snapshot.url.appendingPathComponent(name)) { break }
        }
    }

    static func readSmallFile(_ snapshot: FileSnapshot, maximumBytes: Int = 1_048_576) throws -> Data {
        guard snapshot.isRegularFile, !snapshot.isDataless, snapshot.bytes <= maximumBytes else {
            throw FilesystemFailure.rejected("Arquivo de metadados indisponível ou acima de \(maximumBytes) bytes: \(snapshot.url.path)")
        }
        let descriptor = try openVerified(snapshot, directory: false)
        defer { close(descriptor) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count <= maximumBytes {
            try Task.checkCancellation()
            let count = read(descriptor, &buffer, min(buffer.count, maximumBytes + 1 - data.count))
            if count < 0 {
                if errno == EINTR { continue }
                throw FilesystemFailure.operation(snapshot.url.path, errno)
            }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
        throw FilesystemFailure.rejected("Metadados cresceram além do limite: \(snapshot.url.path)")
    }
}

enum PathPolicy {
    static let ownBundleIdentifier = "io.github.xenofonteicaro.ze-coleta"

    static func isWithin(_ url: URL, root: URL, allowRoot: Bool = false) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        return components.starts(with: rootComponents) && (allowRoot || components.count > rootComponents.count)
    }

    static func exclusion(_ url: URL) -> String? {
        let path = url.standardizedFileURL.path.lowercased()
        if path == "/" || path == "/users" { return "pasta essencial protegida" }
        let protectedRoots = ["/System", "/Library", "/usr", "/bin", "/sbin", "/etc", "/var", "/private", "/dev", "/cores"]
        if protectedRoots.contains(where: { path == $0.lowercased() || path.hasPrefix($0.lowercased() + "/") }) {
            return "caminho de sistema protegido"
        }
        let components = url.pathComponents.map { $0.lowercased() }
        if components.contains("cloudstorage") || components.contains("mobile documents") ||
            components.contains(where: { $0.hasSuffix(".ubiquitous") || $0.hasSuffix(".icloud") }) {
            return "local de nuvem ou placeholder excluído"
        }
        if components.contains(where: { $0.hasSuffix(".photoslibrary") || $0.hasSuffix(".photolibrary") || $0.hasSuffix(".aplibrary") }) {
            return "biblioteca de fotos protegida"
        }
        return nil
    }

    static func largeFileExclusion(_ url: URL, homeDirectory: URL) -> String? {
        let library = homeDirectory.appendingPathComponent("Library")
        if isWithin(url, root: library, allowRoot: true) {
            return "Library é excluída da busca de arquivos grandes; use as categorias de limpeza disponíveis"
        }
        return nil
    }

    static func exclusion(_ snapshot: FileSnapshot) -> String? {
        exclusion(snapshot.url) ?? (snapshot.isDataless ? "placeholder sem conteúdo local" : nil)
    }

    static func isProtectedApp(_ url: URL, bundleIdentifier: String?) -> Bool {
        bundleIdentifier == ownBundleIdentifier || bundleIdentifier?.hasPrefix("com.apple.") == true ||
            url.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    static func authorization(for snapshot: FileSnapshot, root: FileSnapshot) throws -> ItemAuthorization {
        let expected = root.ancestors + [AncestryIdentity(url: root.url, identity: root.identity)]
        guard isWithin(snapshot.url, root: root.url), snapshot.ancestors.starts(with: expected) else {
            throw FilesystemFailure.rejected("O item não pertence mais à raiz analisada: \(snapshot.url.path)")
        }
        return ItemAuthorization(root: root.url, leaf: snapshot.identity, fingerprint: snapshot.fingerprint, ancestors: snapshot.ancestors)
    }
}
