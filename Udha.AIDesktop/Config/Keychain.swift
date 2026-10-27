import Foundation
#if canImport(Security)
import Security
#endif

enum KeychainKey: String {
    case elevenLabsAPIKey = "elevenlabs_api_key"
    case elevenLabsAgentID = "elevenlabs_agent_id"
    case mobileBridgeAccessToken = "mobile_bridge_access_token"
    case mobileBridgeRefreshToken = "mobile_bridge_refresh_token"
    case mobileBridgeExpiresAt = "mobile_bridge_expires_at"
    case mobileBridgeInstanceID = "mobile_bridge_instance_id"
    case anthropicAPIKey = "anthropic_api_key"
}

#if canImport(Security)
/// Which of the two macOS keychains `KeychainStore` talks to.
///
/// The legacy file-based keychain (`login.keychain-db`) authorises reads with a
/// **per-item ACL**, so a binary that isn't on an item's list triggers a password
/// dialog — once per item, every launch, which is why eight stored credentials
/// meant eight prompts. The data-protection keychain has no ACLs: access comes
/// from the access group in the caller's code signature, so it never prompts.
///
/// Using it requires the app to be signed with `keychain-access-groups` (see
/// Udha.AIDesktop.entitlements) and therefore a provisioning profile. We probe
/// once instead of assuming: an unprovisioned build would otherwise come up with
/// every credential blank, and prompting is far better than silently forgetting
/// the ElevenLabs key.
enum KeychainBackend {
    private static let probeService = (Bundle.main.bundleIdentifier ?? "udha") + ".dp-probe"

    static let supportsDataProtection: Bool = {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
            kSecAttrAccount as String: "probe",
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(identity as CFDictionary)

        var add = identity
        add[kSecValueData as String] = Data("probe".utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        SecItemDelete(identity as CFDictionary)

        if status == errSecSuccess {
            Log.app.info("keychain: using the data-protection keychain")
            return true
        }
        Log.app.error(
            "keychain: data-protection keychain unavailable (OSStatus \(status)); "
            + "falling back to the legacy keychain, which prompts once per item. "
            + "Check the keychain-access-groups entitlement and code signing."
        )
        return false
    }()
}

struct KeychainStore: Sendable {
    let service: String

    // MARK: - Generic access

    /// `dataProtection` picks the keychain explicitly rather than relying on the
    /// platform default, so the migration path can address the legacy one by name.
    private func query(account: String, dataProtection: Bool) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: dataProtection,
        ]
    }

    private func write(_ value: String, account: String, dataProtection: Bool) throws {
        let data = Data(value.utf8)
        let base = query(account: account, dataProtection: dataProtection)

        var attrs: [String: Any] = [kSecValueData as String: data]
        if dataProtection {
            attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        }

        let status = SecItemUpdate(base as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            if dataProtection {
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
            }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private func read(account: String, dataProtection: Bool) -> String? {
        var q = query(account: account, dataProtection: dataProtection)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func remove(account: String, dataProtection: Bool) {
        SecItemDelete(query(account: account, dataProtection: dataProtection) as CFDictionary)
    }

    // MARK: - Public API

    func set(_ value: String, account: String) throws {
        try write(value, account: account, dataProtection: KeychainBackend.supportsDataProtection)
    }

    func get(account: String) -> String? {
        read(account: account, dataProtection: KeychainBackend.supportsDataProtection)
    }

    func delete(account: String) {
        remove(account: account, dataProtection: KeychainBackend.supportsDataProtection)
    }

    func has(account: String) -> Bool {
        get(account: account) != nil
    }

    func set(_ value: String, for key: KeychainKey) throws {
        try set(value, account: key.rawValue)
    }

    func get(_ key: KeychainKey) -> String? {
        get(account: key.rawValue)
    }

    func delete(_ key: KeychainKey) {
        delete(account: key.rawValue)
    }

    func has(_ key: KeychainKey) -> Bool {
        has(account: key.rawValue)
    }

    // MARK: - Migration

    /// Moves every item under `service` out of the legacy keychain and into the
    /// data-protection one. Safe to call on every launch: once the legacy side is
    /// empty the lookup returns `errSecItemNotFound` without asking for anything.
    ///
    /// Accounts are enumerated attributes-only — the ACL allows that much silently —
    /// and each value is then fetched on its own, so the user sees one dialog per
    /// item exactly once and a denial costs only that item. A legacy copy is
    /// deleted only after its replacement reads back intact.
    @discardableResult
    func migrateLegacyItems() -> Int {
        guard KeychainBackend.supportsDataProtection else { return 0 }

        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: false,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return 0 }

        let accounts = items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
        guard !accounts.isEmpty else { return 0 }

        Log.app.info("keychain: \(accounts.count) legacy item(s) to migrate — expect one prompt each, once")

        var moved = 0
        for account in accounts {
            if read(account: account, dataProtection: true) != nil {
                remove(account: account, dataProtection: false)
                moved += 1
                continue
            }
            guard let value = read(account: account, dataProtection: false) else {
                Log.app.error("keychain: legacy '\(account)' unreadable (denied or locked) — left in place")
                continue
            }
            do {
                try write(value, account: account, dataProtection: true)
            } catch {
                Log.app.error("keychain: migrating '\(account)' failed (\(error.localizedDescription)) — legacy copy kept")
                continue
            }
            guard read(account: account, dataProtection: true) == value else {
                Log.app.error("keychain: '\(account)' did not read back — legacy copy kept")
                continue
            }
            remove(account: account, dataProtection: false)
            moved += 1
        }

        Log.app.info("keychain: migrated \(moved)/\(accounts.count) item(s) off the legacy keychain")
        return moved
    }
}
#endif
