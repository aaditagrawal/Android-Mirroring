import Foundation
import Security

/// Stores the optional phone PIN in the macOS Keychain (used by "Unlock").
enum Keychain {
    private static let service = "com.aaditagrawal.AndroidMirroring.pin"

    static var pin: String? {
        get {
            let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
            return String(data: d, encoding: .utf8)
        }
        set {
            let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
            SecItemDelete(base as CFDictionary)
            guard let v = newValue, !v.isEmpty else { return }
            var add = base
            add[kSecValueData] = Data(v.utf8)
            add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
