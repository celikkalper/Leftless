import Foundation

/// Looks up a core display string in the core String Catalog; the English source text is the key.
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}
