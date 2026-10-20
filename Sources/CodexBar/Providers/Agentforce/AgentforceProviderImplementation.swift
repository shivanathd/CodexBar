import CodexBarCore
import Foundation
import SwiftUI

struct AgentforceProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .agentforce

    private var cookies: PluginCookieProviderImplementation {
        PluginCookieProviderImplementation(spec: AgentforceProviderDescriptor.spec)
    }

    @MainActor
    func presentation(context: ProviderPresentationContext) -> ProviderPresentation {
        self.cookies.presentation(context: context)
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        self.cookies.observeSettings(settings)
        _ = settings[providerConfig: self.id, field: .endpoint]
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        self.cookies.settingsSnapshot(context: context)
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        AgentforceMyDomain.host(context.environment[AgentforceProviderDescriptor.myDomainKey]) != nil
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        self.cookies.settingsPickers(context: context)
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        let endpoint = context.providerConfigBinding(.endpoint)
        let pasted = context.providerConfigBinding(.cookieHeader)
        // Cached and pasted sids belong to the previous org; clear both as soon as the host changes, because the
        // plugin cannot tell which host a pasted header was captured from.
        let myDomain = Binding(
            get: { endpoint.wrappedValue },
            set: { value in
                if let previous = AgentforceMyDomain.host(endpoint.wrappedValue),
                   previous != AgentforceMyDomain.host(value)
                {
                    _ = CookieHeaderCache.clear(provider: .agentforce)
                    pasted.wrappedValue = ""
                }
                endpoint.wrappedValue = value
            })
        return [ProviderSettingsFieldDescriptor(
            id: "agentforce-my-domain-url",
            title: "My Domain URL",
            subtitle: "Your production org's My Domain, like https://acme.my.salesforce.com. " +
                "Sandboxes are not supported.",
            kind: .plain,
            placeholder: "https://acme.my.salesforce.com",
            binding: myDomain,
            actions: [],
            isVisible: nil)] + self.cookies.settingsFields(context: context)
    }
}
