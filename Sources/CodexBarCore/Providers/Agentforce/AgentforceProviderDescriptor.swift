import Foundation

public enum AgentforceProviderDescriptor {
    public static let myDomainKey = "AGENTFORCE_MY_DOMAIN_URL"

    public static let descriptor: ProviderDescriptor = Self.spec.makeDescriptor(
        credentials: ProviderCredentialAdapter(
            requiresAPIKeyForAPISource: false,
            environmentProjections: [.enterpriseHost(Self.myDomainKey)],
            configValidator: { config in
                guard let raw = config.sanitizedEnterpriseHost, AgentforceMyDomain.host(raw) == nil else { return [] }
                return [CodexBarConfigIssue(
                    severity: .error,
                    provider: .agentforce,
                    field: "enterpriseHost",
                    code: "invalid_enterprise_host",
                    message: AgentforceMyDomain.invalidMessage)]
            },
            missingCredentialMessage: { environment in
                AgentforceMyDomain.host(environment[Self.myDomainKey]) == nil ? AgentforceMyDomain.invalidMessage : nil
            }),
        fetchPlan: ProviderFetchPlan(
            sourceModes: [.auto, .web],
            pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [Self.scriptStrategy()] })))

    public static let spec = PluginProviderSpec(
        id: .agentforce,
        displayName: "Agentforce",
        sessionLabel: "Flex Credits",
        weeklyLabel: "Data Services Credits",
        toggleTitle: "Show Agentforce consumption",
        dashboardURL: nil,
        color: .init(hex: 0x0176D3),
        confetti: [0x0176D3, 0x032D60],
        noDataMessage: "Agentforce reports Digital Wallet consumption, not local token cost history.",
        // Cards are detail rows with no capacity, so there is no window to chart, burn down, or pick for the bar.
        history: .unavailable,
        burnDownWidgetSelectable: false,
        config: ProviderConfigCapabilities(supportsEnterpriseHost: true),
        menuBarMetrics: .automaticOnly,
        webSource: .init(
            settingsSection: .init(AgentforceProviderSettingsKey.self, cookieSettings: CookieProviderSettings.self),
            browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
            browserSupportExemption: { _, _, settings in settings?.agentforce?.cookieSource == .manual },
            field: .init(
                id: "agentforce-cookie-header",
                title: "Cookie header",
                subtitle: "Paste the Cookie header from a request to your My Domain host. It must contain sid.",
                placeholder: "Cookie: sid=…"),
            picker: .init(
                id: "agentforce-cookie-source",
                allowsOff: true,
                auto: .localized("Automatic imports browser cookies."),
                manual: .localized("Paste a Cookie header captured from %@.", argument: "My Domain"),
                off: .localized("%@ cookies are disabled.", argument: "Agentforce")),
            detailLine: "Browser session"))

    static func scriptStrategy(
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) -> ScriptFetchStrategy
    {
        ScriptFetchStrategy(
            id: "agentforce.web",
            provider: .agentforce,
            bundledPlugin: "agentforce",
            sourceLabel: "web",
            kind: .web,
            transport: transport,
            // Three sequential reads, the last a Data 360 query that can take tens of seconds.
            timeout: 60,
            validateContext: { context in
                guard AgentforceMyDomain.host(context.env[Self.myDomainKey]) != nil else {
                    throw ProviderFetchClassifiedError(
                        kind: .missingCredential, message: AgentforceMyDomain.invalidMessage)
                }
            },
            cookieImport: { context, _, batch in
                // The plugin's one logical cookie domain maps to the validated My Domain host. Only the configured
                // production host is queried.
                guard let host = AgentforceMyDomain.host(context.env[Self.myDomainKey]) else { return nil }
                return try Self.boundSessions(
                    ProviderPluginCookieBroker.importCookieHeaders(
                        provider: .agentforce, domain: host, browserDetection: context.browserDetection, batch: batch),
                    host: host)
            },
            resolveValues: { context in
                guard context.settings?.agentforce?.cookieSource != .off else { return nil }
                let host = AgentforceMyDomain.host(context.env[Self.myDomainKey])
                return .init(settings: [Self.myDomainKey: host.map { "https://\($0)" } ?? ""])
            },
            isEnabled: { _ in true })
    }

    /// Only the sid cookie leaves the importer. The source suffix binds each session to `host`; the plugin refuses
    /// a session bound to any other host, so a session cached before a host change is never sent.
    static func boundSessions(
        _ candidates: [(header: String, source: String)]?,
        host: String) -> [(header: String, source: String)]?
    {
        candidates?.compactMap { candidate in
            CookieHeaderNormalizer.filteredHeader(from: candidate.header, allowedNames: ["sid"])
                .map { ($0, "\(candidate.source) / \(host)") }
        }
    }
}

/// Production My Domain hosts only: `https://<name>.my.salesforce.com`, no path, query, user info, or port.
public enum AgentforceMyDomain {
    static let invalidMessage =
        "Set your production Salesforce My Domain URL, like https://acme.my.salesforce.com, in Settings."
    private static let validator = ProviderEndpointOverrideValidator(allowedDomainSuffixes: ["my.salesforce.com"])
    private static let rejectedSuffixes = [
        "sandbox.my.salesforce.com", "develop.my.salesforce.com", "scratch.my.salesforce.com",
        "lightning.force.com", "force.com", "salesforce-setup.com",
    ]

    public static func host(_ raw: String?) -> String? {
        guard let raw = SettingsValue.cleaned(raw),
              raw.lowercased().hasPrefix("https://"),
              let url = validator.validatedURL(raw, policy: .providerOwnedOnly),
              url.port == nil, url.query == nil, url.fragment == nil, url.user == nil, url.password == nil,
              url.path.isEmpty || url.path == "/",
              let host = url.host?.lowercased(),
              host.split(separator: ".", omittingEmptySubsequences: false).count == 4,
              !Self.rejectedSuffixes.contains(where: { host == $0 || host.hasSuffix(".\($0)") })
        else { return nil }
        return host
    }
}

public enum AgentforceProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.agentforce
    public typealias Section = CookieProviderSettings
}

extension ProviderSettingsSnapshot {
    public var agentforce: CookieProviderSettings? {
        self[AgentforceProviderSettingsKey.self]
    }
}
