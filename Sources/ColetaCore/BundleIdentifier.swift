import Foundation

// The raw source remains evidence. Ownership/protection comparisons use a conservative
// ASCII case-folded identity, even on case-sensitive volumes where names can differ.
struct BundleIdentifier: Hashable, Sendable {
    let rawValue: String
    let comparisonKey: String?

    init(rawValue: String) {
        self.rawValue = rawValue
        let safeAlphabet = !rawValue.isEmpty && rawValue.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46
        }
        comparisonKey = safeAlphabet && rawValue != "." && rawValue != ".." ? rawValue.lowercased() : nil
    }
}
