---
summary: "Agentforce and Data 360 month-to-date consumption from a production Salesforce org's Digital Wallet usage table."
provider_id: agentforce
provider_name: Agentforce
provider_source: Browser session on your production My Domain host for this month's Flex Credits, Data Services Credits, and other Digital Wallet consumption.
plugin_scope: Session-cookie bearer reads on the configured production My Domain host (user info, org type, one Data 360 query) on both engines, at most hourly; no balance or percentage.
read_when:
  - Configuring Agentforce
  - Debugging Agentforce usage fetching
---

# Agentforce

CodexBar shows Salesforce Agentforce and Data 360 consumption from your **production** org's Digital Wallet usage
table. It reads Salesforce directly; no extra service is involved.

## What it shows

One row per Digital Wallet card for the current calendar month in UTC (**This month (UTC)**):

- **Flex Credits** consumed month to date, listed first.
- **Data Services Credits** consumed month to date, listed second.
- Any other consumption card, such as Einstein Requests, as an additional row.

Each row shows the consumed quantity and its event count. Cards use different units, so they are never added
together. **Data Storage Allocation** is a storage level rather than consumption and is not shown. Salesforce exposes
no queryable balance, so CodexBar shows no percentage and no remaining amount.

**Usage through** gives the newest event in the result. Salesforce posts usage in a daily batch, up to about 25 hours
late, so the current day is usually incomplete.

## Requirements

- A production org with Data 360 and Digital Wallet. Sandbox orgs are not supported: sandbox usage is billed to
  production, and CodexBar refuses an org whose `Organization.IsSandbox` is true.
- The `TenantEnrichedUsageEvent` data lake object in a data space you can access. If it is missing, add it under
  **Data Spaces → default → Add Data Lake Object**.
- A Data 360 permission set, such as **Data Cloud User** or **Data Cloud Architect**.
- API access for your user.

## Setup

1. Enable **Agentforce** in Settings → Providers.
2. Enter your **My Domain URL**, for example `https://acme.my.salesforce.com`. Only production My Domain hosts on
   `my.salesforce.com` are accepted. CodexBar rejects sandbox, developer, and scratch domains, Lightning and other
   `force.com` hosts, `salesforce-setup.com`, paths, ports, query strings, and user info. The same value can be set
   as `enterpriseHost` in `~/.codexbar/config.json`.
3. Choose a **Cookie source**:
   - **Automatic** reads the `sid` session cookie for that exact host from your browser. Sign in to your My Domain
     host in a supported browser first.
   - **Manual** uses a pasted Cookie header from a request to your My Domain host. It must contain `sid`.
   - **Off** disables the provider's browser session.

When Salesforce rejects the session (`401` / `INVALID_SESSION_ID`, or a user info `403` with `Bad_OAuth_Token`,
`Missing_OAuth_Token`, or `Wrong_Org`), CodexBar discards it and asks you to sign in to your My Domain host in your
browser, then refresh. Changing the My Domain URL clears the cached session and never reuses a session cached for the
previous host.

## Requests and cost

Each refresh makes at most three read-only requests to your My Domain host:

1. `GET /services/oauth2/userinfo` for the organization ID (cached per host after the first success).
2. `GET /services/data/v65.0/query?q=SELECT+IsSandbox+FROM+Organization` to refuse sandboxes (cached with the ID).
3. `POST /services/data/v65.0/ssot/query-sql`: one Data 360 SQL query grouping `TenantEnrichedUsageEvent__dll` by
   card for your organization ID since the first day of the current UTC month.

The Data 360 query may consume Data Services credits. CodexBar therefore refreshes this provider **at most hourly**:
within an hour of a successful fetch it shows the saved result without contacting Salesforce, unless a new UTC month
has started. A query that ran but failed (an unusable result or a server error) is also not retried within the hour;
a rejected session, permission error, or rate limit never ran the query and does not wait. If a later refresh fails, the last good values stay visible, marked **Stale** with their time and the
failure, rather than dropping to zero; values from an earlier month are labelled with that month. A refused, truncated, or unfinished query result is treated as a failure.

## Privacy

The `sid` session cookie is sent only to your configured My Domain host, as `Authorization: Bearer …`, and is never
logged. Only `sid` is taken from the browser for that host. The saved result, organization ID, and fetch time are
stored in CodexBar's plugin storage; the session is not.

## Errors

| Message | Meaning |
|---|---|
| Sign in to your My Domain host in your browser, then refresh | No session, or Salesforce rejected it. |
| Needs a Data 360 permission set | HTTP 403 or `INSUFFICIENT_ACCESS` on the Data 360 query. |
| Needs API access (API Enabled) | HTTP 403 on the user info or org type read. |
| Rate limited | HTTP 429 or `REQUEST_LIMIT_EXCEEDED`. |
| TenantEnrichedUsageEvent is not in your data space | Add the data lake object to your data space. |
| Data 360 is not enabled in this org | Tenant not found or `FUNCTIONALITY_NOT_ENABLED`. |
| Sandbox orgs are not supported | Use the production org. |

## Icon

The monochrome icon is the Salesforce Lightning Design System utility icon `agent_astro`, the Agentforce agent
glyph, from `@salesforce-ux/design-system` 2.264.1 (`assets/icons/utility/agent_astro.svg`), licensed
[CC BY-ND 4.0](https://github.com/salesforce-ux/licenses/blob/master/LICENSE-icons-images.txt). Only technical changes
were made: the fill is `currentColor` and the viewBox is padded; the paths are unchanged. Agentforce and Salesforce
are trademarks of Salesforce, Inc.

Tests use fictitious org IDs and synthetic values on QuickJS and JavaScriptCore with stubbed transports and cookie
sessions. No live Salesforce org was queried during implementation.
