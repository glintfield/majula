# Majula agent credentials and terms

Read date for every source below: **2026-11-25**. Every quote was fetched with `curl` from the URL given, mostly from the providers' own Markdown doc twins (`.md`). No blogs or forum posts are used as authority. The one secondary lead, a web-search summary of an "Agent SDK credit", is labelled as a lead and was **not** confirmed.

Majula, as the roadmap describes it (`majula-roadmap-design.md`, the Decisions rows "Open source" and "Agent credentials", and job 1.3): it is Apache-2.0 with every repo public, installed with Homebrew, and self-hosted. It runs coding agents for its own user, and native apps connect to it. It never bundles an agent CLI; it detects what the user installed. The user brings their own authentication for each runtime.

How Outpost, the predecessor, did it as of 2026-11-25:

- `src/integrations/claude-login.ts` runs `claude auth login` in a pty.
- `src/integrations/runtime-login.ts` runs `codex login --device-auth` and Cursor's `agent login`.
- `src/integrations/usage-poller.ts:18` calls `https://api.anthropic.com/api/oauth/usage`, using `claudeAiOauth.accessToken` read from the Keychain by `src/integrations/claude-credentials.ts` (`usage-poller.ts:179`).

## Summary

|                                       | Claude                                                                                                                                                                                | Codex                                                                                                                    | Cursor                                                                                | Gemini CLI / generic ACP                                                                                                  |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| 1. Drive the user's own signed-in CLI | **Unclear; decided: support it.** The user may sign in to the unmodified binary; a third-party developer may not "route requests through" subscription credentials                    | **Allowed** (documented app-server modes)                                                                                | **Allowed** (ACP and `agent login` are documented for custom clients)                 | Gemini: **allowed only through the unmodified CLI.** Direct use of its OAuth by third-party software is explicitly banned |
| 2. API keys / console credentials     | **Allowed.** This is the sanctioned path                                                                                                                                              | **Allowed**                                                                                                              | **Allowed** (user API key)                                                            | **Allowed** (Gemini API key, Vertex)                                                                                      |
| 3(i). Majula's own OAuth client       | **Not allowed**                                                                                                                                                                       | **Allowed, in preview:** the Sign in with ChatGPT open-source flow (conflicting availability text); decided: don't build | **No such program exists**, so don't                                                  | Gemini: **not allowed**                                                                                                   |
| 3(ii). Relay the CLI's own login      | **Unclear; decided: don't.** The user signs in at a terminal                                                                                                                          | **Allowed** (app-server `chatgptDeviceCode`)                                                                             | **Probably allowed** (documented `NO_OPEN_BROWSER=1`), but nothing addresses relaying | **Unclear**                                                                                                               |
| 4. Read usage limits                  | Outpost's current method is **not allowed**. Documented sources exist inside the SDK, but whether a third party may surface them is **unclear**; decided: use the last-seen SDK value | **Allowed** (`account/rateLimits/read`)                                                                                  | **No sanctioned source** for individual users                                         | **No documented source**                                                                                                  |
| 5. Redistribution / license           | The Agent SDK is proprietary **and bundles the Claude Code binary**. This conflicts with "never bundle"                                                                               | Apache-2.0                                                                                                               | Proprietary; the terms bar reproducing it                                             | Apache-2.0 (Gemini CLI, ACP)                                                                                              |

## Decisions (dc, 2026-11-25)

- **No runtime is required.** Claude is one optional runtime alongside Codex, Cursor and ACP agents such as Gemini CLI. Majula runs with whichever runtimes it detects, and nothing in its core depends on Claude.
- **No provider will be asked.** Claude's login question is settled by design: Majula has no embedded Claude login. The user signs in to the unmodified `claude` themselves, through Anthropic's own flow, and Majula only drives that binary. This is the shape S-A2 explicitly allows ("an end user signing in to the unmodified Claude Code binary with their own Claude subscription"). The residual exposure is S-A1's "unless previously approved … including agents built on the Claude Agent SDK", which is accepted.

---

## Claude (Claude Agent SDK and the `claude` CLI)

### Sources (quoted)

**S-A1. Agent SDK overview**, https://code.claude.com/docs/en/agent-sdk/overview (read 2026-11-25). This is the statement the brief asked for, verbatim:

> "Unless previously approved, Anthropic does not allow third party developers to offer claude.ai login or rate limits for their products, including agents built on the Claude Agent SDK. Use the API key authentication methods described in the [Quickstart] instead."

Branding, same page:

> "For partners integrating the Claude Agent SDK, use of Claude branding is optional. When referencing Claude in your product:
> **Allowed:** "Claude Agent", preferred for dropdown menus · "Claude", when within a menu already labeled "Agents" · "{YourAgentName} Powered by Claude", if you have an existing agent name
> **Not permitted:** "Claude Code" or "Claude Code Agent" · Claude Code-branded ASCII art or visual elements that mimic Claude Code
> Your product should maintain its own branding and not appear to be Claude Code or any Anthropic product. For questions about branding compliance, contact the Anthropic sales team."

License, same page:

> "Use of the Claude Agent SDK is governed by Anthropic's Commercial Terms of Service, including when you use it to power products and services that you make available to your own customers and end users, except to the extent a specific component or dependency is covered by a different license as indicated in that component's LICENSE file."

**S-A2. Legal and compliance**, https://code.claude.com/docs/en/legal-and-compliance (read 2026-11-25):

> "Your use of Claude Code is subject to: Commercial Terms of Service - for Team, Enterprise, and Claude API users · Consumer Terms of Service - for Free, Pro, Max, and Ultra users"

> "Advertised usage limits for Pro, Max, and Ultra plans assume ordinary, individual usage of Claude Code and the Agent SDK."

> "**OAuth authentication** is intended exclusively for purchasers of Claude Free, Pro, Max, Ultra, Team, and Enterprise subscription plans and is designed to support ordinary use of Claude Code and other native Anthropic applications."

> "**Developers** building products or services that interact with Claude's capabilities, including those using the Agent SDK, should use API key authentication through Claude Console or a supported cloud provider. Anthropic does not permit third-party developers to offer Claude.ai login into their own applications, or to route requests through Free, Pro, Max, or Ultra plan credentials on behalf of their users. Moreover, developers may not collect, store, or intermediate Claude.ai credentials or session tokens — sign-in to a Claude account must complete through Anthropic's own flow."

> "This does not restrict how customers provision and manage their own API keys or third-party inference provider credentials … provided the resulting usage is billed to the key owner under their agreement with Anthropic (or the applicable provider) and is not resold or intermediated as described above. Nor does it prevent an end user from signing in to the unmodified Claude Code binary with their own Claude subscription, including where a platform hosts Claude Code as described under _Can customers offer Claude Code in their products?_ above."

> "Anthropic reserves the right to take measures to enforce these restrictions and may do so without prior notice."

"Can customers offer Claude Code in their products?", same page:

> "Unless we've mutually agreed otherwise, preinstalling or running Claude Code in your products or services (e.g. in hosted sandboxes or other agent infrastructure) requires agreeing to our Commercial Terms of Service and complying with the conditions below:
>
> - **The Claude Code binary must not be modified.** Claude Code must be installed and run as published by Anthropic, and customers may not remove, disable, or restrict any authentication method built into it (including methods that permit signing in with a Claude account or the user's own API key).
> - **Customers may not pay for, resell, or intermediate Claude usage on their end users' behalf.** Each end user must authenticate with their own Anthropic API key, Claude subscription plan credentials, or 3P inference provider credential (Amazon Bedrock, Google Cloud's Agent Platform, Microsoft Foundry). That usage is billed directly to the end user under their own agreement with Anthropic or, for third-party inference providers, with the applicable provider."

> "**Using the Claude Code name and logo.** You can accurately say, in plain text, that your product has Claude Code preinstalled or that it runs Claude Code. But you can't use the Claude Code or Anthropic names or logos as part of your own product, feature, or company name, in your own logo, or in a way that suggests Anthropic built, endorses, or is partnered with your product. Any other use of Anthropic's names or logos is governed by our Trademark Guidelines and requires our written permission."

**S-A3. Consumer Terms**, https://www.anthropic.com/legal/consumer-terms (read 2026-11-25). Among the prohibited uses:

> "Except when you are accessing our Services via an Anthropic API Key or where we otherwise explicitly permit it, to access the Services through automated or non-human means, whether through a bot, script, or otherwise."

> "You may not share your Account login information, Anthropic API key, or Account credentials with anyone else. You also may not make your Account available to anyone else."

> "Please note: Our Commercial Terms of Service govern your use of any Anthropic API key, the Anthropic Console, or any other Anthropic offerings that reference the Commercial Terms of Service. For clarity, this does not include Claude.ai or Claude Pro use for individuals or entities."

**S-A4. Documented usage-limit surfaces.**

https://code.claude.com/docs/en/statusline (read 2026-11-25):

> "`rate_limits.five_hour.used_percentage`, `rate_limits.seven_day.used_percentage` | Percentage of the 5-hour or 7-day rate limit consumed, from 0 to 100"

> "`rate_limits`: appears only for claude.ai Pro, Max, and Ultra subscribers, or behind a Claude apps gateway that sets a spend limit for you. Even then, it appears only after the first API response in the session."

https://code.claude.com/docs/en/agent-sdk/typescript (read 2026-11-25):

> "`usage_report` is a structured copy of the `/usage` report, typed as `SDKUsageReport`, and requires Agent SDK v0.3.273 or later. When you send `/usage` as a prompt, Claude Code delivers the report as an assistant message … It attaches `usage_report` to that same message only when the session meets all of these conditions: The session authenticates with a claude.ai credential · The credential shows a known plan type or carries the `user:profile` scope · The account isn't on usage-based billing"

> "Structured form of the `/usage` report … The type is experimental: its shape may change."

> "`rate_limits`: the plan's usage rows in `limits` and usage-credits spend in `extra_usage`. It is `null` when Claude Code couldn't get the plan's usage …"

> "`SDKRateLimitEvent` — Emitted when the session encounters a rate limit." (with `status: "allowed" | "allowed_warning" | "rejected"`, `resetsAt`, `utilization`)

**S-A5. Licenses and the bundled binary.**

- https://raw.githubusercontent.com/anthropics/claude-agent-sdk-typescript/main/LICENSE.md and https://raw.githubusercontent.com/anthropics/claude-code/main/LICENSE.md: both read, verbatim, "© Anthropic PBC. All rights reserved. Use is subject to Anthropic's Commercial Terms of Service."
- npm `@anthropic-ai/claude-agent-sdk@0.3.332`: `"license":"SEE LICENSE IN README.md"`. It has `optionalDependencies` on eight `@anthropic-ai/claude-agent-sdk-<platform>` packages.
- https://code.claude.com/docs/en/agent-sdk/typescript: "The SDK bundles a native Claude Code binary for your platform as an optional dependency such as `@anthropic-ai/claude-agent-sdk-darwin-arm64`. Most installs need no separate Claude Code install. … If your package manager skips optional dependencies, the SDK throws `Native CLI binary for <platform>-<arch> not found`; set `pathToClaudeCodeExecutable` to a separately installed `claude` binary instead."

**S-A6. Trademark Guidelines**, https://www.anthropic.com/legal/trademark-guidelines (read 2026-11-25):

> "You may only use our trademarks as specifically permitted by us and only in materials we approve beforehand. We may terminate permission to use our trademarks at any time."

> "You may not use our trademarks in a manner that implies Anthropic's sponsorship or endorsement, or a relationship or affiliation with Anthropic, except as we expressly authorize."

**Lead only, not confirmed:** a web-search summary said that from June 15, 2026, "Agent SDK and `claude -p` usage on subscription plans will draw from a new monthly Agent SDK credit". I could not find this text on the overview, authentication or cost-tracking pages. Treat it as unverified. If it is real, it would mean Anthropic accounts for SDK use on subscriptions, but it would not change the third-party restriction in S-A1 and S-A2.

### Q1. Drive a `claude` the user already signed into with Pro/Max

- **Allowed:** the end user may "sign in to the unmodified Claude Code binary with their own Claude subscription, including where a platform hosts Claude Code" (S-A2). Plan limits "assume ordinary, individual usage of Claude Code and the Agent SDK" (S-A2). Anthropic itself contemplates subscription-authenticated SDK sessions (S-A4, `usage_report` needs a claude.ai credential).
- **Not allowed:** a third-party developer may not "route requests through Free, Pro, Max, or Ultra plan credentials on behalf of their users", and may not "offer claude.ai login … for their products, including agents built on the Claude Agent SDK" unless "previously approved" (S-A1, S-A2). Consumer accounts may not be accessed by "automated or non-human means" except via an API key "or where we otherwise explicitly permit it" (S-A3).
- **Unclear:** whether Majula counts as a developer routing requests "on behalf of their users". Arguments that it doesn't: it is self-hosted, runs for one user on that user's own machine, never touches the token, and the binary is unmodified. The counter-argument: Majula is a _product built on the Agent SDK_ whose only Claude login is the user's subscription, and S-A1's carve-out requires "previously approved". Autonomous runs (schedules, controller loops) also push against "ordinary, individual usage" and the S-A3 automation clause. The sources neither permit nor forbid this exact shape. **I am not inferring permission.**
- Team and Enterprise seats (often SSO-only, so no API key is available) aren't named in the "Free, Pro, Max, or Ultra" sentence and fall under the Commercial Terms, but S-A1 and the "intermediate" sentence in S-A2 apply on every plan.
- **Recommended Majula behavior (decided):** support the user's own signed-in `claude` as a first-class path alongside API keys and Bedrock/Vertex/Foundry (Q2). Majula never reads, copies, stores or forwards the token (see Q4), passes no `CLAUDE_CODE_OAUTH_TOKEN`, runs the unmodified binary, and ships no login of its own (Q3).

### Q2. API keys and console credentials

- **Allowed:** "should use API key authentication through Claude Console or a supported cloud provider" (S-A2). Each end user brings "their own Anthropic API key … or 3P inference provider credential (Amazon Bedrock, Google Cloud's Agent Platform, Microsoft Foundry)" (S-A2). Customers may configure their own keys "provided the resulting usage is billed to the key owner" (S-A2). The Commercial Terms govern (S-A3).
- **Not allowed:** paying for, reselling or intermediating usage on the user's behalf (S-A2).
- **Recommended (decided):** support it alongside the user's own signed-in `claude` (Q1); neither is the default. The user enters an `ANTHROPIC_API_KEY`, or configures Bedrock, Vertex or Foundry. Majula stores the key locally for that user only, with the same atomic-rename store pattern, and never proxies one user's key for another.

### Q3. Majula's own login flow

- **(i) Majula's own OAuth client against claude.ai: not allowed.** "Anthropic does not permit third-party developers to offer Claude.ai login into their own applications … sign-in to a Claude account must complete through Anthropic's own flow" (S-A2, and S-A1).
- **(ii) Relaying the CLI's own login (what `claude-login.ts` does today): unclear.** Sign-in does finish in Anthropic's own flow, and the user is signing in to the unmodified binary, which S-A2 allows. But Majula would carry the auth URL and the pasted code between devices. That is arguably to "intermediate Claude.ai credentials or session tokens" (S-A2), and it is arguably to "offer claude.ai login" in a product (S-A1). The sources don't say whether a one-time authorization code counts as a credential.
- **Recommended (decided):** Majula has no Claude login of its own and doesn't port the pty relay. Setup tells the user to run `claude auth login` themselves in a terminal on the server machine, or over SSH from another device (e.g. Tailscale SSH from a phone), and Majula only detects the result with `claude auth status`, never reading credentials.

### Q4. Reading usage limits

- **Not allowed (Outpost's current method):** `usage-poller.ts` reads the claude.ai OAuth token from the Keychain and calls the undocumented `api/oauth/usage`. That is a developer collecting a "Claude.ai … session token" (S-A2) and arguably to "offer … rate limits" (S-A1). It is not documented anywhere I found.
- **Documented but unclear for a third party:** Claude Code itself reports the 5-hour and 7-day windows in three places: the status-line JSON (S-A4), the SDK's experimental `usage_report` from `/usage`, and `SDKRateLimitEvent` (S-A4). These come out of the session Majula already runs, so no token handling is needed. It is unclear whether S-A1's "offer … rate limits" means _letting users spend plan quota in your product_ or also _displaying_ plan limits. It is probably the former, but I am not inferring it.
- **Recommended (decided):**
  - Delete the direct `api/oauth/usage` call and the Keychain read from Majula's design.
  - For subscription sessions, read only the `rate_limit_event` / `usage_report` data the SDK emits in sessions Majula already runs. Persist the latest value for each window (utilization, `resetsAt`, observed-at), and update it from every Claude session.
  - While idle, headroom works from that last-seen value. Once a window's `resetsAt` passes, treat that window as reset rather than stale. The UI shows when the value was observed.
  - For API-key users, headroom is not a plan concept, so use cost tracking instead (`total_cost_usd`).
  - Usage is a per-runtime capability: Claude (last-seen SDK data) and Codex (`account/rateLimits/read`) feed the spare-token trigger (roadmap 4.9); Cursor and Gemini don't.

### Q5. Redistribution, licenses and branding

- **SDK license:** proprietary ("All rights reserved"), with use under the Commercial Terms (S-A1, S-A5). An Apache-2.0 repo can _declare_ a dependency on it, because the source code doesn't contain it, but Majula cannot relicense or vendor it. **Unclear:** whether every Majula user must accept the Commercial Terms because the server uses the SDK, even when they sign in with a subscription. S-A2 says the Consumer Terms govern Pro/Max users of Claude Code. Team and Enterprise users are under the Commercial Terms either way.
  **Recommended (decided):** don't pick for the user. Majula's docs say "Using the Claude runtime is subject to your agreement with Anthropic."
- **Bundling conflict (important):** the SDK npm package pulls in the native Claude Code binary as an optional dependency (S-A5). A Homebrew formula or bottle that runs `npm install` with the SDK would therefore _ship Claude Code_. That contradicts the "never bundle" decision and falls under "preinstalling or running Claude Code in your products" (S-A2), which requires the Commercial Terms and an unmodified binary.
  **Recommended (decided):** install with optional dependencies omitted (`--omit=optional`), and always set `pathToClaudeCodeExecutable` to the `claude` that Majula detected on the user's machine (documented in S-A5). Add a CI check that no `@anthropic-ai/claude-agent-sdk-<platform>` package ends up in the bottle. Load the SDK lazily, only once a `claude` binary is detected, so users who never use Claude never touch it.
- **Branding:**
  - Allowed: "Claude Agent", "Claude" inside an "Agents" menu, "Majula … Powered by Claude", and plain-text accurate statements such as "runs Claude Code" (S-A1, S-A2).
  - Not allowed: "Claude Code" or "Claude Code Agent" as a label, Claude Code look-alike art, Anthropic or Claude marks in Majula's name or logo, implied endorsement, and any logo use without written permission (S-A1, S-A2, S-A6).
  - **Recommended:** the runtime picker says "Claude Agent". Docs say "Majula can run Claude Code (installed separately) …". Use no Anthropic logos.

---

## OpenAI Codex (`codex app-server`)

### Sources (quoted)

**S-O1. Codex App Server**, https://developers.openai.com/codex/app-server (read 2026-11-25):

> "Codex app-server is the interface Codex uses to power rich clients (for example, the Codex VS Code extension). Use it when you want a deep integration inside your own product: authentication, conversation history, approvals, and streamed agent events. The app-server implementation is open source in the Codex GitHub repository"

> "**API key (`apikey`)** - the caller supplies an OpenAI API key with `type: "apiKey"`, and Codex stores it for API requests.
> **ChatGPT managed (`chatgpt`)** - Codex owns the ChatGPT OAuth flow, persists tokens, and refreshes them automatically. Start with `type: "chatgpt"` for the browser flow or `type: "chatgptDeviceCode"` for the device-code flow.
> **ChatGPT external tokens (`chatgptAuthTokens`)** - experimental and intended for host apps that already own the user's ChatGPT auth lifecycle. The host app supplies an `accessToken`, `chatgptAccountId`, and optional `chatgptPlanType` directly, and must refresh the token when asked."

> "`account/rateLimits/read` - fetch ChatGPT rate limits. · `account/rateLimits/updated` (notify) - emitted whenever a user's ChatGPT rate limits change."

The `account/rateLimits/read` response example returns `primary: { "usedPercent", "windowDurationMins", "resetsAt" }` for each `limitId`.

**S-O2. Sign in with ChatGPT: ChatGPT plan usage for open-source apps.**

https://developers.openai.com/siwc/token-sharing-open-source (read 2026-11-25):

> "ChatGPT plan usage is an optional capability within Sign in with ChatGPT. In addition to identity scopes, your open-source app can request permission to use the user's ChatGPT plan for eligible Responses API requests."
> "_These docs explain ChatGPT plan usage for open-source and locally hosted apps. If you're interested in offering it in a paid or remotely hosted app, complete the interest form._"

https://developers.openai.com/siwc/token-sharing-open-source/sign-in:

> "Start first-time registration with `client_id=dynamic_agent_client`, include the host's `ext_agent_host_id`, and set `agent_name_hint` to your app's actual name … This direct flow needs neither a client secret nor a partner API key."
> `redirect_uri`: "Use an HTTP loopback callback on `127.0.0.1` … Do not substitute with `localhost`."
> "show a Sign in with ChatGPT button labeled **Continue with ChatGPT**, following the UI/UX Guidelines for approved OpenAI branding."

https://developers.openai.com/siwc/request-client-id:

> "Sign in with ChatGPT is currently offered to a select group of commercial partners. To join the waitlist, complete the Sign in with ChatGPT interest form."

https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server:

> "If your app uses Codex app-server, configure it to send inference requests to the Responses API using an OAuth access token authorized for the user's ChatGPT plan." … "Codex uses this [`clientInfo.name`] as the request originator for attribution."

https://developers.openai.com/siwc/token-sharing-open-source/self-hosted-vms:

> "A `127.0.0.1` callback reaches the computer running the browser, not the remote VM. Complete OAuth locally with the same tool/client for the same user and workspace you will use on the VM." … "Transfer the selected registration's protected credential file to the tool's documented VM path over a secure channel such as SSH." … "Host-specific usage attribution and revocation of ChatGPT plan access for transferred sessions are not yet available."

https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations:

> "These limits apply to ChatGPT plan usage through Sign in with ChatGPT and `https://api.openai.com/v1`, both directly and through Codex app-server." It also lists unsupported tools: "Image generation, file search, Code Interpreter, native computer use, hosted MCP/connectors, and Responses `tool_search`."

https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions:

> "Link from your tool's usage-tracking pages to ChatGPT Settings → Usage, where users can review app usage and manage each app's access to their ChatGPT plan and credits."
> "For ChatGPT Plus users, the five-hour usage limit is shared across all apps where they use their ChatGPT plan, including private and open-source clients."

https://developers.openai.com/siwc/ui-ux-guidelines:

> "When requests use the user's ChatGPT plan, display **Using ChatGPT plan** near the composer or model selector. Include a **Manage usage** link to ChatGPT usage settings"
> "When your app receives a usage-limit error, direct the user to ChatGPT usage settings."

**S-O3. Codex auth**, https://developers.openai.com/codex/auth (read 2026-11-25):

> "Sign in with ChatGPT for subscription access · Sign in with an API key for usage-based access"
> "When you sign in with ChatGPT … the sign-in flow opens a browser window. After you sign in, the browser returns your credentials to Codex."

**S-O4. OpenAI Terms of Use**, https://openai.com/policies/terms-of-use/ (read 2026-11-25; the page served "Effective: January 1, 2026" and links to the `row-terms-of-use` revisions, so this may be the rest-of-world variant):

> "You may not share your account credentials or make your account available to anyone else and are responsible for all activities that occur under your account."
> Prohibited: "Automatically or programmatically extract data or Output (defined below)."

**S-O5. License:** https://github.com/openai/codex/blob/main/LICENSE is Apache License 2.0.

**S-O6. OpenAI brand guidelines**, https://openai.com/brand/ (read 2026-11-25):

> Don't: "Misrepresent your relationship with OpenAI, imply endorsement, or confuse users about sponsorship."
> "We do not permit model names in app titles because there is concern that it confuses end users."
> "If your project leverages our APIs or models … you may choose to reference a specific model but be precise and accurate."

### Q1. Drive a Codex CLI signed in with a ChatGPT plan

- **Allowed:** app-server is documented for "a deep integration inside your own product", including a ChatGPT-managed auth mode where "Codex owns the ChatGPT OAuth flow, persists tokens" (S-O1). Majula never sees the token.
- **Not allowed:** sharing credentials or making the account available to others (S-O4). Majula must not let one user's Codex login serve someone else.
- **Unclear:** S-O4's "Automatically or programmatically extract data or Output" is aimed at scraping, and app-server is OpenAI's own programmatic surface, so I read no conflict. Strictly, though, the terms don't carve app-server out.
- **Recommended (decided):** support it. Spawn the user's installed `codex app-server`, which uses its own `~/.codex` login, and send a stable `clientInfo.name` such as `majula` (S-O2 says this is used "for attribution").

### Q2. API keys

- **Allowed:** `account/login/start` with `type: "apiKey"` (S-O1), and "Sign in with an API key for usage-based access" (S-O3).
- **Recommended:** support it as an alternative.

### Q3. Majula's own login flow

- **(i) Majula's own OAuth client: allowed, in preview.** Sign in with ChatGPT documents a no-secret dynamic registration (`dynamic_agent_client`) for "open-source and locally hosted apps" and a Codex app-server recipe (S-O2). Its conditions:
  - a persisted `ext_agent_host_id` for each host
  - a `127.0.0.1` loopback redirect
  - "Continue with ChatGPT" branding plus the usage UI ("Using ChatGPT plan", "Manage usage")
  - the Responses-API limitations of the preview
  - **Unclear:** two things conflict. The request-client-id page says SIWC "is currently offered to a select group of commercial partners". The phone/remote case also needs the browser on the same machine as the callback; the documented answer for a remote host is "complete OAuth locally … transfer the protected credential file", with "revocation … for transferred sessions … not yet available".
- **(ii) Relaying the CLI's own login: allowed.** app-server exposes `type: "chatgptDeviceCode"` for clients (S-O1). That is the documented equivalent of today's `codex login --device-auth`, so the user completes the device-code step on any device.
- **Recommended (decided):** ship (ii), through app-server's `account/login/start` `chatgptDeviceCode` rather than a pty. Codex owns the flow and the tokens; Majula only shows the code and URL. This is consistent with cross-cutting rule 6 because the login is the provider's own, documented for client apps. Don't build (i).

### Q4. Usage limits

- **Allowed:** `account/rateLimits/read` and the `account/rateLimits/updated` notification are documented (S-O1). SIWC also asks apps to link to `chatgpt.com/settings/usage` (S-O2).
- **Recommended:** read limits only through app-server, and add a "Manage usage" link. Codex can feed the headroom trigger. Note that Plus 5-hour limits are shared across all apps (S-O2).

### Q5. Redistribution and branding

- Codex is Apache-2.0 (S-O5). Majula may detect Codex; bundling would be legally possible but isn't planned.
- **Branding:** no model names in Majula's title, and no implied endorsement (S-O6). For SIWC, use only the approved "Continue with ChatGPT" button formats (S-O2).
- **Recommended:** the runtime label is "Codex" in plain text, used descriptively. Use no OpenAI logos except the approved SIWC button, if (i) ships.

---

## Cursor (`agent acp`)

### Sources (quoted)

**S-C1. ACP**, https://cursor.com/docs/cli/acp (read 2026-11-25):

> "Cursor CLI supports **ACP (Agent Client Protocol)** for advanced integrations. You can run `agent acp` and connect a custom client over `stdio` using JSON-RPC."
> "ACP is intended for building custom clients and integrations."
> "Cursor CLI advertises `cursor_login` as the ACP auth method. In practice, you can pre-authenticate before startup using existing CLI auth paths: `agent login` · `--api-key` (or `CURSOR_API_KEY`) · `--auth-token` (or `CURSOR_AUTH_TOKEN`)"

The page says nothing about usage or rate limits.

**S-C2. Authentication**, https://cursor.com/docs/cli/reference/authentication (read 2026-11-25):

> "Cursor CLI supports two authentication methods: browser-based login (recommended) and API keys."
> "The login command opens your default browser and prompts you to authenticate with your Cursor account. Set `NO_OPEN_BROWSER=1` to print the login URL without opening a browser. Once complete, your credentials are securely stored locally."
> "For automation, scripts, or CI environments, use API key authentication … Generate a user API key from Cursor Dashboard → API Keys."

**S-C3. Terms of Service**, https://cursor.com/terms-of-service (read 2026-11-25; "Last updated September 3, 2026"):

> "you may not: (i) reverse engineer, disassemble, decompile, decode, or otherwise attempt to derive or gain access to the source code, object code or underlying structure of the Service; (ii) reproduce, modify, translate, or create derivative works of the Service; (iii) rent, lease, lend, or sell the Service; … (viii) harvest, scrape, or extract data from the Service; … (xi) knowingly permit any third party to do any of the foregoing."

I found no clause on account or credential sharing, and none on third-party clients.

**S-C4. API overview**, https://cursor.com/docs/api (read 2026-11-25): the Admin API ("Manage team members, settings, usage data, spending…") and the Analytics API are both listed with availability "Enterprise teams".

**S-C5. Brand:** I couldn't check a Cursor brand page; the fetch was blocked by this action's allowlist. **No source.**

### Q1. Drive a CLI signed in with a Cursor plan

- **Allowed:** ACP "is intended for building custom clients and integrations", with `agent login` as a documented pre-auth path (S-C1).
- **Unclear:** the terms say nothing about third-party clients either way.
- **Recommended (decided):** support it. Spawn the user's `agent acp`, and answer `session/request_permission` through Majula's gate.

### Q2. API keys

- **Allowed:** a user API key through `CURSOR_API_KEY` or `--api-key` (S-C1, S-C2). Cursor positions it "for automation, scripts, or CI".
- **Recommended:** support it, and pass the key through the environment, not argv.

### Q3. Majula's own login flow

- **(i) Own OAuth client:** no third-party OAuth program is documented. Treat it as **not available**; don't build one.
- **(ii) Relaying the CLI's login:** the CLI documents `NO_OPEN_BROWSER=1 agent login` to print the URL (S-C2), and ACP advertises `authenticate` with `cursor_login` (S-C1). Showing that URL on another device is a documented mechanism, but **unclear** as a sanctioned third-party practice; nothing addresses it.
- **Recommended (decided):** use the ACP `authenticate` (`cursor_login`) method when the agent advertises it, so the CLI runs its own flow. Otherwise the user runs `agent login` at a terminal. No `NO_OPEN_BROWSER` relay. Majula never reads Cursor's stored credentials.

### Q4. Usage limits

- **No sanctioned source for individual users.** The Admin and Analytics usage APIs are for "Enterprise teams" (S-C4), and ACP documents no usage data (S-C1).
- **Not allowed:** pulling usage out of Cursor's CLI internals. The terms bar reverse engineering and "extract data from the Service" (S-C3). Note: an earlier Outpost investigation ran `rg` over the `cursor-agent` bundle JS; Majula must not depend on anything learned that way.
- **Recommended:** don't build Cursor usage tracking. Exclude Cursor from the headroom trigger.

### Q5. Redistribution and branding

- The CLI is proprietary, and the terms forbid "reproduce … rent, lease, lend, or sell the Service" (S-C3). **Never bundle it**; detect `agent` only.
- Branding: no source checked (S-C5). **Recommended:** plain-text "Cursor" as a descriptive label, no logo.

---

## Generic ACP agents (e.g. Gemini CLI)

### Sources (quoted)

**S-G1. Gemini CLI: License, Terms of Service, and Privacy Notices**, https://github.com/google-gemini/gemini-cli/blob/main/docs/resources/tos-privacy.md (main branch, read 2026-11-25):

> "Gemini CLI software is licensed under the Apache 2.0 license. When you use Gemini CLI to access or use Google's services, the Terms of Service and Privacy Notices applicable to those services apply to such access and use."

> "Directly accessing the services powering Gemini CLI (for example, the Gemini Code Assist service) using third-party software, tools, or services (for example, using OpenClaw with Gemini CLI OAuth) is a violation of applicable terms and policies. Such actions may be grounds for suspension or termination of your account."

> "Supported authentication methods include: Logging in with your Google account to Gemini Code Assist. · Using an API key with Gemini Developer API. · Using an API key with Vertex AI GenAI API."

**S-G2. ACP Mode**, https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/acp-mode.md (main, read 2026-11-25):

> "ACP (Agent Client Protocol) mode is a special operational mode of Gemini CLI designed for programmatic control, primarily for IDE and other developer tool integrations."

It lists `authenticate: Authenticates the user.` among the ACP methods.

**S-G3. Quotas and pricing**, https://github.com/google-gemini/gemini-cli/blob/main/docs/resources/quota-and-pricing.md: it describes the quota tiers. I found no programmatic way for a client to read remaining quota.

**S-G4. ACP license**, https://github.com/agentclientprotocol/agent-client-protocol/blob/main/LICENSE: Apache License 2.0.

### Answers (Gemini CLI)

**Q1. Allowed, through the unmodified CLI's ACP mode only.** ACP mode is "designed for programmatic control, primarily for IDE and other developer tool integrations" (S-G2). The explicit ban is on _third-party software directly accessing_ the backing services with Gemini CLI OAuth (S-G1).

- **Unclear:** whether a non-IDE, self-hosted runner that triggers autonomous runs is still the kind of "developer tool integration" Google intends.
- **Recommended (decided):** support it through `gemini --acp` only. Never read `~/.gemini` OAuth credentials and never call Code Assist directly.

**Q2. Allowed.** Gemini API key and Vertex AI are supported methods (S-G1). The Gemini API or GCP terms govern, depending on the key.

**Q3. (i) Not allowed.** Using the Gemini CLI OAuth from third-party software is "a violation" (S-G1). **(ii) Unclear.** Relaying the CLI's own `authenticate` flow through ACP keeps the CLI as the client, but no source covers a remote device.

- **Recommended (decided):** use only the ACP `authenticate` method the agent advertises; otherwise the user signs in at a terminal. Never handle tokens.

**Q4. No documented programmatic quota source** (S-G3). **Recommended:** none; exclude it from headroom.

**Q5. Apache-2.0** (S-G1). Google/Gemini brand rules were **not researched** in this pass, so make no claims and use plain-text names only.

### Generic ACP: recommended policy

- The protocol is Apache-2.0 (S-G4), but **each agent's own terms govern its credentials**.
- Majula should run only ACP agents on a vetted list. Each entry records:
  - the agent's governing terms URL
  - its allowed auth modes
  - whether it has a usage source
- An unvetted ACP agent can be run only with API-key authentication, or not at all.
- In every case: use only the agent's advertised ACP `authenticate` method, never read an agent's credential files, and never call a backing service directly.

---

## Cross-cutting rules for Majula (applies to every runtime)

1. Never read, copy, store or forward a provider's _consumer_ OAuth or session token. That rules out the Keychain read in `claude-credentials.ts`, `~/.codex`, `~/.gemini` and Cursor's stored credentials.
2. Never bundle a CLI binary. That includes the Claude Code binary that rides in on the Agent SDK's optional dependencies. Always point at the detected install.
3. One user's credential serves only that user. There is no shared server login.
4. Branding stays descriptive and plain-text (see each runtime's Q5): no provider logos, and no provider names in Majula's own name.
5. No runtime is required. Every runtime is optional and detected; Majula's core never assumes Claude.
6. Majula ships no embedded provider login for consumer subscriptions. The user signs in to each CLI through that CLI's own flow. Majula may surface a CLI's login only where the provider documents that for client apps (today: Codex app-server's `chatgptDeviceCode`). For remote sign-in, setup docs tell the user to SSH to the server (e.g. Tailscale SSH) and run the CLI's own login command.

## Accepted residual risk

No provider is being asked; this is a small open-source project. These are the points the sources leave unclear, accepted under the decisions above:

- **Claude:** S-A1's "unless previously approved … including agents built on the Claude Agent SDK" may cover driving a subscription-signed-in `claude`. Whether displaying SDK-emitted usage counts as offering "rate limits" is also unclear (Q4).
- **Codex:** the Terms of Use ban on programmatically extracting Output doesn't carve out app-server, OpenAI's own programmatic surface (Q1).
- **Cursor:** the terms are silent on third-party clients and unattended runs (Q1). There's no usage source for non-Enterprise users, so Cursor stays out of headroom. No brand page was checked.
- **Gemini CLI:** whether a self-hosted runner with scheduled runs is a "developer tool integration" (Q1). ACP `authenticate` from a remote device is uncovered (Q3). Brand rules weren't researched.

## Caveats

- **Not fetched:** the Anthropic Commercial Terms full text, the Anthropic Usage Policy, Cursor's brand page (blocked by this action's allowlist), Google/Gemini brand rules, the Gemini API Additional Terms and the Google One terms. The answers don't depend on them, but the branding answers for Cursor and Gemini are unsourced.
- The OpenAI Terms page served what looks like the rest-of-world variant (it links to `row-terms-of-use` revisions). The US terms may differ in wording.
- The "Agent SDK credit" (June 15, 2026) came from a search snippet and was not found in the docs I read. It is unverified.
- Docs change; the Sign in with ChatGPT open-source flow is labelled preview. Re-check every quote before relying on it after 2026-11-25.

## Sources

All read 2026-11-25. Quotes are in each runtime's Sources section above.

| Id   | Source                                                                                                                                                                                                                                                                                          |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| S-A1 | https://code.claude.com/docs/en/agent-sdk/overview                                                                                                                                                                                                                                              |
| S-A2 | https://code.claude.com/docs/en/legal-and-compliance                                                                                                                                                                                                                                            |
| S-A3 | https://www.anthropic.com/legal/consumer-terms                                                                                                                                                                                                                                                  |
| S-A4 | https://code.claude.com/docs/en/statusline · https://code.claude.com/docs/en/agent-sdk/typescript                                                                                                                                                                                               |
| S-A5 | https://raw.githubusercontent.com/anthropics/claude-agent-sdk-typescript/main/LICENSE.md · https://raw.githubusercontent.com/anthropics/claude-code/main/LICENSE.md · npm `@anthropic-ai/claude-agent-sdk@0.3.332`                                                                              |
| S-A6 | https://www.anthropic.com/legal/trademark-guidelines                                                                                                                                                                                                                                            |
| S-O1 | https://developers.openai.com/codex/app-server                                                                                                                                                                                                                                                  |
| S-O2 | https://developers.openai.com/siwc/token-sharing-open-source (and its `/sign-in`, `/codex-app-server`, `/self-hosted-vms`, `/preview-limitations`, `/profiles-and-sessions` pages) · https://developers.openai.com/siwc/request-client-id · https://developers.openai.com/siwc/ui-ux-guidelines |
| S-O3 | https://developers.openai.com/codex/auth                                                                                                                                                                                                                                                        |
| S-O4 | https://openai.com/policies/terms-of-use/                                                                                                                                                                                                                                                       |
| S-O5 | https://github.com/openai/codex/blob/main/LICENSE                                                                                                                                                                                                                                               |
| S-O6 | https://openai.com/brand/                                                                                                                                                                                                                                                                       |
| S-C1 | https://cursor.com/docs/cli/acp                                                                                                                                                                                                                                                                 |
| S-C2 | https://cursor.com/docs/cli/reference/authentication                                                                                                                                                                                                                                            |
| S-C3 | https://cursor.com/terms-of-service                                                                                                                                                                                                                                                             |
| S-C4 | https://cursor.com/docs/api                                                                                                                                                                                                                                                                     |
| S-G1 | https://github.com/google-gemini/gemini-cli/blob/main/docs/resources/tos-privacy.md                                                                                                                                                                                                             |
| S-G2 | https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/acp-mode.md                                                                                                                                                                                                                      |
| S-G3 | https://github.com/google-gemini/gemini-cli/blob/main/docs/resources/quota-and-pricing.md                                                                                                                                                                                                       |
| S-G4 | https://github.com/agentclientprotocol/agent-client-protocol/blob/main/LICENSE                                                                                                                                                                                                                  |

Outpost code the recommendations change (as of 2026-11-25):

- `src/integrations/usage-poller.ts:18`: reads Claude usage from the undocumented `api.anthropic.com/api/oauth/usage` with the CLI's OAuth token
- `src/integrations/claude-login.ts:14`: relays `claude auth login` through a pty to the user's device
- `src/integrations/runtime-login.ts:34`: relays `codex login --device-auth` and Cursor's `agent login`
- The roadmap's Decisions rows "Open source" and "Agent credentials": all repos public, CLIs never bundled, users bring their own auth, job 1.3 gates the login and usage code
