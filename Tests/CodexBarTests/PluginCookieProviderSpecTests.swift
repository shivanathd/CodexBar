import Foundation
import SweetCookieKit
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct PluginCookieProviderSpecTests {
    @Test
    func `automatic cookie guidance names the provider browser policy and manual alternative`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: #function)
        fixture.settings.debugDisableKeychainAccess = false
        for provider in [UsageProvider.museai, .raycast, .perplexity, .parallel, .agentforce] {
            let implementation = try #require(ProviderCatalog.implementation(for: provider))
            let picker = try #require(implementation.settingsPickers(
                context: fixture.settingsContext(provider: provider)).first)
            let browsers = ProviderDefaults.metadata[provider]?.browserCookieOrder ?? Browser.defaultImportOrder
            let names = browsers.map(\.displayName).joined(separator: ", ")
            #expect(picker.subtitle.contains("Supported browsers: \(names). Use Manual for other browsers."))
            #expect(picker.dynamicSubtitle?()?.contains("Supported browsers: \(names).") == true)
            if provider == .museai {
                #expect(picker.subtitle.hasPrefix("Automatic imports browser cookies."))
                for name in ["Aside", "Opera", "Opera Neon"] {
                    #expect(browsers.map(\.displayName).contains(name))
                }
            }
        }
    }

    @Test
    func `Agentforce stores its My Domain URL as the endpoint and requires a production host`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: #function)
        let implementation = try #require(ProviderCatalog.implementation(for: .agentforce))
        let fields = implementation.settingsFields(context: fixture.settingsContext(provider: .agentforce))
        #expect(fields.map(\.id) == ["agentforce-my-domain-url", "agentforce-cookie-header"])
        #expect(fields.map(\.kind) == [.plain, .secure])
        fields[0].binding.wrappedValue = "https://acme.my.salesforce.com"
        #expect(fixture.settings.providerConfig(for: .agentforce)?.enterpriseHost == "https://acme.my.salesforce.com")
        let available = { (value: String) in
            implementation.isAvailable(context: .init(
                provider: .agentforce,
                settings: fixture.settings,
                environment: [AgentforceProviderDescriptor.myDomainKey: value]))
        }
        #expect(available("https://acme.my.salesforce.com"))
        #expect(!available("https://acme--uat.sandbox.my.salesforce.com"))
        #expect(!available(""))
    }

    @Test
    func `Agentforce clears its cached session when the My Domain host changes`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: #function)
        let implementation = try #require(ProviderCatalog.implementation(for: .agentforce))
        let field = try #require(implementation.settingsFields(
            context: fixture.settingsContext(provider: .agentforce)).first)
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storage) }
        try KeychainCacheStore.withServiceOverrideForTesting("agentforce-host-change-\(UUID().uuidString)") {
            try KeychainCacheStore.withImplicitTestStoreForTesting {
                try CookieHeaderCache.withLegacyBaseURLOverrideForTesting(storage) {
                    field.binding.wrappedValue = "https://acme.my.salesforce.com"
                    CookieHeaderCache.store(
                        provider: .agentforce,
                        cookieHeader: "sid=fixture-sid",
                        sourceLabel: "Chrome / acme.my.salesforce.com")
                    field.binding.wrappedValue = "https://ACME.my.salesforce.com/"
                    #expect(CookieHeaderCache.load(provider: .agentforce)?.cookieHeader == "sid=fixture-sid")
                    field.binding.wrappedValue = "https://other.my.salesforce.com"
                    #expect(CookieHeaderCache.load(provider: .agentforce) == nil)
                    #expect(fixture.settings.providerConfig(for: .agentforce)?.enterpriseHost
                        == "https://other.my.salesforce.com")
                }
            }
        }
    }

    private static let providers: [UsageProvider] = [
        .helmcode, .hyper, .manus, .perplexity, .qoder, .raycast, .sakana, .t3chat, .lithosai, .workbuddy,
        .claudeplatform,
    ]

    @Test
    func `cookie bindings preserve modes and keep headers separate from API keys`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: #function)
        fixture.settings.debugDisableKeychainAccess = false
        for provider in Self.providers {
            let implementation = try #require(ProviderCatalog.implementation(for: provider))
            let context = fixture.settingsContext(provider: provider)
            let field = try #require(implementation.settingsFields(context: context).first)
            fixture.settings[providerConfig: provider, field: .apiKey] = "fixture-api-key"
            field.binding.wrappedValue = "session=fixture"
            #expect(fixture.settings[providerConfig: provider, field: .cookieHeader] == "session=fixture")
            #expect(fixture.settings[providerConfig: provider, field: .apiKey] == "fixture-api-key")
            #expect(field.kind == .secure)
            if provider == .sakana {
                #expect(implementation.settingsPickers(context: context).isEmpty)
                #expect(field.isVisible == nil)
                continue
            }
            let picker = try #require(implementation.settingsPickers(context: context).first)
            let allowsOff = ![UsageProvider.qoder, .t3chat].contains(provider)
            #expect(picker.options.map(\.id) == (allowsOff ? ["auto", "manual", "off"] : ["auto", "manual"]))
            for mode in [ProviderCookieSource.auto, .manual, .off] {
                picker.binding.wrappedValue = mode.rawValue
                #expect(fixture.settings.providerConfig(for: provider)?.cookieSource == mode)
                #expect(field.isVisible?() == (mode == .manual))
            }
            picker.binding.wrappedValue = "unknown"
            #expect(fixture.settings.providerConfig(for: provider)?.cookieSource == .auto)
            fixture.settings.debugDisableKeychainAccess = true
            let disabled = try #require(implementation.settingsPickers(context: context).first)
            #expect(!disabled.options.contains { $0.id == "auto" })
            fixture.settings.debugDisableKeychainAccess = false
        }
    }

    @Test
    func `session accounts select manual cookies but Hyper API accounts do not`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: #function)
        for provider in [UsageProvider.manus, .qoder, .hyper] {
            let implementation = try #require(ProviderCatalog.implementation(for: provider))
            let support = try #require(TokenAccountSupportCatalog.support(for: provider))
            let context = fixture.settingsContext(provider: provider)
            fixture.settings.setCookieSource(.auto, provider: provider)
            #expect(implementation.tokenAccountsVisibility(context: context, support: support) == (provider == .hyper))
            implementation.applyTokenAccountCookieSource(settings: fixture.settings)
            #expect(fixture.settings.resolvedCookieSource(provider: provider, fallback: .auto) ==
                (provider == .hyper ? .auto : .manual))
            #expect(implementation.tokenAccountsVisibility(context: context, support: support))
        }
        #expect(RaycastProviderDescriptor.descriptor.credentials == nil)
        #expect(T3ChatProviderDescriptor.descriptor.credentials == nil)
    }

    @Test
    func `hybrid fetch kind follows the requested source without requiring a key`() async throws {
        let descriptor = HyperProviderDescriptor.descriptor
        for source in [ProviderSourceMode.auto, .web, .api] {
            let context = self.context(source: source)
            let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(context)
            let strategy = try #require(strategies.first)
            #expect(strategy.id == "hyper.js")
            #expect(strategy.kind == (source == .web ? .web : .apiToken))
            #expect(await strategy.isAvailable(context))
        }
        for provider in Self.providers where provider != .hyper {
            #expect(ProviderDescriptorRegistry.descriptor(for: provider).fetchPlan.sourceModes == [.auto, .web])
        }
    }

    @Test
    func `web watchdog budgets preserve request headroom and nonfinite policies`() throws {
        let raycast = try #require(RaycastProviderDescriptor.spec.webSource)
        let t3 = try #require(T3ChatProviderDescriptor.spec.webSource)
        let sakana = try #require(SakanaProviderDescriptor.spec.webSource)
        let cases: [(TimeInterval, TimeInterval, TimeInterval, TimeInterval)] = [
            (-1, 30, 20, 20), (15, 30, 20, 20), (60, 60, 65, 61), (200, 200, 95, 91),
            (.infinity, 30, 95, 20), (-.infinity, 30, 20, 20), (.nan, 30, 95, 20),
        ]
        for (input, raycastBudget, t3Budget, sakanaBudget) in cases {
            let context = self.context(timeout: input)
            #expect(raycast.timeout.resolve(context) == raycastBudget)
            #expect(t3.timeout.resolve(context) == t3Budget)
            #expect(sakana.timeout.resolve(context) == sakanaBudget)
        }
    }

    private func context(source: ProviderSourceMode = .auto, timeout: TimeInterval = 15) -> ProviderFetchContext {
        let base = ProviderCutoverTestSupport.context()
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: source,
            includeCredits: false,
            webTimeout: timeout,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: nil,
            fetcher: base.fetcher,
            claudeFetcher: base.claudeFetcher,
            browserDetection: base.browserDetection)
    }
}
