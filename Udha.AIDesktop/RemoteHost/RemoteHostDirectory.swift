import Foundation
import Observation

/// Every box this desktop is driving, one `RemoteHostClient` each.
///
/// The relay pairs a client socket with *one* host (`set_active_instance`),
/// so showing two boxes at once means two sockets. Before this there was a
/// single client that re-paired whenever a different host was picked — and
/// a switch left the first host's rows on the board while everything per-host
/// (its login pools, its stats, every action verb) now belonged to the second.
/// A session on one box read another box's logins, and "Switch login" sent its
/// id to the wrong machine.
///
/// `discovery` is a client that never pairs: it only keeps `onlineHosts`
/// current, so the directory can connect each host as it appears. Each
/// connected host gets its own client, keyed by name, and every reader asks
/// for the client of the host it is looking at — never "the" client.
@MainActor
@Observable
final class RemoteHostDirectory {
    let discovery: RemoteHostClient
    /// Connected (or connecting) hosts by name, as the relay spells them.
    private(set) var clients: [String: RemoteHostClient] = [:]
    /// Hosts the user disconnected on purpose; auto-connect leaves them alone
    /// until they are connected again by hand.
    private var declined: Set<String> = []

    private let auth0: Auth0Client
    private let relayURL: String
    private let stateStore: SessionStateStore
    private let excludeInstanceID: String?

    init(auth0: Auth0Client, relayURL: String, stateStore: SessionStateStore, excludeInstanceID: String? = nil) {
        self.auth0 = auth0
        self.relayURL = relayURL
        self.stateStore = stateStore
        self.excludeInstanceID = excludeInstanceID
        self.discovery = RemoteHostClient(auth0: auth0, relayURL: relayURL,
                                          stateStore: stateStore, excludeInstanceID: excludeInstanceID)
    }

    /// Fires whenever the relay's host list changes (connect, a host coming
    /// online), with every online host.
    var onHostsDiscovered: (([String]) -> Void)? {
        get { discovery.onHostsDiscovered }
        set { discovery.onHostsDiscovered = newValue }
    }

    func startDiscovery() { discovery.startDiscovery() }

    /// Hosts the relay says are online for this account, plus every host a
    /// client is paired with right now. Discovery's own list can miss a host
    /// that dropped and re-announced while its socket was down — a box went
    /// missing from the New Session picker while connected and streaming.
    var onlineHosts: [String] {
        var hosts = discovery.onlineHosts
        for h in connectedHosts where !hosts.contains(where: { $0.caseInsensitiveCompare(h) == .orderedSame }) {
            hosts.append(h)
        }
        return hosts
    }

    /// Every host client, by name.
    var all: [RemoteHostClient] { clients.keys.sorted().compactMap { clients[$0] } }

    /// Hosts that are paired and handshaken right now.
    var connectedHosts: [String] {
        clients.filter { $0.value.state == .connected }.keys.sorted()
    }

    private func key(_ host: String) -> String? {
        clients.keys.first { $0.compare(host, options: .caseInsensitive) == .orderedSame }
    }

    /// The client driving `host`, if this desktop is connected to it. Nil for
    /// nil (this Mac) and for a host that is not connected.
    func client(for host: String?) -> RemoteHostClient? {
        guard let host, let k = key(host) else { return nil }
        return clients[k]
    }

    func isConnected(_ host: String) -> Bool { client(for: host)?.state == .connected }

    /// Connect to `host` (idempotent): a dropped pairing is retried, a live
    /// one is left alone. Returns the host's client.
    @discardableResult
    func connect(_ host: String) -> RemoteHostClient {
        declined.remove(host.lowercased())
        if let existing = client(for: host) {
            if !existing.isPaired { existing.pair(withHostNamed: host) }
            return existing
        }
        let client = RemoteHostClient(auth0: auth0, relayURL: relayURL,
                                      stateStore: stateStore, excludeInstanceID: excludeInstanceID)
        clients[host] = client
        client.pair(withHostNamed: host)
        return client
    }

    /// Drop `host`'s sessions and close its socket. The host stays in the
    /// relay's list; `connect` brings it back.
    func disconnect(_ host: String) {
        declined.insert(host.lowercased())
        guard let k = key(host), let client = clients[k] else { return }
        client.disconnect()
        clients[k] = nil
    }

    /// Connect every online host that is not connected and was not dropped by
    /// hand — what discovery calls so both machines show without a click.
    func connectAll(_ hosts: [String]) {
        for host in hosts where !declined.contains(host.lowercased()) && client(for: host) == nil {
            connect(host)
        }
    }

    /// Whether folder actions are offered for `host`: this Mac always, a box
    /// only once its agent speaks `folders`. Unknown (not connected) reads as
    /// supported — the verb is refused later with a reason, not hidden.
    func supportsFolders(host: String?) -> Bool {
        client(for: host)?.hostFoldersUnsupported != true
    }

    /// Whether a box's agent can move a session between Claude logins.
    func supportsAccounts(host: String?) -> Bool {
        client(for: host)?.hostAccountsUnsupported != true
    }

    /// Ask every connected host for its vitals.
    func requestStats() { for c in clients.values { c.requestStats() } }
}
