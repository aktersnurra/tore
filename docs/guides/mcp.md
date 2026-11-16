# Using Tore from Claude (MCP)

Tore is an MCP server at `https://<PHX_HOST>/mcp`. Claude signs in through Pocket ID: Pocket ID
issues the token, Tore only checks it. Everything Claude does goes through the same checks and
undo as the app, and nothing it does uses the server's own model, so a household without AI
(nobody sponsors it) can still plan, shop and save recipes this way, on the person's own Claude
plan. Design: `.docs/specs/mcp.md`; the same setup as BurpeeTrainer's (`docs/guides/mcp-setup.md`
there).

## Pocket ID

The groups are the ones login already uses:

| Group | Members | Custom claim |
|---|---|---|
| `tore` | everyone who may use Tore | none |
| `tore-ai` | whoever may let a household use the server's AI | `tore_ai` = `true` |

MCP needs no group of its own, and Claude no client of its own: it registers itself through a
Client ID Metadata Document (CIMD), per API.

1. Admin → **APIs** → create an API. Resource: `https://<PHX_HOST>/mcp`, no trailing slash. It
   can't be changed later and must be exactly what Tore publishes.
2. No permissions: Tore checks none, and every tool is open to any signed-in member.
3. That API → **Access** → *Metadata document clients* → "Allow all metadata document
   clients". The allowlist of Claude's and OpenAI's URLs is global (Application Configuration)
   and is already there.
4. Record the API in `nuc/apps/pocketid/apis.md` in nuc-setup.

A token is only accepted for someone who has signed in to the app once, which is when their
household is made; the app's client allows only `tore`.

## Tore

| Variable | Value |
|---|---|
| `MCP_OIDC_AUDIENCE` | the API's resource, `https://<PHX_HOST>/mcp`. Unset: `/mcp` and its metadata are 404. |

`OIDC_ISSUER` is the one login already uses. A token's audience is that resource; when Claude
also asks for `openid`, Pocket ID adds the issuer as a second audience, which Tore allows, and
nothing else.

## Claude

- **claude.ai and the phone app:** Settings → Connectors → add a custom connector with URL
  `https://<PHX_HOST>/mcp`. Leave the client ID and secret empty; Claude registers itself.
- **Claude Code:** `claude mcp add --transport http tore https://<PHX_HOST>/mcp`, then `/mcp` to
  sign in.

Tools act on the household that's active in the app; switch it in Settings. Start a planning
conversation with the `plan_week` prompt. Claude reads `get_context` first: the household's
language, diet, memory, plan, list and pantry.

ChatGPT isn't tried yet.

## Check it

1. `curl https://<PHX_HOST>/.well-known/oauth-protected-resource` names `https://<PHX_HOST>/mcp`
   and the Pocket ID issuer.
2. `curl -i -X POST https://<PHX_HOST>/mcp` is a 401 with a `WWW-Authenticate` header pointing at
   that metadata.
3. In Claude, ask what's for dinner this week: it matches Plan.
4. Ask Claude to add milk to the list: it shows on Shop at once, and "undo" takes it off.
