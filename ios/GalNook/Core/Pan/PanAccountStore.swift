import Foundation

public protocol PanCredentialStoring: Sendable {
    func string(for account: String) -> String?
    @discardableResult
    func setString(_ value: String?, for account: String) -> Bool
}

extension KeychainStore: PanCredentialStoring {}

/// Independent net-disk credential facade. Values never pass through JSONStore or UserDefaults.
public struct PanAccountStore: Sendable {
    public static let quark = "quark"
    public static let uc = "uc"
    public static let baidu = "baidu"
    public static let pan115 = "pan115"
    public static let pan123 = "pan123"
    public static let pan123Token = "pan123.token"
    public static let xunlei = "xunlei"
    public static let caiyun = "caiyun"
    public static let guangya = "guangya"
    public static let ilanzou = "ilanzou"

    public static let accountKeys = [
        quark, uc, baidu, pan115, pan123, pan123Token,
        xunlei, caiyun, guangya, ilanzou
    ]

    private let credentials: any PanCredentialStoring

    public init(keychain: KeychainStore = KeychainStore(service: "app.galnook.ios.pan-accounts")) {
        self.credentials = keychain
    }

    public init(credentials: any PanCredentialStoring) {
        self.credentials = credentials
    }

    public func value(for account: String) -> String? {
        guard Self.accountKeys.contains(account) else { return nil }
        return credentials.string(for: account)?.nilIfBlank
    }

    @discardableResult
    public func setValue(_ value: String?, for account: String) -> Bool {
        guard Self.accountKeys.contains(account) else { return false }
        return credentials.setString(value?.nilIfBlank, for: account)
    }

    public func cookie(for account: String) -> String? {
        guard account != Self.pan123Token, Self.accountKeys.contains(account) else { return nil }
        return value(for: account)
    }

    @discardableResult
    public func setCookie(_ value: String?, for account: String) -> Bool {
        guard account != Self.pan123Token else { return false }
        return setValue(value, for: account)
    }

    public var pan123AuthorToken: String? { value(for: Self.pan123Token) }

    @discardableResult
    public func setPan123AuthorToken(_ value: String?) -> Bool {
        setValue(value, for: Self.pan123Token)
    }

    /// Mirrors Android logout: remove both the site Cookie and an optional token.
    @discardableResult
    public func removeAccount(_ account: String) -> Bool {
        let cookieAccount = account.hasSuffix(".token") ? String(account.dropLast(6)) : account
        guard Self.accountKeys.contains(cookieAccount) else { return false }
        let removedCookie = credentials.setString(nil, for: cookieAccount)
        let tokenAccount = "\(cookieAccount).token"
        let removedToken = Self.accountKeys.contains(tokenAccount)
            ? credentials.setString(nil, for: tokenAccount)
            : true
        return removedCookie && removedToken
    }
}

