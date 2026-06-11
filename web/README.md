# Maldari web

Cloudflare Worker serving:

- `/` — product landing page (static assets in `public/`)
- `/login`, `/app` — password-gated session transcript viewer
- `PUT /api/sessions/:id` — upload endpoint the macOS app uses
  (`Authorization: Bearer $UPLOAD_TOKEN`, body = transcript markdown,
  metadata in `x-maldari-*` headers)

Sessions are stored in the `maldari-sessions` R2 bucket as
`sessions/<yyyy-mm-dd-hhmmss>.md`.

## Deploy

```bash
cd web
npm install
npx wrangler r2 bucket create maldari-sessions   # once
npx wrangler secret put UPLOAD_TOKEN             # token the app sends
npx wrangler secret put LOGIN_PASSWORD           # viewer password
npx wrangler secret put SESSION_SECRET           # cookie-signing key
npx wrangler deploy
```

The custom domain (`maldari.johnnywon.com`) is configured in `wrangler.jsonc`
and requires the `johnnywon.com` zone in the same Cloudflare account.

## Local dev

```bash
npx wrangler dev
```

Local R2 is memory-backed; set dev secrets in `.dev.vars` (gitignored):

```
UPLOAD_TOKEN=dev-token
LOGIN_PASSWORD=dev-password
SESSION_SECRET=dev-secret
```
