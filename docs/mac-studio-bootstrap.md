# Mac Studio Bootstrap — From Sealed Box to Live

Step-by-step to take a Mac Studio from first boot to serving production traffic at `api.<your-domain>`.

## Placeholders to substitute

Replace these throughout the commands below with your region's values:

| Placeholder | Example | Where you decide it |
|---|---|---|
| `<your-domain>` | `civicfeed.tx`, `opuspopuli.org` | The domain you registered in Cloudflare |
| `<your-hostname>` | `opnode-prod-01`, `tx-civic-01` | Studio computer name, set in System Settings |
| `<your-account>` | `op`, `opuspopuli`, `node` | Local macOS account name (one account total) |
| `<your-region>` | `op-ca`, `tx`, `opuspopuli-prod` | Short label used as a prefix in 1Password notes + R2 bucket names |

The pgsodium key file path and LaunchAgent label use the stable `opuspopuli` platform identifier on every region — those don't change.

**Hardware:** Mac Studio M-series (M4 Max+ recommended), ≥ 64 GB unified RAM, ≥ 1 TB internal SSD + UPS.
**Account:** one local macOS account (you choose the name).
**Time estimate:**
- 5.5 h of step time (commands in sequence).
- **10–14 h realistic** with first-time friction (LaunchAgent timing, rclone config, first restore drill).
- **8–11 h to "live on the internet"** if Phase 10 observability is deferred.
- Calendar: long Saturday + Sunday end-to-end, OR 3–4 evenings (4 h each).

## Decisions

| Decision | Choice |
|---|---|
| Edge / TLS | Cloudflare Tunnel |
| Frontend | Cloudflare Pages (already deploys via `pnpm cf:deploy`) |
| Backend images | Built in GitHub Actions, pushed to `ghcr.io/opuspopuli/*`, Studio pulls — no local builds |
| Container runtime | Docker Desktop — see [`docker-resources.md`](./docker-resources.md) for the full memory / CPU / disk-image sizing table. **Never reduce the disk image size — set it large up front (300 GB recommended for a 1 TB Studio).** |
| Storage | Internal 1 TB SSD, Docker-managed named volumes |
| Supabase | Self-hosted on the Studio (no Supabase Cloud) |
| Email | Resend (DKIM on `<your-domain>`) |
| Backups | Nightly `pg_dump -Fc` → Cloudflare R2, 30-day retention |
| LLM | Local Ollama, `qwen3.5:9b` to start |
| FileVault | Off (Secure Enclave still encrypts the SSD; trade is unattended boot) |
| pgsodium key | 1Password `<your-region>-prod-pgsodium-root-key`, mirrored locally at `$HOME/.config/opuspopuli/pgsodium_root_key` mode 0400 |
| Out-of-band admin | Tailscale |

---

## Phase 1 — Workstation prep (≈ 1 h, no Studio needed)

Do these from your laptop today.

1. **Apply Cloudflare prod Terraform** — creates Tunnel, DNS (`api.`, `grafana.`), R2 bucket.
   ```bash
   cd infra/cloudflare
   terraform workspace select prod || terraform workspace new prod
   terraform apply -var-file=environments/prod.tfvars
   ```

2. **Capture Tunnel token to 1Password** as `<your-region>-prod-tunnel-token`.
   ```bash
   terraform output -raw tunnel_token
   ```

3. **R2 backup token** — Cloudflare dashboard → R2 → API tokens → scoped to `<your-region>-prod-db-backups`, Object Read+Write only. Save to 1Password.

4. **Verify DNS + TLS** (origin will 530 until Phase 9):
   ```bash
   dig api.<your-domain> +short          # CNAME to *.cfargotunnel.com
   curl -I https://api.<your-domain>     # HTTP/2 530
   ```

5. **Resend DKIM** — add SPF + DKIM records on `<your-domain>` per Resend dashboard. Test-send to your inbox.

6. **Generate the pgsodium master key** (on laptop, not Studio):
   ```bash
   set +o history
   head -c 32 /dev/urandom | od -A n -t x1 | tr -d ' \n'
   ```
   Save the 64-hex output to 1Password as `<your-region>-prod-pgsodium-root-key`.

---

## Phase 2 — Studio first-boot (≈ 30 min, at the Studio)

1. **Plug in:** power → Ethernet → display → USB keyboard.

2. **Setup Assistant:**
   - Apple ID: production account (not personal).
   - Account name: **`<your-account>`** (e.g. `op`, `node`, or whatever short name you picked above).
   - Skip Touch ID, Apple Pay, Siri, Screen Time, analytics.
   - **FileVault: OFF.**
   - Disable iCloud Drive / Photos / Mail / Contacts / Calendar.

3. **System Settings:**
   - General → Software Update → install all → Automatic: security responses **on**, macOS updates **off**.
   - Displays → Sleep: Never.
   - Energy → **Start up automatically after a power failure**.
   - Lock Screen → require password immediately.
   - Sharing → Remote Login (SSH) **on** (admin only); Screen Sharing **on** (admin only); File Sharing **off**; Computer Name **`<your-hostname>`**.
   - Users & Groups → Login Options → automatic login **off**.

4. **Verify:**
   ```bash
   hostname                              # <your-hostname>
   ipconfig getifaddr en0
   ping -c 1 1.1.1.1
   sudo pmset -g | grep autorestart      # autorestart  1
   ```

---

## Phase 3 — Dev tooling (≈ 45 min)

1. **Xcode CLI tools:**
   ```bash
   xcode-select --install
   ```

2. **Homebrew:**
   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```
   Run the PATH lines it prints.

3. **Core tools** (all MIT / Apache-2 — no GPL):
   ```bash
   brew install git gh pnpm jq cloudflared rclone
   brew install --cask docker tailscale
   ```

4. **Docker Desktop config** — open once from `/Applications`, accept EULA, then:
   - Settings → General → Start Docker Desktop when you sign in: **on**.
   - Settings → Resources → Memory: **40 GB**, CPU: all cores.
   - Settings → Resources → **Disk image size: 200 GB** (set this once and **never change it** — resizing wipes volumes).
   ```bash
   docker --version && docker compose version
   ```

5. **GitHub auth:**
   ```bash
   gh auth login
   gh repo view OpusPopuli/opuspopuli   # smoke test
   ```

6. **Tailscale** — sign in, accept Studio as a node, enable SSH. Verify from laptop:
   ```bash
   tailscale ssh <your-account>@<your-hostname>
   ```

7. **Ollama** (kick off downloads now, ~6 GB, comes back at Phase 7):
   ```bash
   brew install ollama
   brew services start ollama
   ollama pull qwen3.5:9b &
   ollama pull nomic-embed-text &
   ```

---

## Phase 4 — pgsodium key + LaunchAgent (≈ 20 min, load-bearing)

1. **Materialize the key file** from 1Password:
   ```bash
   set +o history
   mkdir -p $HOME/.config/opuspopuli
   chmod 700 $HOME/.config/opuspopuli
   printf '%s' '<paste-64-hex-from-1password>' > $HOME/.config/opuspopuli/pgsodium_root_key
   chmod 400 $HOME/.config/opuspopuli/pgsodium_root_key
   wc -c $HOME/.config/opuspopuli/pgsodium_root_key   # 64
   ```

2. **Author LaunchAgent** at `~/Library/LaunchAgents/org.opuspopuli.envloader.plist`:
   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
     <key>Label</key><string>org.opuspopuli.envloader</string>
     <key>ProgramArguments</key>
     <array>
       <string>/bin/sh</string>
       <string>-c</string>
       <string>launchctl setenv PGSODIUM_ROOT_KEY "$(cat $HOME/.config/opuspopuli/pgsodium_root_key)"; launchctl setenv TUNNEL_TOKEN "<paste-tunnel-token>"</string>
     </array>
     <key>RunAtLoad</key><true/>
   </dict>
   </plist>
   ```
   Load + verify:
   ```bash
   launchctl load ~/Library/LaunchAgents/org.opuspopuli.envloader.plist
   # Log out and back in, then in a fresh shell:
   echo ${PGSODIUM_ROOT_KEY:0:8}     # 8 hex chars
   echo ${TUNNEL_TOKEN:0:8}          # 8 chars
   ```

3. **Prepare operator-secret seed SQL** at `$HOME/.config/opuspopuli/seed-operator-vault.sql` (mode 0400, source values from 1Password). Used at Phase 8.3.
   ```sql
   SELECT vault_create_secret('<resend_key>',  'RESEND_API_KEY',   'Resend');
   SELECT vault_create_secret('<fec_key>',     'FEC_API_KEY',      'FEC');
   SELECT vault_create_secret('<r2_account>',  'R2_ACCOUNT_ID',    'R2 account');
   SELECT vault_create_secret('<r2_key>',      'R2_ACCESS_KEY_ID', 'R2 access');
   SELECT vault_create_secret('<r2_secret>',   'R2_SECRET_ACCESS_KEY', 'R2 secret');
   ```
   **Do not commit.**

---

## Phase 5 — Clone your node repo (≈ 5 min)

This Mac Studio is the host for one **node repo** — the repo you created from the `OpusPopuli/opuspopuli-node` template, customized with your region's tfvars and secrets. That repo holds the compose files, bind-mount sources, and bootstrap scripts the Studio uses. Backend + prompt-service images come from `ghcr.io/opuspopuli/*`; the Studio never builds.

```bash
mkdir -p $HOME/Development
cd $HOME/Development
gh repo clone <your-org>/opuspopuli-node-<region>
```

Then log in to ghcr.io so the next `docker compose pull` can authenticate:
```bash
gh auth token | docker login ghcr.io -u "$(gh api user --jq .login)" --password-stdin
```

> Note: if you've already run `scripts/mac-studio-setup.sh`, both of these are done — the script clones the node repo (if you ran it after a separate clone, it's a no-op) and logs in to ghcr.io for you.

---

## Phase 6 — Backup-restore drill (≈ 45 min, before any real data lands)

Rehearse recovery before there's anything worth recovering.

1. **Configure rclone for R2** at `~/.config/rclone/rclone.conf` (mode 0400) using the token from Phase 1.3.

2. **Stand up only the DB + seed a tiny fixture** (using the same prod compose; the rest of the stack stays down so we're rehearsing on a small surface).
   ```bash
   cd $HOME/Development/opuspopuli-node-<region>
   docker compose -f docker-compose-prod.yml up -d opuspopuli-db
   # seed a handful of test rows (any of the GraphQL mutations work, or psql
   # directly into the db container; the point is to have *something* to
   # back up and restore).
   ```

3. **Backup → R2.**
   ```bash
   docker compose -f docker-compose-prod.yml -f docker-compose-backup.yml \
                  --env-file .env.backup.prod \
                  run --rm opuspopuli-backup /scripts/backup-db.sh
   rclone copyto <local-dump-path> r2:<your-region>-prod-db-backups/<filename>.dump.gz
   rclone hashsum md5 r2:<your-region>-prod-db-backups/<filename>.dump.gz   # compare to local md5sum
   ```

4. **Restore drill from R2** (simulate full Studio loss):
   ```bash
   docker compose -f docker-compose-prod.yml down -v
   docker compose -f docker-compose-prod.yml up -d opuspopuli-db
   rclone copy r2:<your-region>-prod-db-backups/<latest>.dump.gz /tmp/
   docker compose -f docker-compose-prod.yml -f docker-compose-backup.yml \
                  run --rm opuspopuli-backup /scripts/restore-db.sh --full
   ```
   Time it. Target: **< 60 min**. Record RTO in `docs/site-notes/<your-hostname>.md`.

5. **pgsodium key drill** — stash a wrong key file, restore from R2, watch `vault.secrets` reads fail. Proves the 1Password key is the only recovery path.

6. **Reset:** `docker compose down -v`.

---

## Phase 7 — Ollama smoke (≈ 10 min)

Ollama downloads from Phase 3.7 should be done by now.

```bash
ollama list                                # qwen3.5:9b + nomic-embed-text present
curl http://localhost:11434/api/tags | jq '.models[].name'
docker run --rm alpine sh -c 'apk add curl && curl http://host.docker.internal:11434/api/tags'
# warm the model so first user request isn't a 90s cold start:
curl -X POST http://localhost:11434/api/generate \
     -d '{"model":"qwen3.5:9b","prompt":"hi","stream":false}'
```

---

## Phase 8 — Pull + start the stack (≈ 20 min)

The prod compose already references `ghcr.io/opuspopuli/<service>:${TAG:-latest}` for every backend service + worker — no local builds happen on the Studio. Image publishing is driven by the central `OpusPopuli/opuspopuli` and `OpusPopuli/prompt-service` repos' `release.yml` workflows on push to `main`.

1. **Pull images.**
   ```bash
   cd $HOME/Development/opuspopuli-node-<region>
   docker compose -f docker-compose-prod.yml -f docker-compose-backup.yml pull
   ```

2. **Bring up the stack.**
   ```bash
   docker compose -f docker-compose-prod.yml -f docker-compose-backup.yml up -d
   ```
   Watch `db-migrate` exit 0:
   ```bash
   docker compose logs -f db-migrate
   ```

3. **Seed operator secrets** into the Vault using the SQL from Phase 4.3:
   ```bash
   docker compose exec opuspopuli-db psql -U postgres -d postgres \
          < $HOME/.config/opuspopuli/seed-operator-vault.sql
   ```

4. **Smoke prompt-service** (now running inside the unified compose):
   ```bash
   curl -s -X POST http://localhost:3210/api/render \
        -H 'authorization: Bearer dev-key-1' \
        -H 'content-type: application/json' \
        -d '{"name":"document-analysis-representative-bio","inputs":{"TEXT":"test"}}' \
        | jq '.promptText | length'
   ```
   Expect a positive integer.

5. **Wait for healthy:**
   ```bash
   for port in 3000 3001 3002 3003 3004 3005 3210; do
     printf "port %s: " $port
     curl -fsS "http://localhost:$port/health" && echo
   done
   ```
   All `{"status":"ok"}`.

6. **Run ad-hoc backup** to verify R2 upload from the real stack:
   ```bash
   docker compose -f docker-compose-prod.yml -f docker-compose-backup.yml \
                  run --rm opuspopuli-backup /scripts/backup-db.sh
   wrangler r2 object list <your-region>-prod-db-backups | head
   ```

---

## Phase 9 — Cloudflare Tunnel cutover (≈ 30 min, the visible moment)

1. **Connect cloudflared.** Already defined in `docker-compose-prod.yml`; reads `TUNNEL_TOKEN` from launchd env (Phase 4.2).
   ```bash
   docker compose -f docker-compose-prod.yml up -d cloudflared
   docker logs <your-region>-prod-cloudflared --tail 50
   # expect "Registered tunnel connection" from 2+ edge POPs
   ```

2. **Verify from off-LAN** (phone tethered, or a friend's laptop):
   ```bash
   curl -i https://api.<your-domain>/health     # HTTP/2 200, cf-cache-status header
   curl -s -X POST https://api.<your-domain>/api \
        -H 'content-type: application/json' \
        -H 'apollo-require-preflight: true' \
        -d '{"query":"{ regionInfo { name } }"}' | jq
   ```

3. **Point Cloudflare Pages at prod.** In Pages settings:
   ```
   NEXT_PUBLIC_GRAPHQL_URL=https://api.<your-domain>/api
   ```
   Deploy:
   ```bash
   cd apps/frontend
   pnpm cf:deploy
   ```

4. **End-to-end browser check.** Visit `https://app.<your-domain>`. Sign up → magic link arrives via Resend → add address → `/region` page renders representatives + committees → click into a committee → all four layers render.

---

## Phase 10 — Observability + alerts (≈ 45 min)

1. **Grafana behind Cloudflare Access.** Extend `infra/cloudflare/tunnel.tf` with an ingress rule for `grafana.<your-domain>` → `http://localhost:3101`. Apply. Add Cloudflare Access policy requiring login as your email.
   ```bash
   curl -I https://grafana.<your-domain>    # redirect to Access login
   ```

2. **Grafana alerts → Resend SMTP.** Grafana → Alerting → Notification channels.

3. **External uptime monitor** — UptimeRobot or Better Stack free tier: `GET https://api.<your-domain>/health` every 1 min, page on 3 failures.

4. **Smoke an alert:**
   ```bash
   docker compose stop knowledge
   # wait 5 min, confirm email arrives
   docker compose start knowledge
   ```

5. **Confirm `audit_logs` table is in nightly `pg_dump`.**

---

## Cold-restore rehearsal (≈ 4 h, optional, post-MVP if time-pressed)

Run the entire bootstrap from Phase 2 onward against a second Mac (your dev MacBook works) using the R2 backup. The only honest RTO answer is what the rehearsal measures. Record in `docs/site-notes/cold-restore-runbook.md`.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `db-migrate` exits non-zero | Migration SQL conflict, FK type drift vs `users.id` (TEXT) | `docker logs opuspopuli-e2e-db-migrate` |
| Container OOMs (region, knowledge) | Docker memory cap too low | Settings → Resources → bump from 40 → 48 GB |
| `network prompt-service_default not found` | prompt-service stack not running | Phase 8.1 |
| Stale frontend after Pages deploy | Service worker cache | DevTools → Application → Service Workers → Unregister + Reload |
| Ollama timeouts | `OLLAMA_NUM_PARALLEL` vs `BIO_GENERATOR_CONCURRENCY` mismatch | `docs/guides/ollama-setup.md` |
| `apollo-require-preflight` 403 | NestJS CSRF on the path | Use in-browser fetch — same-origin cookies bypass |
| Tunnel reports unhealthy | Token rotated or DNS not pointing at tunnel | Re-apply Terraform; reload LaunchAgent |
| `vault.secrets` all error after restore | pgsodium key drift | Restore 1Password key to `$HOME/.config/opuspopuli/pgsodium_root_key`; relogin |
| Stack doesn't come back after reboot | LaunchAgent didn't inject `PGSODIUM_ROOT_KEY` | `launchctl list | grep opuspopuli.envloader`; reload `.plist`; relogin |
| Docker disk image full | Volumes accumulated | `docker system prune --volumes` (READ docs first); **never resize the disk image** — that wipes volumes |

---

## Critical files

- `docker-compose-prod.yml` — base prod stack
- `docker-compose-backup.yml` — nightly `pg_dump` overlay
- `supabase/init/pgsodium_getkey_env.sh` — reads `PGSODIUM_ROOT_KEY` from env
- `infra/cloudflare/tunnel.tf` — Tunnel ingress rules
- `backup/scripts/backup-db.sh` — dump + verify
- `apps/backend/src/common/bootstrap.ts` — `VAULT_BACKED_SECRETS` list
- `~/Library/LaunchAgents/org.opuspopuli.envloader.plist` — boot-time env injection
- `$HOME/.config/opuspopuli/pgsodium_root_key` — local mirror of the 1Password key (mode 0400)
- `$HOME/.config/opuspopuli/seed-operator-vault.sql` — operator-secret seed SQL (mode 0400, not committed)
