"""Login connectivity checks and non-destructive automatic proxy updates."""

import re

from source_patches import SourcePatches

APPLICATION = "submodules/TelegramUI/Sources/ApplicationContext.swift"
PROXIES = "submodules/TelegramCore/Sources/Network/AutomaticProxyBootstrap.swift"
PROXY_UI = "submodules/SettingsUI/Sources/Data and Storage/ProxyListSettingsController.swift"
NETWORK_RUNTIME_FILES = {
    "WhitegramLoginProbe.swift": "submodules/TelegramCore/Sources/WhitegramLoginProbe.swift",
}


def _recommendations(patches):
    for screen in ("Login", "Main"):
        marker = f"didShowProxyRecommendationOn{screen}Screen"
        replacement = f"        // {screen}: connection errors are handled by the native Telegram flow.\n"
        value = patches.read(APPLICATION)
        if replacement not in value:
            blocks = re.findall(r"^        Queue\.mainQueue\(\)\.after\(2\.0, \{ \[weak self\] in\n.*?^        \}\)\n", value, re.MULTILINE | re.DOTALL)
            blocks = [block for block in blocks if marker in block]
            if len(blocks) != 1:
                raise ValueError(f"Unexpected {screen} proxy recommendation")
            patches.replace("nativeConnectionErrors", APPLICATION, blocks[0], replacement)
    value = patches.read(APPLICATION)
    start = value.find("private var didShowProxyRecommendationOnMainScreen = false\n")
    if start >= 0:
        end = value.index("final class UnauthorizedApplicationContext", start)
        patches.replace("nativeConnectionErrors", APPLICATION, value[start:end], "// No unconditional proxy recommendation.\n\n")
    patches.features.setdefault("nativeConnectionErrors", set()).add(APPLICATION)


def apply_network_patches(root):
    patches = SourcePatches(root)
    _recommendations(patches)
    anchor = "    private var serviceNotificationEventsDisposable: Disposable?\n"
    patches.replace("loginConnectivityProbe", APPLICATION, anchor,
                    anchor + "    private var whitegramLoginProbe: Disposable?\n")
    anchor = "        DeviceAccess.authorizeAccess(to: .cellularData, presentationData: sharedContext.currentPresentationData.with { $0 },"
    patches.replace("loginConnectivityProbe", APPLICATION, anchor,
                    "        self.whitegramLoginProbe = whitegramObserveLoginConnection(network: account.network, foreground: sharedContext.applicationBindings.applicationInForeground)\n\n" + anchor)
    anchor = "        self.serviceNotificationEventsDisposable?.dispose()\n"
    patches.replace("loginConnectivityProbe", APPLICATION, anchor,
                    anchor + "        self.whitegramLoginProbe?.dispose()\n")

    # A fetched public list must not evict or disable a user's working proxy.
    start = "    let automaticSet = Set(settings.automaticServers)\n"
    end = "\nprivate func automaticProxyCleanupActiveServer"
    value = patches.read(PROXIES)
    before = value[value.index(start):value.index(end)]
    after = """    let automaticSet = Set(settings.automaticServers)
    return settings.servers.filter { server in
        return server == settings.activeServer || !automaticSet.contains(server)
    }
}
"""
    if "let migrateLegacyAutomaticServers" in before:
        patches.replace("preserveManualProxies", PROXIES, before, after)
    elif before != after:
        raise ValueError("Unexpected manual proxy ownership policy")
    patches.replace("preserveManualProxies", PROXIES,
                    "settings.servers = automaticProxyMergedServers(existing: fetchedServers, fetched: manualServers)",
                    "settings.servers = automaticProxyMergedServers(existing: manualServers, fetched: fetchedServers, limit: max(automaticProxyStoredServerLimit, manualServers.count))")
    patches.replace("preserveManualProxies", PROXIES, """            settings.automaticServers = fetchedServers
            if let activeServer = settings.activeServer, automaticProxyHostIsIPAddress(activeServer.host) {
                settings.activeServer = nil
                settings.enabled = false
            }
""", """            settings.automaticServers = fetchedServers.filter { !manualServers.contains($0) && settings.servers.contains($0) }
""")
    # Probes rank candidates; only connection failure may replace an active server.
    patches.replace("stableProxySelection", PROXIES, """            if settings.enabled && settings.autoConnectOnLaunch {
                settings.activeServer = automaticProxySortedAvailableServers(candidates: mergedServers, statuses: statuses).first
            }
""", """            // Keep the active connection while refreshing probe results.
""")
    patches.replace("stableProxySelection", PROXIES,
                    "if automaticSet.contains(server) && !fetchedSet.contains(server) {",
                    "if server != settings.activeServer && automaticSet.contains(server) && !fetchedSet.contains(server) {")
    patches.replace("stableProxySelection", PROXIES,
                    "if fetchedSet.contains(server), case .notAvailable? = statuses[server] {",
                    "if server != settings.activeServer && fetchedSet.contains(server), case .notAvailable? = statuses[server] {")
    patches.replace("stableProxySelection", PROXIES,
                    "let mergedServers = automaticProxyMergedServers(existing: autoAvailableServers, fetched: existingServers)",
                    "let mergedServers = automaticProxyMergedServers(existing: existingServers, fetched: autoAvailableServers, limit: max(automaticProxyStoredServerLimit, existingServers.count))")
    patches.replace("stableProxySelection", PROXIES,
                    "if strongSelf.currentSettings.enabled && (strongSelf.currentSettings.autoConnectOnLaunch || strongSelf.proxyNeeded) {",
                    "if strongSelf.currentSettings.enabled && strongSelf.currentSettings.autoConnectOnLaunch && strongSelf.proxyNeeded {", count=2)
    patches.replace("stableProxySelection", PROXIES, """        case .waitingForNetwork, .updating:
            if self.currentSettings.enabled && self.currentSettings.autoConnectOnLaunch {
                self.scheduleProxyActivation()
            }
""", """        case .waitingForNetwork, .updating:
            self.proxyNeeded = false
            self.activationTimer?.invalidate()
            self.activationTimer = nil
            self.connectionFallbackTimer?.invalidate()
            self.connectionFallbackTimer = nil
            self.bestSelectionTimer?.invalidate()
            self.bestSelectionTimer = nil
""")
    value = patches.read(PROXY_UI)
    start = "        if proxySettings.enabled && proxySettings.autoConnectOnLaunch, let bestServer = proxySettingsBestServer("
    replacement = "        // The network bootstrap owns automatic failover; rendering the list never switches servers.\n"
    if replacement not in value:
        begin = value.index(start)
        end = value.index("        }\n", value.index("            }).start()\n", begin)) + len("        }\n")
        patches.replace("stableProxySelection", PROXY_UI, value[begin:end], replacement)
    patches.features.setdefault("stableProxySelection", set()).add(PROXY_UI)
    return patches.write()
