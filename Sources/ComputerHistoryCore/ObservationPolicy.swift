import Foundation

/// 观测策略：决定哪些应用/域名被采集、哪些被抑制。
///
/// 模型来自反编译 `ComputerUseIPCSkysightObservationSettings`：
///
///     ObservationSettings {
///         defaultApplicationBehavior : observe | do_not_observe
///         defaultURLBehavior         : observe | do_not_observe
///         allowlist : [ObservationRule]
///         blocklist : [ObservationRule]
///     }
///     ObservationRule { scope: app|url, bundleID: String?, urlDomain: String? }
///
/// 因此"黑名单制"与"白名单制"只是同一组参数的两个取值，不需要两套逻辑：
///   - 默认 `observe` + blocklist 命中 → 抑制；
///   - 默认 `do_not_observe` + allowlist 命中 → 采集。
public struct ObservationPolicy: Sendable {

    public enum DefaultBehavior: String, Sendable {
        case observe
        case doNotObserve = "do_not_observe"
    }

    /// 规则作用域。rawValue 与二进制一致（`app` / `url`）。
    public enum Scope: String, Sendable {
        case app
        case url
    }

    public struct Rule: Sendable, Hashable {
        public var scope: Scope
        public var bundleID: String?
        public var urlDomain: String?

        public init(scope: Scope, bundleID: String? = nil, urlDomain: String? = nil) {
            self.scope = scope
            self.bundleID = bundleID
            self.urlDomain = urlDomain
        }

        public static func application(_ bundleID: String) -> Rule {
            Rule(scope: .app, bundleID: bundleID)
        }

        public static func domain(_ domain: String) -> Rule {
            Rule(scope: .url, urlDomain: domain)
        }
    }

    public var defaultApplicationBehavior: DefaultBehavior
    public var defaultURLBehavior: DefaultBehavior
    public var allowlist: [Rule]
    public var blocklist: [Rule]

    /// 隐私浏览等强制抑制的域名后缀（`Incognito` / `Private Browsing` 之外的兜底层）。
    /// 官方另有 `ComputerUseURLBlocklist` 与隐私浏览检测，属策略之外的第二道防线。
    public var forcedBlockedDomains: [String]

    public init(
        defaultApplicationBehavior: DefaultBehavior = .observe,
        defaultURLBehavior: DefaultBehavior = .observe,
        allowlist: [Rule] = [],
        blocklist: [Rule] = [],
        forcedBlockedDomains: [String] = []
    ) {
        self.defaultApplicationBehavior = defaultApplicationBehavior
        self.defaultURLBehavior = defaultURLBehavior
        self.allowlist = allowlist
        self.blocklist = blocklist
        self.forcedBlockedDomains = forcedBlockedDomains
    }

    /// 保守默认策略：默认全采，但屏蔽公认的凭据类应用。
    ///
    /// 长期运行时"默认全采"是必要的——否则会漏掉大部分日常活动。但密码管理器
    /// 一类应用的内容一旦落盘即为明文凭据，代价不可逆，故默认排除。
    ///
    /// 这份清单**只覆盖已知的通用凭据工具**，不构成安全保证：使用者应按自己的
    /// 情况在 `config.json` 的 `policy.blocklist` 中增补。
    public static var conservative: ObservationPolicy {
        ObservationPolicy(blocklist: [
            .application("com.1password.1password"),
            .application("com.1password.1password7"),
            .application("com.agilebits.onepassword7"),
            .application("com.bitwarden.desktop"),
            .application("com.lastpass.LastPass"),
            .application("com.dashlane.dashlanephonefinal"),
            .application("in.sinew.Enpass-Desktop"),
            .application("org.keepassxc.keepassxc"),
            .application("com.apple.keychainaccess"),
            .application("com.apple.Passwords"),
        ])
    }

    /// 缺字段沿用默认策略，错误字段拒绝加载。
    public init(json: [String: Any]) throws {
        try ConfigValidation.keys(json, allowed: ["defaultApplicationBehavior", "defaultURLBehavior", "allowlist", "blocklist", "forcedBlockedDomains"], path: "policy")
        self = .conservative
        func behavior(_ key: String) throws -> DefaultBehavior? {
            guard let value = json[key] else { return nil }
            guard let raw = value as? String, let result = DefaultBehavior(rawValue: raw) else {
                throw CollectorConfig.ConfigError.invalidField("policy." + key, expected: "observe 或 do_not_observe")
            }
            return result
        }
        if let value = try behavior("defaultApplicationBehavior") { defaultApplicationBehavior = value }
        if let value = try behavior("defaultURLBehavior") { defaultURLBehavior = value }
        if let value = json["allowlist"] { allowlist = try Self.rules(from: value, path: "policy.allowlist") }
        if let value = json["blocklist"] { blocklist = try Self.rules(from: value, path: "policy.blocklist") }
        if let value = json["forcedBlockedDomains"] {
            guard let domains = value as? [String], domains.allSatisfy(Self.validDomain) else {
                throw CollectorConfig.ConfigError.invalidField("policy.forcedBlockedDomains", expected: "域名数组（不含协议或路径）")
            }
            forcedBlockedDomains = domains
        }
    }

    static func rules(from value: Any, path: String) throws -> [Rule] {
        guard let array = value as? [[String: Any]] else {
            throw CollectorConfig.ConfigError.invalidField(path, expected: "规则对象数组")
        }
        return try array.enumerated().map { index, item in
            let field = "\(path)[\(index)]"
            guard let raw = item["scope"] as? String, let scope = Scope(rawValue: raw) else {
                throw CollectorConfig.ConfigError.invalidField(field + ".scope", expected: "app 或 url")
            }
            let key = scope == .app ? "bundleID" : "urlDomain"
            try ConfigValidation.keys(item, allowed: ["scope", key], path: field)
            guard let text = item[key] as? String, !text.isEmpty,
                  text == text.trimmingCharacters(in: .whitespacesAndNewlines),
                  scope == .app || validDomain(text) else {
                throw CollectorConfig.ConfigError.invalidField(field + "." + key, expected: "非空应用标识或域名（不含协议或路径）")
            }
            return scope == .app ? .application(text) : .domain(text)
        }
    }

    private static func validDomain(_ text: String) -> Bool {
        !text.isEmpty && !text.contains(where: { $0.isWhitespace || "/:@?#*".contains($0) })
            && !text.split(separator: ".", omittingEmptySubsequences: false).contains("")
    }

    /// 序列化为配置字典。
    public var jsonObject: [String: Any] {
        func encode(_ rules: [Rule]) -> [[String: Any]] {
            rules.map { r in
                switch r.scope {
                case .app: return ["scope": "app", "bundleID": r.bundleID ?? ""]
                case .url: return ["scope": "url", "urlDomain": r.urlDomain ?? ""]
                }
            }
        }
        return [
            "defaultApplicationBehavior": defaultApplicationBehavior.rawValue,
            "defaultURLBehavior": defaultURLBehavior.rawValue,
            "allowlist": encode(allowlist),
            "blocklist": encode(blocklist),
            "forcedBlockedDomains": forcedBlockedDomains,
        ]
    }

    /// 判定一条事件是否应被抑制。
    ///
    /// 应用与域名**分别**按各自默认行为 + 名单判定，任一判为不采集即抑制。
    public func shouldSuppress(app: EventStreamApp?, window: EventStreamWindow?) -> Bool {
        if let bundleID = app?.bundleIdentifier,
           !decide(value: bundleID, scope: .app, ruleValue: { $0.bundleID },
                   defaultBehavior: defaultApplicationBehavior) {
            return true
        }
        if let host = window?.url.flatMap(Self.host(from:)),
           !decide(value: host, scope: .url, ruleValue: { $0.urlDomain },
                   defaultBehavior: defaultURLBehavior) {
            return true
        }
        if let host = window?.url.flatMap(Self.host(from:)),
           forcedBlockedDomains.contains(where: { Self.domain(host, matches: $0) }) {
            return true
        }
        return false
    }

    /// 判定某条规则是否命中给定值。
    ///
    /// 匹配方式随作用域而不同：bundleID 精确匹配；域名按后缀匹配以覆盖子域
    /// （规则 `example.com` 应命中 `mail.example.com`）。
    static func matches(scope: Scope, ruleValue: String, value: String) -> Bool {
        switch scope {
        case .app: return ruleValue == value
        case .url: return domain(value, matches: ruleValue)
        }
    }

    /// 单维度判定：黑名单优先于白名单，两者都未命中时取默认行为。
    private func decide(
        value: String,
        scope: Scope,
        ruleValue: (Rule) -> String?,
        defaultBehavior: DefaultBehavior
    ) -> Bool {
        let hit: (Rule) -> Bool = { rule in
            guard rule.scope == scope, let rv = ruleValue(rule) else { return false }
            return Self.matches(scope: scope, ruleValue: rv, value: value)
        }
        if blocklist.contains(where: hit) { return false }
        if allowlist.contains(where: hit) { return true }
        return defaultBehavior == .observe
    }

    static func domain(_ host: String, matches rule: String) -> Bool {
        let h = host.lowercased(), r = rule.lowercased()
        return h == r || h.hasSuffix("." + r)
    }

    /// 从 URL 取主机名。裸域名匹配子域由 `domain(_:matches:)` 负责。
    public static func host(from urlString: String) -> String? {
        guard let url = URL(string: urlString), let host = url.host() else { return nil }
        return host
    }
}
