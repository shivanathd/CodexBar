defineProvider({
  id: "agentforce",
  name: "Agentforce",
  endpoints: [{ setting: "AGENTFORCE_MY_DOMAIN_URL", policy: "https" }],
  settings: [{ key: "AGENTFORCE_MY_DOMAIN_URL", title: "My Domain URL", type: "plain" }],
  capabilities: ["browser-cookies", "http-status", "persistent-storage"],
  // One logical domain; the host maps it to the validated My Domain host before importing sid.
  cookieDomains: ["my.salesforce.com"],
  async fetchUsage(ctx) {
    const domain = "my.salesforce.com";
    // The host validates a production My Domain origin and declares it as the only request origin.
    const base = (ctx.settings.get("AGENTFORCE_MY_DOMAIN_URL") ?? "").replace(/\/+$/, "");
    const host = base.slice("https://".length);
    if (!base.startsWith("https://") || !host) {
      throw ctx.fail.missingCredential("Set your production Salesforce My Domain URL in Settings.");
    }
    const nowMs = ctx.date.now().getTime();
    const hourMs = 60 * 60 * 1000;
    type Stored = { host: string; fetchedAt: number; usage: CodexBarUsageSnapshot };
    type Org = { host: string; orgId: string };
    const orgPattern = /^00D[A-Za-z0-9]{12}([A-Za-z0-9]{3})?$/;
    const read = (key: string): Record<string, unknown> | undefined => {
      try {
        const value: unknown = JSON.parse(ctx.storage.get(key) ?? "null");
        return value && typeof value === "object" && !Array.isArray(value)
          ? (value as Record<string, unknown>)
          : undefined;
      } catch (error) {
        void error;
        return undefined;
      }
    };
    const write = (key: string, value: unknown): void => {
      // A full or busy store must not discard a fresh reading.
      try {
        ctx.storage.set(key, JSON.stringify(value));
      } catch (error) {
        void error;
      }
    };
    const storedState = read("state");
    const state: Stored | undefined =
      storedState &&
      storedState.host === host &&
      typeof storedState.fetchedAt === "number" &&
      Number.isFinite(storedState.fetchedAt) &&
      storedState.usage &&
      typeof storedState.usage === "object"
        ? (storedState as unknown as Stored)
        : undefined;
    // UTC year-month, like "2026-10".
    const month = (ms: number): string => new Date(ms).toISOString().slice(0, 7);
    const sameMonth = state !== undefined && month(state.fetchedAt) === month(nowMs);
    // Each query may consume Data Services credits and Salesforce posts usage in a daily batch.
    // A new UTC month starts a new period, so last month's totals are never served as this month's.
    if (state && sameMonth && nowMs >= state.fetchedAt && nowMs - state.fetchedAt < hourMs) {
      return { usage: state.usage, sourceLabel: "cached" };
    }
    const utc = (ms: number): string => `${new Date(ms).toISOString().slice(0, 16).replace("T", " ")} UTC`;
    const periodTitle = "This month (UTC)";
    // The stale path shows the message this plugin composed, never the host's encoded error.
    let lastError = "Refresh failed";
    const fail = (kind: keyof CodexBarFailures, message: string): Error => {
      lastError = message;
      return ctx.fail[kind](message);
    };

    const live = async (): Promise<CodexBarUsageSnapshot> => {
      const policy = ctx.browser.availability(domain);
      if (policy === "off") throw fail("missingCredential", "Agentforce cookies are disabled.");
      const signIn = `Sign in to ${host} in your browser, then refresh.`;
      const unauthorized = Symbol("unauthorized");
      const classify = (response: CodexBarHTTPTextResponse, query: boolean): void | typeof unauthorized => {
        // query-sql answers 201 Created; any 2xx is success.
        if (response.status >= 200 && response.status < 300) return;
        // Error bodies are matched for Salesforce error codes only and never echoed.
        const body = response.bodyText;
        if (response.status === 401 || body.includes("INVALID_SESSION_ID")) return unauthorized;
        // userinfo answers an invalid, expired, or other-org token with HTTP 403 and an OAuth error code.
        if (!query && /Bad_OAuth_Token|Missing_OAuth_Token|Wrong_Org/.test(body)) return unauthorized;
        if (response.status === 429 || body.includes("REQUEST_LIMIT_EXCEEDED")) {
          throw fail("rateLimited", `Salesforce rate limited the request (HTTP ${response.status}).`);
        }
        if (body.includes("FUNCTIONALITY_NOT_ENABLED") || /tenant[^"]{0,80}not found/i.test(body)) {
          throw fail("permissionDenied", "Data 360 is not enabled in this org.");
        }
        // Access errors come first: Salesforce often words them "does not exist or you do not have access".
        if (response.status === 403 || body.includes("INSUFFICIENT_ACCESS")) {
          throw fail(
            "permissionDenied",
            query
              ? "Agentforce needs a Data 360 permission set (Data Cloud User or Data Cloud Architect)."
              : "Your Salesforce user needs API access (the API Enabled permission).",
          );
        }
        if (query && body.includes("does not exist")) {
          throw fail(
            "permissionDenied",
            "TenantEnrichedUsageEvent is not in your data space: Data Spaces > default > Add Data Lake Object.",
          );
        }
        const message = `Salesforce returned HTTP ${response.status}.`;
        if (response.status >= 500) throw fail("providerUnavailable", message);
        throw fail("apiFailure", message);
      };
      const json = (response: CodexBarHTTPTextResponse, what: string): Record<string, unknown> => {
        try {
          const value: unknown = JSON.parse(response.bodyText);
          if (value && typeof value === "object" && !Array.isArray(value)) return value as Record<string, unknown>;
        } catch (error) {
          void error;
        }
        throw fail("parseFailure", `Salesforce returned an unrecognized ${what} response.`);
      };

      const fetchWith = async (sid: string): Promise<CodexBarUsageSnapshot | typeof unauthorized> => {
        const headers = { Authorization: `Bearer ${sid}` };
        const get = (path: string) =>
          ctx.http.get(`${base}${path}`, { headers, timeoutSeconds: 15, retryPolicy: "transientIdempotent" });
        const cachedOrg = read("org");
        let orgId = cachedOrg && cachedOrg.host === host ? (cachedOrg as unknown as Org).orgId : undefined;
        if (typeof orgId !== "string" || !orgPattern.test(orgId)) {
          const userinfo = await get("/services/oauth2/userinfo");
          if (classify(userinfo, false) === unauthorized) return unauthorized;
          const id = json(userinfo, "user info").organization_id;
          if (typeof id !== "string" || !orgPattern.test(id)) {
            throw fail("parseFailure", "Salesforce returned an unrecognized organization ID.");
          }
          const organization = await get("/services/data/v65.0/query?q=SELECT+IsSandbox+FROM+Organization");
          if (classify(organization, false) === unauthorized) return unauthorized;
          const records = json(organization, "organization").records;
          const record = Array.isArray(records) && records.length === 1 ? records[0] : undefined;
          const isSandbox = record && typeof record === "object" ? (record as { IsSandbox?: unknown }).IsSandbox : null;
          if (typeof isSandbox !== "boolean") {
            throw fail("parseFailure", "Salesforce returned an unrecognized organization response.");
          }
          if (isSandbox) {
            throw fail(
              "permissionDenied",
              "Sandbox orgs are not supported; use your production org (sandbox usage is billed to production).",
            );
          }
          orgId = id;
          write("org", { host, orgId });
        }

        // An explicit UTC instant: a zoneless TIMESTAMP would be read in the query session's time zone.
        const monthStart = `${month(nowMs)}-01 00:00:00+00:00`;
        const sql =
          "SELECT cardname__c AS card, COUNT(*) AS n, SUM(unitsconsumed__c) AS units, " +
          "MAX(eventtime__c) AS latest_event FROM TenantEnrichedUsageEvent__dll " +
          `WHERE entitlementorgid__c = '${orgId}' AND eventtime__c >= TIMESTAMP WITH TIME ZONE '${monthStart}' ` +
          "GROUP BY cardname__c";
        // A query that ran but failed may still have consumed credits, so it is not retried within the hour; a new UTC month starts over.
        const attempt = read("queryAttempt");
        const attemptAt = attempt && attempt.host === host ? attempt.at : undefined;
        if (
          typeof attemptAt === "number" &&
          month(attemptAt) === month(nowMs) &&
          nowMs >= attemptAt &&
          nowMs - attemptAt < hourMs
        ) {
          throw fail(
            "providerUnavailable",
            `The last Data 360 query failed; retrying after ${utc(attemptAt + hourMs)}.`,
          );
        }
        const response = await ctx.http.post(`${base}/services/data/v65.0/ssot/query-sql`, {
          body: { sql },
          headers,
          timeoutSeconds: 45,
        });
        if ((response.status >= 200 && response.status < 300) || response.status >= 500)
          write("queryAttempt", { host, at: nowMs });
        if (classify(response, true) === unauthorized) return unauthorized;
        const root = json(response, "Data 360 query");
        const unusable = (detail: string): never => {
          throw fail("parseFailure", `Data 360 returned an unusable usage result: ${detail}.`);
        };
        const status =
          root.status && typeof root.status === "object"
            ? (root.status as Record<string, unknown>)
            : unusable("status");
        if (status.completionStatus !== "ResultsProduced" && status.completionStatus !== "Finished") {
          unusable("the query did not finish");
        }
        if (!Array.isArray(root.data) || !Array.isArray(root.metadata)) return unusable("missing rows");
        if (status.rowCount !== root.data.length) unusable("truncated rows");
        const names = root.metadata.map((column: unknown) =>
          column && typeof column === "object" ? (column as { name?: unknown }).name : undefined,
        );
        const index = (name: string): number => {
          const position = names.indexOf(name);
          return position < 0 ? unusable(`missing ${name}`) : position;
        };
        const [cardAt, countAt, unitsAt, latestAt] = ["card", "n", "units", "latest_event"].map(index);
        const quantity = (value: unknown): number =>
          typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : unusable("invalid number");
        let latest: number | undefined;
        const cards: Array<{ card: string; count: number; units: number }> = [];
        for (const row of root.data) {
          if (!Array.isArray(row)) return unusable("invalid row");
          const card = typeof row[cardAt] === "string" ? row[cardAt].trim() : "";
          if (!card) return unusable("invalid card");
          // A storage allocation level, not consumption; skipped before validation so it cannot fail the result.
          if (card === "Data Storage Allocation") continue;
          cards.push({ card, count: quantity(row[countAt]), units: quantity(row[unitsAt]) });
          const event = row[latestAt];
          if (event != null) {
            const time = typeof event === "string" ? Date.parse(event) : NaN;
            if (!Number.isFinite(time)) return unusable("invalid event time");
            latest = latest === undefined ? time : Math.max(latest, time);
          }
        }
        const rank = (card: string): number => (card === "Flex Credits" ? 0 : card === "Data Services Credits" ? 1 : 2);
        cards.sort((a, b) => rank(a.card) - rank(b.card) || (a.card < b.card ? -1 : a.card > b.card ? 1 : 0));
        // Each card is its own unit; capacity is not queryable, so no percentage, remaining, or total.
        const rows: CodexBarDetailRow[] = cards.slice(0, 24).map((entry) => ({
          label: entry.card.slice(0, 120),
          value: ctx.format.number(entry.units, { maximumFractionDigits: 2 }),
          secondaryValue: `${ctx.format.number(entry.count, { maximumFractionDigits: 0 })} events`,
          usageValue: entry.units,
        }));
        const freshness: CodexBarDetailRow[] = [];
        if (latest !== undefined) freshness.push({ label: "Usage through", value: `~${utc(latest)}` });
        freshness.push({ label: "Reporting lag", value: "Salesforce posts usage up to ~25 h late" });
        return {
          details: [
            {
              title: periodTitle,
              rows: rows.length ? rows : [{ label: "Consumption", value: "None recorded" }],
            },
            { title: "Freshness", rows: freshness },
          ],
          identity: { accountID: orgId, loginMethod: "Browser session" },
          dataConfidence: "exact",
        };
      };

      let rejected = false;
      for await (const session of ctx.browser.sessions(domain)) {
        // Imported sessions name their host; a session cached for a previous host is never sent.
        if (policy !== "manual" && !session.source.endsWith(` / ${host}`)) {
          ctx.browser.rejectCookie(domain, session);
          continue;
        }
        const sid = (session.header ?? "")
          .split(";")
          .map((pair) => pair.trim())
          .find((pair) => pair.startsWith("sid="))
          ?.slice(4);
        if (!sid) {
          if (policy === "manual") throw fail("missingCredential", "Paste a Cookie header that contains sid.");
          continue;
        }
        const usage = await fetchWith(sid);
        if (usage !== unauthorized) return usage;
        rejected = true;
        ctx.browser.rejectCookie(domain, session);
        if (policy === "manual") break;
      }
      throw rejected
        ? fail("authenticationExpired", signIn)
        : fail("missingCredential", `${signIn} Supported browsers: ${ctx.browser.supportedBrowsers}.`);
    };

    try {
      const usage = await live();
      write("state", { host, fetchedAt: nowMs, usage });
      return { usage, sourceLabel: "web" };
    } catch (error) {
      if (!state) throw error;
      // Never replace a good reading with zeros: keep it, marked stale with its age and the failure.
      const stale: CodexBarDetailSection = {
        title: "Stale",
        rows: [
          { label: "As of", value: utc(state.fetchedAt), severity: "warning" },
          { label: "Last error", value: lastError.slice(0, 120) },
        ],
      };
      // A reading from an earlier month is labelled with its own month, not as this month.
      const details = (state.usage.details ?? []).map((section) =>
        sameMonth || section.title !== periodTitle ? section : { ...section, title: `${month(state.fetchedAt)} (UTC)` },
      );
      return {
        usage: {
          ...state.usage,
          details: [stale, ...details].slice(0, 8),
          dataConfidence: "unknown",
        },
        sourceLabel: "stale",
      };
    }
  },
});
