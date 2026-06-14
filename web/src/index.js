/**
 * Maldari — session transcript service.
 *
 * Public:    GET  /            landing page (static asset)
 * App API:   PUT  /api/sessions/:id   upload/overwrite one session's markdown
 *                                     (Authorization: Bearer UPLOAD_TOKEN)
 * Viewer:    GET  /login, POST /login, GET /logout
 *            GET  /app             session list   (cookie auth)
 *            GET  /app/s/:id       rendered transcript
 *            GET  /app/s/:id/raw   markdown download
 *
 * Storage: R2 bucket SESSIONS, keys `sessions/<id>.md`, customMetadata
 * {startedAt, utterances, durationS}. Ids are date-time stamps
 * (e.g. 2026-06-11-120154) so lexicographic order is chronological.
 */

const COOKIE = "maldari_auth";
const SESSION_TTL_S = 30 * 24 * 3600;
const ID_RE = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const { pathname } = url;

    try {
      if (pathname.startsWith("/api/sessions/")) {
        return await handleUpload(request, env, pathname);
      }
      if (pathname === "/login") {
        return request.method === "POST"
          ? await handleLoginPost(request, env)
          : page(loginHtml(url.searchParams.has("bad")), 200);
      }
      if (pathname === "/logout") {
        return redirect("/", clearCookie());
      }
      if (pathname === "/app" || pathname.startsWith("/app/")) {
        if (!(await isAuthed(request, env))) return redirect("/login");
        if (pathname === "/app" || pathname === "/app/") {
          return await appShell(env, null);
        }
        const m = pathname.match(/^\/app\/s\/([^/]+?)(\/raw)?$/);
        if (m) {
          if (!ID_RE.test(m[1])) return page(notFoundHtml(), 404);
          return m[2]
            ? await rawSession(env, m[1])
            : await appShell(env, m[1]);
        }
        return page(notFoundHtml(), 404);
      }
      // Anything else under run_worker_first that we don't know.
      return env.ASSETS.fetch(request);
    } catch (err) {
      console.error("maldari error", { path: pathname, error: String(err) });
      return page(errorHtml(), 500);
    }
  },
};

// MARK: - Upload API (macOS app)

async function handleUpload(request, env, pathname) {
  if (request.method !== "PUT") {
    return new Response("method not allowed", { status: 405 });
  }
  const auth = request.headers.get("authorization") || "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!token || !(await safeEqual(token, env.UPLOAD_TOKEN))) {
    return new Response("unauthorized", { status: 401 });
  }
  const id = decodeURIComponent(pathname.slice("/api/sessions/".length));
  if (!ID_RE.test(id)) {
    return new Response("bad session id", { status: 400 });
  }
  const markdown = await request.text();
  if (!markdown || markdown.length > 10_000_000) {
    return new Response("bad body", { status: 400 });
  }
  await env.SESSIONS.put(`sessions/${id}.md`, markdown, {
    httpMetadata: { contentType: "text/markdown; charset=utf-8" },
    customMetadata: {
      startedAt: request.headers.get("x-maldari-started-at") || "",
      utterances: request.headers.get("x-maldari-utterances") || "0",
      durationS: request.headers.get("x-maldari-duration") || "0",
      finalized: request.headers.get("x-maldari-finalized") || "false",
    },
  });
  return Response.json({ ok: true, id });
}

// MARK: - Auth

async function hmac(env, message) {
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(env.SESSION_SECRET),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Constant-time-ish string compare via digest comparison. */
async function safeEqual(a, b) {
  const enc = new TextEncoder();
  const [da, db] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(a)),
    crypto.subtle.digest("SHA-256", enc.encode(b)),
  ]);
  const va = new Uint8Array(da), vb = new Uint8Array(db);
  let diff = 0;
  for (let i = 0; i < va.length; i++) diff |= va[i] ^ vb[i];
  return diff === 0;
}

async function isAuthed(request, env) {
  const cookie = request.headers.get("cookie") || "";
  const match = cookie.match(new RegExp(`${COOKIE}=([^;]+)`));
  if (!match) return false;
  const [exp, sig] = match[1].split(".");
  if (!exp || !sig) return false;
  if (Number(exp) < Date.now() / 1000) return false;
  return safeEqual(sig, await hmac(env, exp));
}

async function handleLoginPost(request, env) {
  const form = await request.formData();
  const password = String(form.get("password") || "");
  if (!password || !(await safeEqual(password, env.LOGIN_PASSWORD))) {
    await new Promise((r) => setTimeout(r, 400)); // slow down guessing
    return redirect("/login?bad");
  }
  const exp = String(Math.floor(Date.now() / 1000) + SESSION_TTL_S);
  const sig = await hmac(env, exp);
  return redirect("/app", {
    "set-cookie":
      `${COOKIE}=${exp}.${sig}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=${SESSION_TTL_S}`,
  });
}

function clearCookie() {
  return { "set-cookie": `${COOKIE}=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0` };
}

// MARK: - Viewer pages

async function listAllSessions(env) {
  const sessions = [];
  let cursor;
  do {
    const listed = await env.SESSIONS.list({
      prefix: "sessions/", cursor, include: ["customMetadata"],
    });
    sessions.push(...listed.objects);
    cursor = listed.truncated ? listed.cursor : undefined;
  } while (cursor);
  // Ids are date-time stamps: lexicographic desc == newest first.
  sessions.sort((a, b) => (a.key < b.key ? 1 : -1));
  return sessions;
}

/**
 * The two-pane viewer: session sidebar on the left, transcript on the right.
 * `/app` passes selectedId=null and we open the newest session by default, so
 * the right pane is never empty when sessions exist.
 */
async function appShell(env, selectedId) {
  const sessions = await listAllSessions(env);

  let id = selectedId;
  if (!id && sessions.length) {
    id = sessions[0].key.slice("sessions/".length, -3);
  }

  let viewerHtml;
  if (sessions.length === 0) {
    viewerHtml = `<div class="viewer-empty"><p class="empty">No sessions yet.
      Start a meeting in the Maldari app — every session lands here automatically.</p></div>`;
  } else if (id) {
    const object = await env.SESSIONS.get(`sessions/${id}.md`);
    viewerHtml = object
      ? viewerHtmlFor(id, await object.text(), object.customMetadata || {})
      : `<div class="viewer-empty"><p class="empty">Session not found.
         <a href="/app">Back to the latest</a>.</p></div>`;
  } else {
    viewerHtml = `<div class="viewer-empty"><p class="empty">Pick a session on the left.</p></div>`;
  }

  const body = `<div class="shell2">
    <aside class="side">
      <a class="wordmark" href="/">말다리<span>Maldari</span></a>
      <div class="side-list">${sidebarHtml(sessions, id)}</div>
      <div class="side-foot"><a href="/logout">log out</a></div>
    </aside>
    <main class="viewer">${viewerHtml}</main>
  </div>
  <script>${VIEW_TOGGLE_JS}</script>`;

  return page(shell("Sessions", body, false), 200);
}

function sidebarHtml(sessions, selectedId) {
  const groups = new Map();
  for (const s of sessions) {
    const id = s.key.slice("sessions/".length, -3);
    const day = id.slice(0, 10);
    if (!groups.has(day)) groups.set(day, []);
    groups.get(day).push({ id, meta: s.customMetadata || {} });
  }
  let out = "";
  for (const [day, items] of groups) {
    out += `<div class="side-day">${esc(day)}</div>`;
    for (const { id, meta } of items) {
      const time = fmtTime(id, meta.startedAt);
      const count = Number(meta.utterances || 0);
      const dur = fmtDuration(Number(meta.durationS || 0));
      const tail = meta.finalized === "false"
        ? `<span class="live">live</span>`
        : `<span class="id">${esc(dur)}</span>`;
      out += `<a class="side-item${id === selectedId ? " on" : ""}" href="/app/s/${esc(id)}">
        <span class="it">${esc(time)}</span>
        <span class="il">${count ? `${count} lines` : "—"}</span>
        ${tail}
      </a>`;
    }
  }
  return out;
}

/** Right pane: header (title + Stacked/Columns toggle + download) over rows.
 *  Both layouts share the same row markup; the `.cols` class on `.viewer`
 *  switches stacked → parallel columns via CSS. */
function viewerHtmlFor(id, markdown, meta) {
  const rows = parseTranscript(markdown);
  let body = "";
  for (const row of rows) {
    body += `<div class="row">
      <div class="ts">${esc(row.time)}</div>
      <div class="ko">${esc(row.korean)}</div>
      <div class="en">${row.english ? esc(row.english) : ""}</div>
    </div>`;
  }
  if (rows.length === 0) {
    return `<div class="viewer-empty"><p class="empty">Empty transcript.</p></div>`;
  }
  return `<header class="vbar">
      <h1 class="vtitle">${esc(fmtTime(id, meta.startedAt))}<span class="vday">${esc(id.slice(0, 10))}</span></h1>
      <div class="seg" id="viewseg">
        <button class="on" data-view="stack">Stacked</button>
        <button data-view="cols">Columns</button>
      </div>
      <a class="dl" href="/app/s/${esc(id)}/raw" download>download .md</a>
    </header>
    <div class="rows">${body}</div>`;
}

/** Inline: toggle Stacked/Columns and remember the choice. */
const VIEW_TOGGLE_JS = `(function(){
  var KEY='maldari-view';
  var viewer=document.querySelector('.viewer');
  var seg=document.getElementById('viewseg');
  if(!viewer||!seg)return;
  function set(v){
    viewer.classList.toggle('cols', v==='cols');
    seg.querySelectorAll('button').forEach(function(b){ b.classList.toggle('on', b.dataset.view===v); });
    try{ localStorage.setItem(KEY, v); }catch(e){}
  }
  seg.addEventListener('click', function(e){ var b=e.target.closest('button'); if(b) set(b.dataset.view); });
  var saved='stack'; try{ saved=localStorage.getItem(KEY)||'stack'; }catch(e){}
  set(saved);
})();`;

async function rawSession(env, id) {
  const object = await env.SESSIONS.get(`sessions/${id}.md`);
  if (!object) return new Response("not found", { status: 404 });
  return new Response(object.body, {
    headers: {
      "content-type": "text/markdown; charset=utf-8",
      "content-disposition": `attachment; filename="maldari-${id}.md"`,
      etag: object.httpEtag,
    },
  });
}

/**
 * Parses the app's exportMarkdown shape:
 *   **HH:MM:SS**         → timestamp starting a row
 *   **HH:MM:SS — Me**    → timestamp + speaker (dual-capture sessions:
 *                          mic = "Me", system audio = "Them")
 *   > english            → translation line
 *   anything else        → Korean text
 */
function parseTranscript(markdown) {
  const rows = [];
  let current = null;
  for (const line of markdown.split("\n")) {
    const t = line.trim();
    if (!t || t.startsWith("# ")) continue;
    const ts = t.match(/^\*\*(\d{2}:\d{2}:\d{2})(?:\s+—\s+(.+?))?\*\*$/);
    if (ts) {
      current = { time: ts[1], speaker: ts[2] || "", korean: "", english: "" };
      rows.push(current);
    } else if (t.startsWith("> ")) {
      if (current) current.english += (current.english ? " " : "") + t.slice(2);
    } else if (current) {
      current.korean += (current.korean ? " " : "") + t;
    }
  }
  return rows.filter((r) => r.korean || r.english);
}

// MARK: - HTML

function fmtTime(id, startedAt) {
  if (startedAt) {
    const d = new Date(startedAt);
    if (!isNaN(d)) {
      return d.toLocaleTimeString("en-US", {
        hour: "numeric", minute: "2-digit", timeZone: "America/Los_Angeles",
      });
    }
  }
  const m = id.match(/^\d{4}-\d{2}-\d{2}-(\d{2})(\d{2})/);
  return m ? `${m[1]}:${m[2]}` : id;
}

function fmtDuration(s) {
  if (!s || s <= 0) return "";
  if (s < 60) return `${Math.round(s)}s`;
  const m = Math.round(s / 60);
  return m < 60 ? `${m} min` : `${Math.floor(m / 60)}h ${m % 60}m`;
}

function esc(s) {
  return String(s).replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

function page(html, status, extraHeaders = {}) {
  return new Response(html, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "x-frame-options": "DENY",
      "x-content-type-options": "nosniff",
      "referrer-policy": "no-referrer",
      ...extraHeaders,
    },
  });
}

function redirect(to, extraHeaders = {}) {
  return new Response(null, { status: 303, headers: { location: to, ...extraHeaders } });
}

function shell(title, body, withFooter = true) {
  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>${esc(title)} — Maldari</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,400;9..144,600&family=Gowun+Batang:wght@400;700&family=IBM+Plex+Mono:wght@400;500&family=IBM+Plex+Sans+KR:wght@400;500&display=swap" rel="stylesheet">
<link rel="stylesheet" href="/maldari.css">
</head><body class="appview">${body}${withFooter ? `
<footer class="foot"><span>말다리 · a bridge of words</span></footer>` : ""}
</body></html>`;
}

function loginHtml(bad) {
  return shell("Log in", `
    <main class="login">
      <a class="wordmark big" href="/">말다리<span>Maldari</span></a>
      <form method="post" action="/login">
        <label for="pw">Password</label>
        <input id="pw" name="password" type="password" autofocus autocomplete="current-password">
        ${bad ? `<p class="bad">Wrong password.</p>` : ""}
        <button type="submit">Enter →</button>
      </form>
    </main>`);
}

function notFoundHtml() {
  return shell("Not found", `<main class="login"><a class="wordmark big" href="/">말다리<span>Maldari</span></a>
    <p class="empty">Nothing here. <a href="/app">Back to sessions</a>.</p></main>`);
}

function errorHtml() {
  return shell("Error", `<main class="login"><a class="wordmark big" href="/">말다리<span>Maldari</span></a>
    <p class="empty">Something broke. Try again.</p></main>`);
}
