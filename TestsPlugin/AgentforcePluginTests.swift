import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

/// Fictitious org, session, and consumption values only; no Salesforce org is contacted.
struct AgentforcePluginTests {
    static let host = "acme.my.salesforce.com"
    static let orgID = "00D000000000001AAA"
    /// 2026-10-18T12:00:00Z.
    static let now = Date(timeIntervalSince1970: 1_792_324_800)
    static let userinfo = #"{"organization_id":"00D000000000001AAA","user_id":"005000000000001AAA"}"#
    static let production =
        #"{"totalSize":1,"done":true,"records":[{"attributes":{"type":"Organization"},"IsSandbox":false}]}"#
    /// Columns deliberately out of query order: the plugin maps them by metadata name.
    static let consumption = #"""
    {"data":[
      [4567.5,"Flex Credits","2026-10-18T05:12:00.000+00:00",123],
      [890,"Data Services Credits","2026-10-17T22:00:00.000+00:00",40],
      [99999,"Data Storage Allocation","2026-10-18T09:00:00.000+00:00",1],
      [12,"Einstein Requests","2026-10-16T01:00:00.000+00:00",7]],
     "metadata":[{"name":"units","type":"DECIMAL"},{"name":"card","type":"VARCHAR"},
       {"name":"latest_event","type":"TIMESTAMP WITH TIME ZONE"},{"name":"n","type":"BIGINT"}],
     "returnedRows":4,
     "status":{"chunkCount":1,"completionStatus":"ResultsProduced","rowCount":4}}
    """#

    @Test(arguments: BundledPluginTestSupport.engines)
    func `consumption maps one row per card without storage or totals`(engine: ProviderPluginEngineKind) async throws {
        let stub = Stub()
        let result = try await Self.fetch(engine: engine, stub: stub)
        let usage = result.usage
        #expect(result.sourceLabel == "web")
        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.providerCost == nil)
        #expect(usage.dataConfidence == .exact)
        #expect(usage.identity?.accountID == Self.orgID)
        #expect(usage.details.map(\.title) == ["This month (UTC)", "Freshness"])
        let rows = try #require(usage.details.first).rows
        #expect(rows.map(\.label) == ["Flex Credits", "Data Services Credits", "Einstein Requests"])
        #expect(rows.map(\.value) == ["4,567.5", "890", "12"])
        #expect(rows.map(\.secondaryValue) == ["123 events", "40 events", "7 events"])
        #expect(rows.map(\.usageValue) == [4567.5, 890, 12])
        #expect(rows.allSatisfy { $0.progress == nil })
        let freshness = try #require(usage.details.last).rows
        #expect(freshness.map(\.label) == ["Usage through", "Reporting lag"])
        // The storage allocation's later event does not advance consumption freshness.
        #expect(freshness.first?.value == "~2026-10-18 05:12 UTC")

        let requests = stub.recorded
        #expect(requests.map { $0.url?.path } == [
            "/services/oauth2/userinfo", "/services/data/v65.0/query", "/services/data/v65.0/ssot/query-sql",
        ])
        #expect(requests[1].url?.query == "q=SELECT+IsSandbox+FROM+Organization")
        #expect(requests.map(\.httpMethod) == ["GET", "GET", "POST"])
        for request in requests {
            #expect(request.url?.scheme == "https")
            #expect(request.url?.host == Self.host)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-sid")
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        }
        let sql = try Self.sql(stub)
        #expect(sql.contains("FROM TenantEnrichedUsageEvent__dll"))
        #expect(sql.contains("entitlementorgid__c = '\(Self.orgID)'"))
        #expect(sql.contains("eventtime__c >= TIMESTAMP WITH TIME ZONE '2026-10-01 00:00:00+00:00'"))
        #expect(sql.contains("GROUP BY cardname__c"))
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `the month starts at midnight UTC whatever the local time zone`(engine: ProviderPluginEngineKind) async throws {
        for (instant, zone, month) in [
            ("2026-11-01T03:00:00Z", "America/Los_Angeles", "2026-11"),
            ("2026-10-31T23:00:00Z", "Asia/Tokyo", "2026-10"),
        ] {
            let stub = Stub()
            _ = try await Self.fetch(
                engine: engine, stub: stub, now: Self.date(instant), timeZone: TimeZone(identifier: zone)!)
            #expect(try Self.sql(stub).contains("TIMESTAMP WITH TIME ZONE '\(month)-01 00:00:00+00:00'"), "\(zone)")
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a malformed storage allocation row cannot fail the consumption result`(
        engine: ProviderPluginEngineKind) async throws
    {
        for units in ["-5", "null", "\"private-response\""] {
            let body = Self.consumption.replacingOccurrences(of: "[99999,", with: "[\(units),")
            let usage = try await Self.fetch(engine: engine, stub: Stub(query: (200, body))).usage
            #expect(usage.details.first?.rows.map(\.label) == ["Flex Credits", "Data Services Credits", "Einstein Requests"])
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a month without consumption still reports an empty month`(engine: ProviderPluginEngineKind) async throws {
        let empty = #"{"data":[],"metadata":[{"name":"card"},{"name":"n"},{"name":"units"},{"name":"latest_event"}],"#
            + #""status":{"completionStatus":"Finished","rowCount":0}}"#
        let usage = try await Self.fetch(engine: engine, stub: Stub(query: (200, empty))).usage
        #expect(usage.details.first?.rows.map(\.value) == ["None recorded"])
        #expect(usage.details.last?.rows.map(\.label) == ["Reporting lag"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `truncated, unfinished, or invalid query results fail closed`(engine: ProviderPluginEngineKind) async {
        let metadata = #""metadata":[{"name":"card"},{"name":"n"},{"name":"units"},{"name":"latest_event"}]"#
        let result = { (row: String, status: String, columns: String) in
            #"{"data":[\#(row)],\#(columns),"status":{"completionStatus":"\#(status)""#
        }
        for body in [
            result(#"["Flex Credits",1,2,null]"#, "ResultsProduced", metadata) + #","rowCount":2}}"#,
            result(#"["Flex Credits",1,2,null]"#, "Running", metadata) + #","rowCount":1}}"#,
            result(#"["Flex Credits",1,-2,null]"#, "Finished", metadata) + #","rowCount":1}}"#,
            result(#"["Flex Credits","1",2,null]"#, "Finished", metadata) + #","rowCount":1}}"#,
            result(#"["Flex Credits",1,2,null]"#, "Finished", #""metadata":[{"name":"card"}]"#) + #","rowCount":1}}"#,
            result(#"["Flex Credits",1,2,"private-response"]"#, "Finished", metadata) + #","rowCount":1}}"#,
            "private-response",
        ] {
            await Self.expectFailure(engine: engine, stub: Stub(query: (200, body)), kind: .parseFailure)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a rejected session is discarded and the next one is tried`(engine: ProviderPluginEngineKind) async throws {
        let sessions = Sessions([Self.session(sid: "expired-sid"), Self.session()])
        let stub = Stub { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer expired-sid"
                ? (401, #"[{"message":"Session expired or invalid","errorCode":"INVALID_SESSION_ID"}]"#) : nil
        }
        let result = try await Self.fetch(engine: engine, stub: stub, sessions: sessions)
        #expect(result.usage.details.first?.rows.count == 3)
        #expect(sessions.rejected == ["expired"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `an unauthorized session asks the user to sign in to the host`(engine: ProviderPluginEngineKind) async {
        let sessions = Sessions([Self.session()])
        let stub = Stub(userinfo: (401, #"[{"errorCode":"INVALID_SESSION_ID","message":"private-response"}]"#))
        await Self.expectFailure(engine: engine, stub: stub, sessions: sessions, kind: .authenticationExpired) {
            #expect($0 == "Sign in to acme.my.salesforce.com in your browser, then refresh.")
        }
        #expect(sessions.rejected == ["current"])
        #expect(stub.recorded.count == 1)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `an invalid token on user info rejects the session and asks the user to sign in`(
        engine: ProviderPluginEngineKind) async
    {
        for body in ["Bad_OAuth_Token", "Missing_OAuth_Token", "Wrong_Org"] {
            let sessions = Sessions([Self.session()])
            let stub = Stub(userinfo: (403, body))
            await Self.expectFailure(engine: engine, stub: stub, sessions: sessions, kind: .authenticationExpired) {
                #expect($0 == "Sign in to acme.my.salesforce.com in your browser, then refresh.")
            }
            #expect(sessions.rejected == ["current"])
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a session rejected by the usage query asks the user to sign in`(engine: ProviderPluginEngineKind) async {
        let storage = Self.storageDirectory()
        let expired = (401, #"[{"errorCode":"INVALID_SESSION_ID","message":"private-response"}]"#)
        // The first fetch reads and caches the org ID; the second goes straight to the query with it.
        for paths in [
            ["/services/oauth2/userinfo", "/services/data/v65.0/query", "/services/data/v65.0/ssot/query-sql"],
            ["/services/data/v65.0/ssot/query-sql"],
        ] {
            let sessions = Sessions([Self.session()])
            let stub = Stub(query: expired)
            await Self.expectFailure(
                engine: engine, stub: stub, storage: storage, sessions: sessions, kind: .authenticationExpired)
            { #expect($0 == "Sign in to acme.my.salesforce.com in your browser, then refresh.") }
            #expect(sessions.rejected == ["current"])
            #expect(stub.recorded.map { $0.url?.path } == paths)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a session from a previous host is skipped for the current host's session`(
        engine: ProviderPluginEngineKind) async throws
    {
        let sessions = Sessions([
            Self.session(sid: "old-sid", source: "Chrome / other.my.salesforce.com"), Self.session(),
        ])
        let stub = Stub()
        let result = try await Self.fetch(engine: engine, stub: stub, sessions: sessions)
        #expect(result.sourceLabel == "web")
        #expect(sessions.rejected == ["expired"])
        #expect(stub.recorded.count == 3)
        #expect(stub.recorded.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-sid" })
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `disabled cookies fail without contacting Salesforce`(engine: ProviderPluginEngineKind) async {
        let stub = Stub()
        await Self.expectFailure(engine: engine, stub: stub, cookieSource: .off, kind: .missingCredential) {
            #expect($0 == "Agentforce cookies are disabled.")
        }
        #expect(stub.recorded.isEmpty)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a session cached for another host is rejected without being sent`(engine: ProviderPluginEngineKind) async {
        let sessions = Sessions([Self.session(source: "Chrome / other.my.salesforce.com")])
        let stub = Stub()
        await Self.expectFailure(engine: engine, stub: stub, sessions: sessions, kind: .missingCredential) {
            #expect($0.hasPrefix("Sign in to acme.my.salesforce.com in your browser, then refresh."))
        }
        #expect(sessions.rejected == ["current"])
        #expect(stub.recorded.isEmpty)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a manual header must contain sid`(engine: ProviderPluginEngineKind) async {
        let sessions = Sessions([ProviderPluginCookieSession(
            header: "oid=fixture; other=value", source: "manual", origin: "https://my.salesforce.com")])
        let stub = Stub()
        await Self.expectFailure(
            engine: engine, stub: stub, sessions: sessions, cookieSource: .manual, kind: .missingCredential)
        { #expect($0.contains("contains sid")) }
        #expect(stub.recorded.isEmpty)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `Salesforce errors map to actionable messages`(engine: ProviderPluginEngineKind) async {
        let cases: [(Stub, ProviderFetchClassifiedError.Kind, String)] = [
            (Stub(userinfo: (403, "private-response")), .permissionDenied, "API Enabled"),
            (Stub(organization: (403, #"[{"errorCode":"API_DISABLED_FOR_ORG"}]"#)), .permissionDenied, "API Enabled"),
            (Stub(query: (403, #"[{"errorCode":"INSUFFICIENT_ACCESS"}]"#)), .permissionDenied, "Data Cloud User"),
            (
                Stub(query: (
                    403,
                    #"[{"errorCode":"INSUFFICIENT_ACCESS","message":"Object does not exist or you do not have access"}]"#)),
                .permissionDenied,
                "Data 360 permission set"),
            (Stub(userinfo: (429, "private-response")), .rateLimited, "rate limited"),
            (Stub(query: (403, #"[{"errorCode":"REQUEST_LIMIT_EXCEEDED"}]"#)), .rateLimited, "rate limited"),
            (
                Stub(query: (400, #"[{"message":"Table 'TenantEnrichedUsageEvent__dll' does not exist"}]"#)),
                .permissionDenied,
                "Data Spaces > default > Add Data Lake Object"),
            (Stub(query: (400, #"[{"errorCode":"FUNCTIONALITY_NOT_ENABLED"}]"#)), .permissionDenied, "not enabled"),
            (Stub(query: (404, #"{"message":"Tenant not found"}"#)), .permissionDenied, "not enabled"),
            (Stub(query: (503, "private-response")), .providerUnavailable, "HTTP 503"),
        ]
        for (stub, kind, text) in cases {
            await Self.expectFailure(engine: engine, stub: stub, kind: kind) { #expect($0.contains(text)) }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `sandbox orgs are refused before any query`(engine: ProviderPluginEngineKind) async {
        let stub = Stub(organization: (200, #"{"totalSize":1,"done":true,"records":[{"IsSandbox":true}]}"#))
        await Self.expectFailure(engine: engine, stub: stub, kind: .permissionDenied) {
            #expect($0.contains("Sandbox orgs are not supported"))
        }
        #expect(stub.recorded.map(\.httpMethod) == ["GET", "GET"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `organization IDs are validated before use`(engine: ProviderPluginEngineKind) async {
        for id in ["00D123", "001000000000001AAA", "00D000000000001AAA' OR '1'='1", "00D00000000000-AAA"] {
            let stub = Stub(userinfo: (200, #"{"organization_id":"\#(id)"}"#))
            await Self.expectFailure(engine: engine, stub: stub, kind: .parseFailure)
            #expect(stub.recorded.count == 1)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a fetch within an hour reuses the saved result without HTTP`(engine: ProviderPluginEngineKind) async throws {
        let storage = Self.storageDirectory()
        let first = try await Self.fetch(engine: engine, stub: Stub(), storage: storage)
        let quiet = Stub { _ in
            Issue.record("A throttled fetch must not contact Salesforce")
            return (500, "")
        }
        let cached = try await Self.fetch(
            engine: engine, stub: quiet, storage: storage, now: Self.now.addingTimeInterval(59 * 60))
        #expect(cached.sourceLabel == "cached")
        #expect(cached.usage.details == first.usage.details)
        #expect(quiet.recorded.isEmpty)

        // After the hour, the cached org ID skips user info and the org type read.
        let later = Stub()
        _ = try await Self.fetch(
            engine: engine,
            stub: later,
            storage: storage,
            now: Self.now.addingTimeInterval(61 * 60))
        #expect(later.recorded.map { $0.url?.path } == ["/services/data/v65.0/ssot/query-sql"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a query that ran but failed is not retried within the hour`(engine: ProviderPluginEngineKind) async {
        let storage = Self.storageDirectory()
        let truncated = Self.consumption.replacingOccurrences(of: #""rowCount":4"#, with: #""rowCount":5"#)
        await Self.expectFailure(engine: engine, stub: Stub(query: (200, truncated)), storage: storage, kind: .parseFailure)

        let soon = Stub()
        await Self.expectFailure(
            engine: engine, stub: soon, storage: storage, now: Self.now.addingTimeInterval(30 * 60),
            kind: .providerUnavailable)
        { message in
            #expect(message.contains("retrying after 2026-10-18 13:00 UTC"))
        }
        #expect(!soon.recorded.contains { $0.url?.path == "/services/data/v65.0/ssot/query-sql" })

        let later = Stub()
        _ = try? await Self.fetch(engine: engine, stub: later, storage: storage, now: Self.now.addingTimeInterval(61 * 60))
        #expect(later.recorded.map { $0.url?.path } == ["/services/data/v65.0/ssot/query-sql"])

        // A rejected session never ran the query, so signing in again can retry at once.
        let signedOut = Self.storageDirectory()
        await Self.expectFailure(
            engine: engine,
            stub: Stub(query: (401, #"[{"errorCode":"INVALID_SESSION_ID"}]"#)),
            storage: signedOut,
            kind: .authenticationExpired)
        let retried = Stub()
        _ = try? await Self.fetch(
            engine: engine, stub: retried, storage: signedOut, now: Self.now.addingTimeInterval(60))
        #expect(retried.recorded.map { $0.url?.path } == ["/services/data/v65.0/ssot/query-sql"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a failure after a success keeps the last good values marked stale`(
        engine: ProviderPluginEngineKind) async throws
    {
        let storage = Self.storageDirectory()
        _ = try await Self.fetch(engine: engine, stub: Stub(), storage: storage)
        let stale = try await Self.fetch(
            engine: engine,
            stub: Stub(query: (503, "private-response")),
            storage: storage,
            now: Self.now.addingTimeInterval(2 * 60 * 60))
        #expect(stale.sourceLabel == "stale")
        #expect(stale.usage.details.map(\.title) == ["Stale", "This month (UTC)", "Freshness"])
        let status = try #require(stale.usage.details.first).rows
        #expect(status.map(\.label) == ["As of", "Last error"])
        #expect(status.first?.value == "2026-10-18 12:00 UTC")
        #expect(status.first?.severity == .warning)
        #expect(status.last?.value == "Salesforce returned HTTP 503.")
        #expect(stale.usage.details[1].rows.map(\.value) == ["4,567.5", "890", "12"])
        #expect(!stale.usage.details.flatMap(\.rows).contains { $0.value == "0" })

        // A different host never reuses another host's saved result.
        await Self.expectFailure(
            engine: engine,
            stub: Stub(query: (503, "private-response")),
            storage: storage,
            myDomain: "https://other.my.salesforce.com",
            sessions: Sessions([Self.session(source: "Chrome / other.my.salesforce.com")]),
            kind: .providerUnavailable)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `every failure after a success keeps the last good values with a clean reason`(
        engine: ProviderPluginEngineKind) async throws
    {
        let truncated = Self.consumption.replacingOccurrences(of: #""rowCount":4"#, with: #""rowCount":5"#)
        let cases: [(Stub, String, [String])] = [
            (Stub(query: (200, truncated)), "Data 360 returned an unusable usage result: truncated rows.", []),
            (
                Stub(query: (401, #"[{"errorCode":"INVALID_SESSION_ID","message":"private-response"}]"#)),
                "Sign in to acme.my.salesforce.com in your browser, then refresh.",
                ["current"]),
            (
                Stub(query: (403, #"[{"errorCode":"INSUFFICIENT_ACCESS","message":"private-response"}]"#)),
                "Agentforce needs a Data 360 permission set (Data Cloud User or Data Cloud Architect).",
                []),
            (Stub(query: (429, "private-response")), "Salesforce rate limited the request (HTTP 429).", []),
        ]
        for (stub, reason, rejected) in cases {
            let storage = Self.storageDirectory()
            _ = try await Self.fetch(engine: engine, stub: Stub(), storage: storage)
            let sessions = Sessions([Self.session()])
            let stale = try await Self.fetch(
                engine: engine,
                stub: stub,
                storage: storage,
                now: Self.now.addingTimeInterval(2 * 60 * 60),
                sessions: sessions)
            #expect(stale.sourceLabel == "stale")
            #expect(stale.usage.details.map(\.title) == ["Stale", "This month (UTC)", "Freshness"])
            #expect(stale.usage.details.first?.rows.last?.value == reason)
            #expect(stale.usage.details[1].rows.map(\.value) == ["4,567.5", "890", "12"])
            #expect(sessions.rejected == rejected)
            let values = stale.usage.details.flatMap(\.rows).map(\.value)
            #expect(!values.contains { $0.contains("__CODEXBAR") || $0.contains("private-response") })
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a new UTC month bypasses the hourly cache and relabels stale totals`(
        engine: ProviderPluginEngineKind) async throws
    {
        let lastDay = Self.date("2026-10-31T23:30:00Z")
        let nextMonth = Self.date("2026-11-01T00:10:00Z")

        let storage = Self.storageDirectory()
        _ = try await Self.fetch(engine: engine, stub: Stub(), storage: storage, now: lastDay)
        let fresh = Stub()
        let refreshed = try await Self.fetch(engine: engine, stub: fresh, storage: storage, now: nextMonth)
        #expect(refreshed.sourceLabel == "web")
        #expect(try Self.sql(fresh).contains("TIMESTAMP WITH TIME ZONE '2026-11-01 00:00:00+00:00'"))

        let failing = Self.storageDirectory()
        _ = try await Self.fetch(engine: engine, stub: Stub(), storage: failing, now: lastDay)
        let stale = try await Self.fetch(
            engine: engine, stub: Stub(query: (503, "private-response")), storage: failing, now: nextMonth)
        #expect(stale.sourceLabel == "stale")
        #expect(stale.usage.details.map(\.title) == ["Stale", "2026-10 (UTC)", "Freshness"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `imported cookies keep only sid and are bound to the configured host`(
        engine: ProviderPluginEngineKind) async throws
    {
        let bound = try #require(AgentforceProviderDescriptor.boundSessions(
            [
                ("oid=00D000000000001; sid=fixture-sid; BrowserId=fixture", "Chrome Default"),
                ("BrowserId=fixture", "Safari"),
            ],
            host: Self.host))
        #expect(bound.map(\.header) == ["sid=fixture-sid"])
        #expect(bound.map(\.source) == ["Chrome Default / acme.my.salesforce.com"])
        #expect(AgentforceProviderDescriptor.boundSessions(nil, host: Self.host) == nil)

        // The plugin accepts exactly the binding the importer produces.
        let sessions = Sessions(bound.map {
            ProviderPluginCookieSession(
                header: $0.header, source: $0.source, origin: "https://my.salesforce.com", id: "current")
        })
        let stub = Stub()
        #expect(try await Self.fetch(engine: engine, stub: stub, sessions: sessions).sourceLabel == "web")
        #expect(sessions.rejected.isEmpty)
        #expect(stub.recorded.count == 3)
        for request in stub.recorded {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-sid")
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        }
    }

    @Test
    func `the strategy refuses invalid hosts and disabled cookies before any request`() async {
        let stub = Stub()
        let strategy = AgentforceProviderDescriptor.scriptStrategy(transport: stub.transport)
        for host in [
            "https://acme--uat.sandbox.my.salesforce.com", "https://acme.my.salesforce.com.evil.com",
            "https://acme.lightning.force.com", "http://acme.my.salesforce.com",
        ] {
            do {
                _ = try await strategy.fetch(Self.context(myDomain: host))
                Issue.record("Expected \(host) to be refused")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == .missingCredential)
            } catch {
                Issue.record("Unexpected failure: \(error)")
            }
        }
        let off = Self.context(myDomain: "https://\(Self.host)", cookieSource: .off)
        #expect(await !strategy.isAvailable(off))
        await #expect(throws: ProviderPluginError.self) { try await strategy.fetch(off) }
        #expect(stub.recorded.isEmpty)
    }

    @Test
    func `My Domain validation accepts only production hosts`() {
        #expect(AgentforceMyDomain.host("https://acme.my.salesforce.com") == "acme.my.salesforce.com")
        #expect(AgentforceMyDomain.host(" https://ACME.my.salesforce.com/ ") == "acme.my.salesforce.com")
        for value in [
            nil, "", "acme.my.salesforce.com", "http://acme.my.salesforce.com",
            "https://acme.my.salesforce.com.evil.com", "https://evilmy.salesforce.com",
            "https://user@acme.my.salesforce.com", "https://user:pass@acme.my.salesforce.com",
            "https://acme.my.salesforce.com:8443", "https://acme.my.salesforce.com/services",
            "https://acme.my.salesforce.com?x=1", "https://acme.my.salesforce.com#x",
            "https://my.salesforce.com", "https://acme--uat.sandbox.my.salesforce.com",
            "https://acme-dev-ed.develop.my.salesforce.com", "https://fun-1.scratch.my.salesforce.com",
            "https://acme.lightning.force.com", "https://acme.my.force.com", "https://acme.my.salesforce-setup.com",
            "https://acme%2eevil.com.my.salesforce.com", "https://a.b.my.salesforce.com",
        ] {
            #expect(AgentforceMyDomain.host(value) == nil, "\(value ?? "nil")")
        }
    }

    @Test
    func `descriptor projects the host, validates config, and stays opt-in`() throws {
        let descriptor = AgentforceProviderDescriptor.descriptor
        let credentials = try #require(descriptor.credentials)
        #expect(!descriptor.metadata.defaultEnabled)
        #expect(descriptor.config.supportsEnterpriseHost)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .web])
        var config = ProviderConfig(id: .agentforce)
        config.enterpriseHost = "https://acme.my.salesforce.com"
        let environment = credentials.applyConfig(base: [:], config: config)
        #expect(environment[AgentforceProviderDescriptor.myDomainKey] == "https://acme.my.salesforce.com")
        #expect(credentials.validateConfig(config).isEmpty)
        #expect(credentials.unavailableMessage(environment: environment) == nil)
        config.enterpriseHost = "https://acme--uat.sandbox.my.salesforce.com"
        #expect(credentials.validateConfig(config).map(\.code) == ["invalid_enterprise_host"])
        #expect(credentials.unavailableMessage(environment: [:])?.contains("My Domain URL") == true)
    }

    // MARK: - Fixtures

    private static func session(sid: String = "fixture-sid", source: String = "Chrome / \(host)")
        -> ProviderPluginCookieSession
    {
        ProviderPluginCookieSession(
            header: "sid=\(sid)",
            source: source,
            origin: "https://my.salesforce.com",
            id: sid == "fixture-sid" ? "current" : "expired")
    }

    private static func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private static func sql(_ stub: Stub) throws -> String {
        let body = try #require(stub.recorded.last?.httpBody)
        return try #require((JSONSerialization.jsonObject(with: body) as? [String: String])?["sql"])
    }

    private static func context(
        myDomain: String,
        cookieSource: ProviderCookieSource = .auto) -> ProviderFetchContext
    {
        ProviderFetchContext(
            runtime: .cli,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 10,
            webDebugDumpHTML: false,
            verbose: false,
            env: [AgentforceProviderDescriptor.myDomainKey: myDomain],
            settings: .init(.init(cookieSource: cookieSource), for: AgentforceProviderSettingsKey.self),
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: BrowserDetection()),
            browserDetection: BrowserDetection())
    }

    private static func storageDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("agentforce-plugin-\(UUID().uuidString)")
    }

    private static func expectFailure(
        engine: ProviderPluginEngineKind,
        stub: Stub,
        storage: URL = Self.storageDirectory(),
        now: Date = Self.now,
        myDomain: String = "https://\(host)",
        sessions: Sessions = Sessions([Self.session()]),
        cookieSource: ProviderCookieSource = .auto,
        kind: ProviderFetchClassifiedError.Kind,
        message check: (String) -> Void = { _ in }) async
    {
        do {
            _ = try await self.fetch(
                engine: engine,
                stub: stub,
                storage: storage,
                now: now,
                myDomain: myDomain,
                sessions: sessions,
                cookieSource: cookieSource)
            Issue.record("Expected a classified failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
            #expect(!error.message.contains("private-response"))
            #expect(!error.message.contains("fixture-sid"))
            check(error.message)
        } catch {
            Issue.record("Unexpected failure: \(error)")
        }
    }

    private static func fetch(
        engine: ProviderPluginEngineKind,
        stub: Stub,
        storage: URL = Self.storageDirectory(),
        now: Date = Self.now,
        timeZone: TimeZone = TimeZone(identifier: "America/Los_Angeles")!,
        myDomain: String = "https://\(host)",
        sessions: Sessions = Sessions([Self.session()]),
        cookieSource: ProviderCookieSource = .auto) async throws -> ProviderPluginResult
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "agentforce", engine: engine, transport: stub.transport, storageDirectory: storage)
        return try await runtime.fetchResult(
            settings: [AgentforceProviderDescriptor.myDomainKey: myDomain],
            now: now,
            timeZone: timeZone,
            sourceMode: .auto,
            cookieSource: cookieSource,
            cookieSessionResolver: { _, _ in sessions.next() },
            cookieSessionInvalidator: { _, id in sessions.reject(id) })
    }

    private final class Sessions: @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [ProviderPluginCookieSession]
        private var rejectedIDs: [String] = []

        init(_ sessions: [ProviderPluginCookieSession]) {
            self.queue = sessions
        }

        var rejected: [String] {
            self.lock.withLock { self.rejectedIDs }
        }

        func next() -> ProviderPluginCookieSession? {
            self.lock.withLock { self.queue.isEmpty ? nil : self.queue.removeFirst() }
        }

        func reject(_ id: String) {
            self.lock.withLock { self.rejectedIDs.append(id) }
        }
    }

    private final class Stub: @unchecked Sendable {
        typealias Reply = (Int, String)
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        private let override: @Sendable (URLRequest) -> Reply?
        private let userinfo: Reply
        private let organization: Reply
        private let query: Reply

        init(
            userinfo: Reply = (200, AgentforcePluginTests.userinfo),
            organization: Reply = (200, AgentforcePluginTests.production),
            query: Reply = (200, AgentforcePluginTests.consumption),
            override: @escaping @Sendable (URLRequest) -> Reply? = { _ in nil })
        {
            self.userinfo = userinfo
            self.organization = organization
            self.query = query
            self.override = override
        }

        convenience init(_ override: @escaping @Sendable (URLRequest) -> Reply?) {
            self.init(override: override)
        }

        var recorded: [URLRequest] {
            self.lock.withLock { self.requests }
        }

        var transport: ProviderHTTPTransportHandler {
            ProviderHTTPTransportHandler { request in
                self.lock.withLock { self.requests.append(request) }
                let path = request.url?.path ?? ""
                let (status, body) = self.override(request)
                    ?? (path.hasSuffix("/userinfo") ? self.userinfo
                        : path.hasSuffix("/query-sql") ? self.query : self.organization)
                let response = try #require(HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json", "Retry-After": "0"]))
                return (Data(body.utf8), response)
            }
        }
    }
}
