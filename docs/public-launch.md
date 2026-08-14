# Taking a node public

Going from a working `--local-only` node to one serving a real domain. Written
after doing it for `us-ca` on 2026-08-13, and organised around the things that
went wrong rather than the happy path — every failure below was found by
hitting it, because **none of them fail loudly**.

The through-line: a node in this state boots healthy, passes every health
check, and is still unusable. `docker ps` showing all-green tells you nothing
about whether a human can log in.

## What you need before starting

- The node running and healthy on its tunnel.
- A Cloudflare zone for your domain on the same account as the tunnel.
- Two names decided: the app host (`app-<region>.<domain>`) and the auth host
  (`auth-<region>.<domain>`).

## 1. Cloudflare — two entries, two different places

These are easy to conflate. They are configured in different products and only
one of them lives in git.

**Auth (Kong) — a Tunnel public hostname.** Zero Trust → Networks → Tunnels →
your tunnel → Public Hostname → Add.

| Field | Value |
|---|---|
| Subdomain | `auth-<region>` |
| Domain | your zone |
| Path | *(empty)* |
| Type | `HTTP` |
| URL | `opuspopuli-supabase-kong:8000` |

`Type: HTTP` is right even though the public side is HTTPS — Cloudflare
terminates TLS at the edge and speaks plain HTTP to Kong over the Docker
network. The URL field takes `host:port`, no scheme.

**App (frontend) — a Workers custom domain, NOT a tunnel hostname.** It is
declared in `apps/frontend/wrangler.toml` in the monorepo and created by the
deploy — normally `deploy-frontend.yml` firing on a `frontend-v*` tag, or
`pnpm cf:deploy` if you are using the break-glass path:

```toml
[[routes]]
pattern = "app-<region>.<domain>"
custom_domain = true
```

Cloudflare creates and owns that DNS record. Do not also add a CNAME by hand —
it conflicts.

> Declaring any route **disables `workers.dev`** unless you also set
> `workers_dev = true`. That is usually what you want: the `workers.dev` origin
> won't be in `ALLOWED_ORIGINS`, so it is a second public URL that cannot reach
> your API.

### The tunnel hostname added by hand is not safe forever

`infra/cloudflare/tunnel.tf` declares the tunnel's ingress in Terraform:

```hcl
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "api" {
  config {
    ingress_rule { hostname = local.api_hostname  service = "http://..." }
    ingress_rule { service  = "http_status:404" }   # catch-all
  }
}
```

Terraform owns that resource **whole**. It is not a merge — an apply reconciles
the tunnel to exactly the rules listed, so a hostname added through the
dashboard is silently deleted and auth stops working.

Today nothing applies: only `environments/prod.tfvars.example` exists, so the
`cloudflare-infra` workflow (triggered by `infra/cloudflare/**` and pushes to
`main`) has no real variables to run against. The us-ca tunnel was created by
`create-op-node bootstrap`, not Terraform.

So this is a **trap, not a live problem** — it springs the first time someone
creates a real `prod.tfvars` and applies, which is exactly when nobody is
thinking about auth. If you adopt Terraform for a node, add the auth ingress
rule to `tunnel.tf` *before* the first apply:

```hcl
ingress_rule {
  hostname = "auth-${var.region}.${var.domain_name}"
  service  = "http://opuspopuli-supabase-kong:8000"
}
```

Ordering matters — the catch-all `http_status:404` must stay last.

## 2. Node `.env`

See `.env.example` for the full commentary. The minimum:

```bash
SITE_URL=https://app-<region>.<domain>
ADDITIONAL_REDIRECT_URLS=https://app-<region>.<domain>/**,http://localhost:3200/**
SUPABASE_URL=https://auth-<region>.<domain>
ALLOWED_ORIGINS=https://app-<region>.<domain>
COOKIE_DOMAIN=.<domain>
CSRF_COOKIE_DOMAIN=.<domain>
WEBAUTHN_RP_ID=<domain>
WEBAUTHN_ORIGIN=https://app-<region>.<domain>
```

**Order matters.** Set `SUPABASE_URL` to the public host only *after* step 1's
tunnel hostname resolves. Between the two, the running containers still hold
the old value so nothing is broken — but the next `up -d` picks up an
unresolvable Supabase URL and takes down *all* auth, not just magic links.

Then restart. Note the `-f`; `op-compose` hydrates Keychain secrets and execs
`docker compose "$@"`, it does not inject a compose file:

```bash
./bin/op-compose -f docker-compose-prod.yml up -d --force-recreate \
  supabase-auth api users
```

`api` and `users` need it too, not just `supabase-auth` — they read
`SUPABASE_URL`, and `users` reads the WebAuthn pair.

## 3. Verify — in this order

Each step isolates one layer. Skipping to "click a link in my email" makes a
failure at any layer look identical.

```bash
# DNS exists. Query the AUTHORITATIVE server: your resolver has probably
# cached NXDOMAIN from before the record existed, for up to 1800s.
dig +short @<zone-ns>.ns.cloudflare.com auth-<region>.<domain>

# Kong is answering through the tunnel. 401 "No API key found" is CORRECT --
# it proves Kong is reachable and enforcing key-auth. 502/530 means cloudflared
# resolved the name but could not reach Kong (usually a Docker network mismatch).
curl -s -o /dev/null -w '%{http_code}\n' https://auth-<region>.<domain>/auth/v1/health

# The magic-link endpoint is OPEN (Supabase exempts it from key-auth).
# Expect 400 bare, 303 with a token. A 401 here means the exemption is missing.
curl -s -o /dev/null -w '%{http_code}\n' https://auth-<region>.<domain>/auth/v1/verify

# The single highest-value check: where does GoTrue actually redirect?
# A deliberately bogus token still reveals the host. Read the HOST, not the
# error -- #error=otp_expired is expected.
curl -s -D - -o /dev/null \
  "https://auth-<region>.<domain>/auth/v1/verify?token=bogus&type=magiclink&redirect_to=https://app-<region>.<domain>" \
  | grep -i '^location'

# CORS from the app origin to the API. Needs allow-origin AND allow-credentials.
curl -s -D - -o /dev/null -X OPTIONS https://api-<region>.<domain>/api \
  -H "Origin: https://app-<region>.<domain>" \
  -H "Access-Control-Request-Method: POST" | grep -i access-control

# The app itself.
curl -s -o /dev/null -w '%{http_code}\n' https://app-<region>.<domain>
```

If the `location` line still shows `localhost`, the containers are running the
**old** environment — the `.env` edit landed but the restart did not.

Finally, request a real magic link and sign in. Nothing above exercises the
cookie-domain or CSRF path; only a real login does.

## Failure modes, and what they look like

| Symptom | Cause |
|---|---|
| Link host is an internal name | `SUPABASE_URL` still internal |
| Link redirects to `localhost:3000` | `SITE_URL` unset — falls back to the compose default |
| App's own `redirect_to` ignored | Not in `ADDITIONAL_REDIRECT_URLS`; GoTrue substitutes `SITE_URL` silently |
| Login succeeds, session doesn't stick | `COOKIE_DOMAIN` / `CSRF_COOKIE_DOMAIN` unset — cookies are host-only |
| Login loop | Only one of the two cookie-domain vars set |
| `users` crash-loops on boot | `WEBAUTHN_RP_ID` unset while `NODE_ENV=production` |
| Node won't boot after setting origins | Production mode requires every `ALLOWED_ORIGINS` entry to be `https://` |
| Host "doesn't resolve" but is live | Your resolver cached NXDOMAIN. Check authoritative before believing it |

## Don't trust your own resolver

Repeatedly cost time on 2026-08-13. Probing a hostname *before* creating it
caches NXDOMAIN for up to 1800 seconds — on your machine, your router, and
anything else that saw the query. The site is then live and unreachable from
exactly the network you are testing from, including a phone on the same Wi-Fi.

Confirm against the authoritative nameserver, or bypass DNS entirely:

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  --resolve app-<region>.<domain>:443:<cloudflare-ip> \
  https://app-<region>.<domain>
```

## Known gaps

- **No startup validation.** A node with `SITE_URL` unset boots healthy and
  emails dead links. Making production mode fail fast on a localhost default —
  as the CORS validator already does for non-https origins — is
  opuspopuli-node#51.
- **`SUPABASE_URL` is overloaded**, serving as both the public link host and
  the internal service URL. Public means backend→Supabase calls hairpin through
  Cloudflare. Split tracked as OpusPopuli/opuspopuli#1005.
- **`create-op-node` does not write these**, so a fresh node reproduces every
  failure above. Also opuspopuli-node#51.
