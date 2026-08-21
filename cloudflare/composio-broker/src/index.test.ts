import { afterEach, describe, expect, it, vi } from "vitest";

import {
  authorize,
  connectedServices,
  connectionStatus,
  createSession,
  disconnectAccount,
  ensureSession,
  normalizeAccountAlias,
  parseSession,
  sha256,
} from "./index";

const multiAccount = {
  enable: true,
  max_accounts_per_toolkit: 5,
  require_explicit_selection: true,
};

function session(id: string, userId: string, configured = true, maxAccounts = 5) {
  return {
    session_id: id,
    mcp: { url: `https://mcp.composio.dev/${id}` },
    config: {
      user_id: userId,
      multi_account: configured
        ? { ...multiAccount, max_accounts_per_toolkit: maxAccounts }
        : undefined,
    },
  };
}

function testEnv(fetchCalls: Array<{ url: string; init?: RequestInit }>) {
  const dbRuns: Array<{ sql: string; values: unknown[] }> = [];
  const env = {
    COMPOSIO_API_BASE: "https://backend.composio.dev/api/v3.1",
    COMPOSIO_TOOLKIT_BASE: "https://backend.composio.dev/api/v3",
    COMPOSIO_API_KEY: "ak_test",
    REGISTRATION_MODE: "open",
    REGISTRATION_LIMITER: { limit: async () => ({ success: true }) },
    SESSION_LIMITER: { limit: async () => ({ success: true }) },
    DB: {
      prepare(sql: string) {
        return {
          bind(...values: unknown[]) {
            return {
              run: async () => {
                dbRuns.push({ sql, values });
              },
            };
          },
        };
      },
    },
  };
  const ctx = { waitUntil(promise: Promise<unknown>) { void promise; } };
  // SAFETY: The broker tests exercise only the D1, rate-limit, and waitUntil
  // members implemented by these in-memory fakes; no other binding is read.
  const typedEnv = env as typeof env & Env;
  // SAFETY: The tested broker paths use only waitUntil on ExecutionContext.
  const typedContext = ctx as typeof ctx & ExecutionContext;
  return { env: typedEnv, ctx: typedContext, dbRuns, fetchCalls };
}

afterEach(() => vi.unstubAllGlobals());

describe("connected-apps broker boundaries", () => {
  it("accepts only HTTPS Composio MCP endpoints", () => {
    expect(parseSession({
      session_id: "session-1",
      mcp: { url: "https://mcp.composio.dev/session", headers: { "x-session": "one", host: "bad" } },
    })).toEqual({
      sessionId: "session-1",
      url: "https://mcp.composio.dev/session",
      headers: { "x-session": "one" },
      userId: undefined,
      multiAccountConfigured: false,
    });
    expect(() => parseSession({ session_id: "session-1", mcp: { url: "https://attacker.example/mcp" } })).toThrow(/untrusted/i);
    expect(() => parseSession({ session_id: "session-1", mcp: { url: "http://mcp.composio.dev/session" } })).toThrow(/untrusted/i);
  });

  it("hashes installation tokens before storage", async () => {
    await expect(sha256("openmausbot")).resolves.toBe("63c74f70a9d4681c334e84001935955a75245ea5b16b9c37c808e85c69963705");
  });

  it("creates Sessions with explicit multi-account selection", async () => {
    const fetchCalls: Array<{ url: string; init?: RequestInit }> = [];
    const { env } = testEnv(fetchCalls);
    vi.stubGlobal("fetch", async (input: string | URL | Request, init?: RequestInit) => {
      fetchCalls.push({ url: String(input), init });
      return Response.json(session("trs_new", "omb_user"), { status: 201 });
    });

    await expect(createSession(env, "omb_user")).resolves.toMatchObject({
      sessionId: "trs_new",
      multiAccountConfigured: true,
    });
    expect(JSON.parse(String(fetchCalls[0].init?.body))).toMatchObject({
      user_id: "omb_user",
      multi_account: multiAccount,
    });
  });

  it("upgrades a legacy Session without changing the installation's Composio user", async () => {
    const fetchCalls: Array<{ url: string; init?: RequestInit }> = [];
    const { env, ctx, dbRuns } = testEnv(fetchCalls);
    vi.stubGlobal("fetch", async (input: string | URL | Request, init?: RequestInit) => {
      const url = String(input);
      fetchCalls.push({ url, init });
      if (init?.method === "POST") return Response.json(session("trs_new", "omb_stable"), { status: 201 });
      return Response.json(session("trs_legacy", "omb_stable", false));
    });

    await expect(ensureSession({
      id: "install-1",
      composio_user_id: "omb_stable",
      session_id: "trs_legacy",
      disabled_at: null,
    }, env, ctx)).resolves.toMatchObject({ sessionId: "trs_new", multiAccountConfigured: true });
    const creation = fetchCalls.find((call) => call.init?.method === "POST");
    expect(JSON.parse(String(creation?.init?.body))).toMatchObject({ user_id: "omb_stable", multi_account: multiAccount });
    expect(dbRuns.some((run) => run.values[0] === "trs_new" && run.values[2] === "install-1")).toBe(true);
  });

  it("reuses a Session whose upstream multi-account capacity is above the requested floor", async () => {
    const fetchCalls: Array<{ url: string; init?: RequestInit }> = [];
    const { env, ctx } = testEnv(fetchCalls);
    vi.stubGlobal("fetch", async (input: string | URL | Request, init?: RequestInit) => {
      fetchCalls.push({ url: String(input), init });
      return Response.json(session("trs_capacity_10", "omb_stable", true, 10));
    });

    await expect(ensureSession({
      id: "install-1",
      composio_user_id: "omb_stable",
      session_id: "trs_capacity_10",
      disabled_at: null,
    }, env, ctx)).resolves.toMatchObject({
      sessionId: "trs_capacity_10",
      multiAccountConfigured: true,
    });
    expect(fetchCalls).toHaveLength(1);
    expect(fetchCalls[0]?.init?.method).not.toBe("POST");
  });

  it("returns every account and deletes only an owned account ID", async () => {
    const fetchCalls: Array<{ url: string; init?: RequestInit }> = [];
    const { env, ctx } = testEnv(fetchCalls);
    const accounts = {
      items: [
        { id: "ca_work", alias: "work", toolkit: { slug: "gmail" }, status: "ACTIVE", updated_at: "2026-08-21T10:00:00Z" },
        { id: "ca_personal", alias: "personal", toolkit: { slug: "gmail" }, status: "INITIALIZING", updated_at: "2026-08-21T11:00:00+02:00" },
      ],
      next_cursor: "accounts-page-2",
    };
    let connectedAccountsUnavailable = false;
    vi.stubGlobal("fetch", async (input: string | URL | Request, init?: RequestInit) => {
      const url = String(input);
      fetchCalls.push({ url, init });
      if (url.includes("/tool_router/session/trs_multi/toolkits")) {
        const query = new URL(url).searchParams;
        if (query.get("cursor") === "toolkits-page-2") {
          return Response.json({
            items: [
              { slug: "publicsearch", is_no_auth: true },
              { slug: "selectedonly", connected_account: { id: "ca_session_only", status: "ACTIVE" } },
            ],
          });
        }
        const body = {
          items: [{ slug: "gmail", connected_account: { id: "ca_work", status: "ACTIVE" } }],
          next_cursor: query.has("toolkits") ? undefined : "toolkits-page-2",
        };
        return Response.json(body);
      }
      if (url.endsWith("/tool_router/session/trs_multi/link") && init?.method === "POST") {
        return Response.json({ redirect_url: "https://connect.composio.dev/link/gmail" }, { status: 201 });
      }
      if (url.includes("/tool_router/session/trs_multi")) return Response.json(session("trs_multi", "omb_stable"));
      if (url.includes("/connected_accounts?") && !init?.method) {
        if (connectedAccountsUnavailable) {
          return Response.json({ error: "connected-account read not granted" }, { status: 403 });
        }
        if (url.includes("cursor=accounts-page-2")) {
          return Response.json({
            items: [
              { id: "ca_toolkit_41", alias: "overflow", toolkit: { slug: "toolkit_41" }, status: "ACTIVE", updated_at: "2026-08-21T12:00:00Z" },
            ],
          });
        }
        return Response.json(accounts);
      }
      if (url.includes("/connected_accounts/ca_work") && init?.method === "DELETE") return Response.json({ success: true });
      return Response.json({ error: "not found" }, { status: 404 });
    });
    const installation = {
      id: "install-1",
      composio_user_id: "omb_stable",
      session_id: "trs_multi",
      disabled_at: null,
    };

    const statusResponse = await connectionStatus(
      new URL("https://broker.example/v1/connectors?services=gmail"),
      installation,
      env,
      ctx,
    );
    await expect(statusResponse.json()).resolves.toEqual({
      services: {
        gmail: {
          connected: true,
          pending: true,
          status: "ACTIVE",
          accounts: [
            { id: "ca_work", alias: "work", status: "ACTIVE" },
            { id: "ca_personal", alias: "personal", status: "INITIALIZING" },
          ],
        },
      },
    });
    const connectedResponse = await connectedServices(installation, env, ctx);
    await expect(connectedResponse.json()).resolves.toMatchObject({
      configured: true,
      services: {
        toolkit_41: {
          connected: true,
          pending: false,
          status: "ACTIVE",
          accounts: [{ id: "ca_toolkit_41", alias: "overflow", status: "ACTIVE" }],
        },
        publicsearch: {
          connected: true,
          pending: false,
          status: "ACTIVE",
          accounts: [],
        },
        selectedonly: {
          connected: true,
          pending: false,
          status: "ACTIVE",
          accounts: [{ id: "ca_session_only", status: "ACTIVE" }],
        },
      },
    });
    const inventoryCall = fetchCalls.find((call) =>
      call.url.includes("/connected_accounts?") && !call.url.includes("toolkit_slugs=")
    );
    expect(inventoryCall).toBeDefined();
    expect(fetchCalls.some((call) =>
      call.url.includes("/connected_accounts?")
        && !call.url.includes("toolkit_slugs=")
        && call.url.includes("cursor=accounts-page-2")
    )).toBe(true);
    expect(fetchCalls.some((call) =>
      call.url.includes("/tool_router/session/trs_multi/toolkits?")
        && !call.url.includes("toolkits=")
        && call.url.includes("cursor=toolkits-page-2")
    )).toBe(true);

    connectedAccountsUnavailable = true;
    const fallbackStatus = await connectionStatus(
      new URL("https://broker.example/v1/connectors?services=gmail"),
      installation,
      env,
      ctx,
    );
    await expect(fallbackStatus.json()).resolves.toEqual({
      services: {
        gmail: {
          connected: true,
          pending: false,
          status: "ACTIVE",
          accounts: [],
        },
      },
    });
    const fallbackResponse = await connectedServices(installation, env, ctx);
    await expect(fallbackResponse.json()).resolves.toMatchObject({
      configured: true,
      services: {
        gmail: {
          connected: true,
          status: "ACTIVE",
          accounts: [{ id: "ca_work", status: "ACTIVE" }],
        },
        publicsearch: { connected: true, status: "ACTIVE", accounts: [] },
        selectedonly: {
          connected: true,
          status: "ACTIVE",
          accounts: [{ id: "ca_session_only", status: "ACTIVE" }],
        },
      },
    });
    connectedAccountsUnavailable = false;
    await expect((await disconnectAccount("gmail", "ca_work", installation, env, ctx)).json())
      .resolves.toEqual({ removed: 1 });
    await expect((await disconnectAccount("gmail", "ca_not_owned", installation, env, ctx)).json())
      .resolves.toEqual({ removed: 0 });
    expect(fetchCalls.filter((call) => call.init?.method === "DELETE")).toHaveLength(1);

    const missingAlias = await authorize("gmail", undefined, installation, env, ctx);
    expect(missingAlias.status).toBe(400);
    await expect(missingAlias.json()).resolves.toEqual({
      error: "Add an account alias so the existing connection is not replaced",
    });
    const authorized = await authorize("gmail", "second", installation, env, ctx);
    expect(authorized.status).toBe(200);
    await expect(authorized.json()).resolves.toEqual({ url: "https://connect.composio.dev/link/gmail" });
    const linkCall = fetchCalls.find((call) => call.url.endsWith("/tool_router/session/trs_multi/link"));
    expect(JSON.parse(String(linkCall?.init?.body))).toEqual({ toolkit: "gmail", alias: "second" });
  });

  it("validates aliases at the broker boundary", () => {
    expect(normalizeAccountAlias("  work gmail  ")).toBe("work gmail");
    for (const alias of [
      "bad\nalias",
      "bad\u0085alias",
      "bad\u2028alias",
      "bad\u202Ealias",
      "bad\u2066alias",
    ]) {
      expect(() => normalizeAccountAlias(alias)).toThrow(/printable/i);
    }
  });

  it("bounds complete inventory pagination within the Worker subrequest budget", async () => {
    const fetchCalls: Array<{ url: string; init?: RequestInit }> = [];
    const { env, ctx } = testEnv(fetchCalls);
    let accountPage = 0;
    let toolkitPage = 0;
    vi.stubGlobal("fetch", async (input: string | URL | Request, init?: RequestInit) => {
      const url = String(input);
      fetchCalls.push({ url, init });
      if (url.includes("/connected_accounts?")) {
        accountPage += 1;
        return Response.json({ items: [], next_cursor: `account-page-${accountPage}` });
      }
      if (url.includes("/tool_router/session/trs_budget/toolkits?")) {
        toolkitPage += 1;
        return Response.json({ items: [], next_cursor: `toolkit-page-${toolkitPage}` });
      }
      return Response.json(session("trs_budget", "omb_stable"));
    });

    await expect(connectedServices({
      id: "install-1",
      composio_user_id: "omb_stable",
      session_id: "trs_budget",
      disabled_at: null,
    }, env, ctx)).rejects.toThrow(/pagination safety limit/i);

    const accountCalls = fetchCalls.filter((call) => call.url.includes("/connected_accounts?"));
    const toolkitCalls = fetchCalls.filter((call) => call.url.includes("/tool_router/session/trs_budget/toolkits?"));
    expect(accountCalls).toHaveLength(10);
    expect(toolkitCalls).toHaveLength(10);
    expect([...accountCalls, ...toolkitCalls].every((call) => new URL(call.url).searchParams.get("limit") === "50"))
      .toBe(true);
  });
});
