(() => {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const main = $("main");
  const accountBox = $("accountBox");
  const forumBox = $("forumBox");
  const notice = $("notice");
  const msgBadge = $("msgBadge");
  const notifBadge = $("notifBadge");

  const state = {
    me: null,
    counts: {},
    forums: [],
    route: null,
    ws: null,
    wsTimer: null,
    currentThreadId: null,
    currentMessageUser: null,
    refreshBusy: false,
  };

  const esc = (value) => String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");

  const fmt = (unix) => {
    if (!unix) return "never";
    const d = new Date(unix * 1000);
    return d.toLocaleString(undefined, {
      year: "numeric",
      month: "short",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
    });
  };

  const age = (unix) => {
    if (!unix) return "never";
    const diff = Math.max(0, Math.floor(Date.now() / 1000) - unix);
    if (diff < 60) return `${diff}s ago`;
    if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
    if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
    return `${Math.floor(diff / 86400)}d ago`;
  };

  async function api(path, opts = {}) {
    const res = await fetch(`/api${path}`, {
      credentials: "same-origin",
      headers: { "content-type": "application/json", ...(opts.headers || {}) },
      ...opts,
    });
    const data = await res.json().catch(() => ({ ok: false, error: "Invalid server response." }));
    if (!res.ok || data.ok === false) {
      const err = new Error(data.error || `HTTP ${res.status}`);
      err.status = res.status;
      err.data = data;
      throw err;
    }
    return data;
  }

  function showNotice(text, kind = "info") {
    notice.textContent = text;
    notice.className = kind === "error" ? "notice error" : "notice";
    notice.hidden = false;
    window.clearTimeout(showNotice.timer);
    showNotice.timer = window.setTimeout(() => {
      notice.hidden = true;
    }, 4500);
  }

  function updateBadges() {
    const m = state.counts.unread_messages || 0;
    const n = state.counts.unread_notifications || 0;
    msgBadge.textContent = m;
    notifBadge.textContent = n;
    msgBadge.classList.toggle("hidden", !m);
    notifBadge.classList.toggle("hidden", !n);
  }

  async function loadMe() {
    try {
      const data = await api("/me");
      state.me = data.user;
      state.counts = data.counts || {};
      updateBadges();
      renderAccountBox();
      connectSocket();
    } catch {
      state.me = null;
      renderAccountBox();
    }
  }

  async function loadForums() {
    const data = await api("/forums");
    state.forums = data.forums || [];
    renderForumBox();
  }

  function renderAccountBox(mode = "login") {
    if (state.me) {
      accountBox.innerHTML = `
        <h3>Account</h3>
        <div class="inner">
          <div><strong>${esc(state.me.display_name)}</strong></div>
          <div class="small muted">@${esc(state.me.username)}</div>
          <div class="small muted">last seen ${age(state.me.last_seen)}</div>
          <div class="row" style="margin-top:8px">
            <a class="button" href="#/messages">Messages</a>
            <button class="secondary" data-action="logout">Logout</button>
          </div>
        </div>`;
      return;
    }

    const isRegister = mode === "register";
    accountBox.innerHTML = `
      <h3>Account</h3>
      <div class="auth-tabs">
        <button class="${!isRegister ? "active" : ""}" data-auth-tab="login">Login</button>
        <button class="${isRegister ? "active" : ""}" data-auth-tab="register">Register</button>
      </div>
      <div class="auth-body">
        <form id="authForm">
          <input type="hidden" name="mode" value="${isRegister ? "register" : "login"}">
          <label>Username</label>
          <input name="username" autocomplete="username" required minlength="3" maxlength="24">
          ${isRegister ? `<label>Display name</label><input name="display_name" maxlength="40">` : ""}
          <label>Password</label>
          <input name="password" type="password" autocomplete="${isRegister ? "new-password" : "current-password"}" required minlength="8">
          <div class="form-actions"><button>${isRegister ? "Register" : "Login"}</button></div>
        </form>
        <p class="small muted">Use a throwaway password unless you deploy behind HTTPS.</p>
      </div>`;
  }

  function renderForumBox() {
    forumBox.innerHTML = `
      <h3>Forums</h3>
      <ul>
        <li><a href="#/threads">Active topics</a></li>
        ${state.forums.map(f => `<li><a href="#/forum/${f.id}">${esc(f.name)}</a><div class="small muted">${f.thread_count || 0} threads</div></li>`).join("")}
      </ul>`;
  }

  function requireLogin() {
    if (state.me) return true;
    main.innerHTML = `<div class="empty">You need to log in first.</div>`;
    return false;
  }

  function forumName(id) {
    return (state.forums.find(f => String(f.id) === String(id)) || {}).name || "Forum";
  }

  async function renderHome() {
    state.route = "home";
    const data = await api("/forums");
    state.forums = data.forums || [];
    renderForumBox();
    main.innerHTML = `
      <div class="panel">
        <div class="panel-title">Forum index</div>
        <div class="panel-body muted">A small, permanent discussion board for technical notes, questions, fixes, and project work.</div>
      </div>
      <table class="table">
        <thead><tr><th>Forum</th><th class="num">Threads</th><th class="num">Replies</th><th class="num">Activity</th></tr></thead>
        <tbody>
          ${state.forums.map(f => `
            <tr>
              <td><a class="forum-name" href="#/forum/${f.id}">${esc(f.name)}</a><div class="description">${esc(f.description)}</div></td>
              <td class="num">${f.thread_count || 0}</td>
              <td class="num">${f.reply_count || 0}</td>
              <td class="num">${f.last_activity ? age(f.last_activity) : "none"}</td>
            </tr>`).join("")}
        </tbody>
      </table>`;
  }

  function threadTable(threads) {
    if (!threads.length) return `<div class="empty">No threads yet. Start one.</div>`;
    return `
      <table class="table">
        <thead><tr><th>Thread</th><th class="num">Replies</th><th class="num">Views</th><th class="num">Last</th></tr></thead>
        <tbody>
          ${threads.map(t => `
            <tr>
              <td>
                <a class="thread-link" href="#/thread/${t.id}">${esc(t.title)}</a>
                <div class="small muted">in ${esc(t.forum_name)} by <a href="#/user/${esc(t.user.username)}">${esc(t.user.display_name)}</a></div>
              </td>
              <td class="num">${t.reply_count || 0}</td>
              <td class="num">${t.views || 0}</td>
              <td class="num">${age(t.updated_at)}</td>
            </tr>`).join("")}
        </tbody>
      </table>`;
  }

  async function renderThreads(forumId = "all", query = "") {
    state.route = forumId === "all" ? "threads" : "forum";
    const q = new URLSearchParams();
    if (forumId !== "all") q.set("forum", forumId);
    if (query) q.set("q", query);
    const data = await api(`/threads?${q}`);
    const title = query ? `Search results for “${esc(query)}”` : forumId === "all" ? "Active topics" : forumName(forumId);
    main.innerHTML = `
      <div class="breadcrumbs"><a href="#/">Forum index</a> / ${title}</div>
      <div class="panel">
        <div class="panel-title">${title}</div>
        <div id="threadList">${threadTable(data.threads || [])}</div>
      </div>`;
  }

  function renderPosts(thread, replies, preserveReply = true) {
    const replyBox = $("replyBody");
    const savedReply = preserveReply && replyBox ? replyBox.value : "";
    const focused = document.activeElement === replyBox;
    const posts = replies.map((r, index) => `
      <article class="post" id="reply-${r.id}">
        <aside class="post-author">
          <div class="avatar">${esc((r.user.display_name || r.user.username || "?").slice(0, 2).toUpperCase())}</div>
          <div class="name"><a href="#/user/${esc(r.user.username)}">${esc(r.user.display_name)}</a></div>
          <div class="rank">member</div>
          <div class="small muted">post #${index + 1}</div>
        </aside>
        <section class="post-content">
          <div class="post-head">${fmt(r.created_at)}</div>
          <div class="post-body">${esc(r.body)}</div>
          <div class="signature">${esc(r.user.username)} · Plainwire member</div>
        </section>
      </article>`).join("");

    const list = $("postList");
    if (list) {
      list.innerHTML = posts;
    }

    const meta = $("threadMeta");
    if (meta) {
      meta.innerHTML = `${replies.length} posts · updated ${age(thread.updated_at)}`;
    }

    const newReplyBox = $("replyBody");
    if (newReplyBox && savedReply && preserveReply) newReplyBox.value = savedReply;
    if (focused && newReplyBox) newReplyBox.focus();
  }

  async function renderThread(id, soft = false) {
    state.route = "thread";
    state.currentThreadId = Number(id);
    const data = await api(`/threads/${id}`);
    const thread = data.thread;
    const replies = data.replies || [];

    if (soft && $("postList")) {
      renderPosts(thread, replies, true);
      return;
    }

    main.innerHTML = `
      <div class="breadcrumbs"><a href="#/">Forum index</a> / <a href="#/forum/${thread.forum_id}">${esc(thread.forum_name)}</a> / thread</div>
      <div class="thread">
        <div class="thread-titlebar">${esc(thread.title)}<div id="threadMeta" class="small muted">${replies.length} posts · updated ${age(thread.updated_at)}</div></div>
        <div id="postList"></div>
      </div>
      ${state.me ? `
        <form id="replyForm" class="composer" data-thread-id="${thread.id}">
          <h3>Post a reply</h3>
          <textarea id="replyBody" name="body" placeholder="Write a reply..." required></textarea>
          <div class="form-actions"><button>Submit reply</button><span class="small muted">Your draft stays untouched when updates arrive.</span></div>
        </form>` : `<div class="empty">Log in to reply.</div>`}`;
    renderPosts(thread, replies, false);
  }

  async function renderNewThread() {
    state.route = "new";
    if (!requireLogin()) return;
    if (!state.forums.length) await loadForums();
    main.innerHTML = `
      <div class="panel">
        <div class="panel-title">New thread</div>
        <div class="panel-body">
          <form id="newThreadForm">
            <label>Forum</label>
            <select name="forum_id" required>${state.forums.map(f => `<option value="${f.id}">${esc(f.name)}</option>`).join("")}</select>
            <label>Title</label>
            <input name="title" required minlength="4" maxlength="120" placeholder="Short, specific title">
            <label>Post</label>
            <textarea name="body" required placeholder="Describe the issue, what you tried, and relevant logs or versions."></textarea>
            <div class="form-actions"><button>Create thread</button></div>
          </form>
        </div>
      </div>`;
  }

  async function renderMessages(username = null, soft = false) {
    state.route = "messages";
    if (!requireLogin()) return;
    state.currentMessageUser = username;

    const convData = await api("/conversations");
    const conv = convData.conversations || [];

    if (!soft) {
      main.innerHTML = `
        <div class="messages-grid">
          <section class="conversation-list" id="conversationList"></section>
          <section class="chat-window" id="chatWindow"></section>
        </div>`;
    }

    const list = $("conversationList");
    if (list) {
      list.innerHTML = `
        <div class="message-head">Messages</div>
        <div class="panel-body">
          <form id="startMessageForm" class="compact-form" style="padding:0">
            <input name="to" placeholder="username">
            <button>Open</button>
          </form>
        </div>
        ${conv.length ? conv.map(c => `
          <a class="conversation-item ${username === c.user.username ? "active" : ""}" href="#/messages/${esc(c.user.username)}">
            <strong>${esc(c.user.display_name)}</strong> <span class="small muted">@${esc(c.user.username)}</span>
            ${c.unread ? `<span class="unread-dot">● ${c.unread}</span>` : ""}
            <div class="small muted">${esc(c.last_body || "")}</div>
          </a>`).join("") : `<div class="empty" style="border:0">No messages yet.</div>`}`;
    }

    if (username) await renderChat(username, soft);
    else if (!soft) $("chatWindow").innerHTML = `<div class="message-head">Conversation</div><div class="empty" style="border:0">Choose a conversation or enter a username.</div>`;
  }

  async function renderChat(username, soft = false) {
    const data = await api(`/messages/${encodeURIComponent(username)}`);
    const chat = $("chatWindow");
    if (!chat) return;
    const box = $("messageBody");
    const draft = soft && box ? box.value : "";
    const focused = document.activeElement === box;

    chat.innerHTML = `
      <div class="message-head">Conversation with ${esc(data.other.display_name)} <span class="small muted">@${esc(data.other.username)}</span></div>
      <div class="chat-log" id="chatLog">
        ${(data.messages || []).map(m => {
          const mine = state.me && m.sender.id === state.me.id;
          return `<div class="message ${mine ? "mine" : ""}">
            <div class="message-meta">${mine ? "you" : esc(m.sender.display_name)} · ${fmt(m.created_at)}</div>
            <div>${esc(m.body)}</div>
          </div>`;
        }).join("") || `<div class="empty" style="border:0">No messages in this conversation.</div>`}
      </div>
      <form id="messageForm" class="chat-compose" data-to="${esc(data.other.username)}">
        <textarea id="messageBody" name="body" placeholder="Write a message..." required></textarea>
        <div class="form-actions"><button>Send</button><span class="small muted">Incoming messages do not reset this text area.</span></div>
      </form>`;

    const newBox = $("messageBody");
    if (draft && newBox) newBox.value = draft;
    if (focused && newBox) newBox.focus();
    const log = $("chatLog");
    if (log && !focused) log.scrollTop = log.scrollHeight;
    await refreshCounts();
  }

  async function renderNotifications() {
    state.route = "notifications";
    if (!requireLogin()) return;
    const data = await api("/notifications");
    state.counts = data.counts || {};
    updateBadges();
    const items = data.notifications || [];
    main.innerHTML = `
      <div class="panel">
        <div class="panel-title row between"><span>Notifications</span><button class="secondary" data-action="markNotificationsRead">Mark read</button></div>
        <div>
          ${items.length ? items.map(n => `
            <div class="notification ${n.seen ? "" : "unread"}">
              <a href="${esc(n.url)}">${esc(n.body)}</a>
              <div class="small muted">${esc(n.kind)} · ${fmt(n.created_at)}</div>
            </div>`).join("") : `<div class="empty" style="border:0">No notifications.</div>`}
        </div>
      </div>`;
  }

  async function renderUser(username) {
    const data = await api(`/users/${encodeURIComponent(username)}`);
    const u = data.user;
    main.innerHTML = `
      <div class="panel">
        <div class="panel-title">Member profile</div>
        <div class="panel-body">
          <div class="row">
            <div class="avatar">${esc((u.display_name || u.username).slice(0, 2).toUpperCase())}</div>
            <div>
              <h2 style="margin:0">${esc(u.display_name)}</h2>
              <div class="muted">@${esc(u.username)}</div>
              <div class="small muted">joined ${fmt(u.created_at)} · last seen ${age(u.last_seen)}</div>
            </div>
          </div>
          ${state.me && state.me.username !== u.username ? `<p><a class="button" href="#/messages/${esc(u.username)}">Message ${esc(u.display_name)}</a></p>` : ""}
        </div>
      </div>`;
  }

  async function refreshCounts() {
    if (!state.me) return;
    try {
      const data = await api("/notifications");
      state.counts = data.counts || {};
      updateBadges();
    } catch {}
  }

  async function softRefresh(reason = "event") {
    if (state.refreshBusy) return;
    state.refreshBusy = true;
    try {
      await refreshCounts();
      if (state.route === "thread" && state.currentThreadId) {
        await renderThread(state.currentThreadId, true);
      } else if (state.route === "messages" && state.currentMessageUser) {
        await renderMessages(state.currentMessageUser, true);
      } else if (state.route === "messages") {
        await renderMessages(null, true);
      } else if (state.route === "home") {
        await loadForums();
      }
    } catch (err) {
      console.warn("soft refresh failed", reason, err);
    } finally {
      state.refreshBusy = false;
    }
  }

  function connectSocket() {
    if (!state.me) return;
    if (state.ws && [WebSocket.CONNECTING, WebSocket.OPEN].includes(state.ws.readyState)) return;

    window.clearTimeout(state.wsTimer);
    const proto = location.protocol === "https:" ? "wss" : "ws";
    const ws = new WebSocket(`${proto}://${location.host}/ws`);
    state.ws = ws;

    ws.onmessage = (event) => {
      let msg;
      try { msg = JSON.parse(event.data); } catch { return; }
      if (msg.type === "message_created") showNotice("New private message.");
      if (msg.type === "reply_created") {
        if (state.route !== "thread" || Number(msg.thread_id) !== Number(state.currentThreadId)) showNotice("New forum activity.");
      }
      softRefresh(msg.type);
    };

    ws.onclose = () => {
      if (state.me) state.wsTimer = window.setTimeout(connectSocket, 3000);
    };

    ws.onerror = () => {
      try { ws.close(); } catch {}
    };
  }

  async function route() {
    const hash = location.hash || "#/";
    const parts = hash.replace(/^#\/?/, "").split("/").filter(Boolean);
    try {
      if (!parts.length) await renderHome();
      else if (parts[0] === "forum") await renderThreads(parts[1] || "all");
      else if (parts[0] === "threads") await renderThreads("all");
      else if (parts[0] === "search") await renderThreads("all", decodeURIComponent(parts.slice(1).join("/")));
      else if (parts[0] === "thread") await renderThread(parts[1]);
      else if (parts[0] === "new") await renderNewThread();
      else if (parts[0] === "messages") await renderMessages(parts[1] ? decodeURIComponent(parts[1]) : null);
      else if (parts[0] === "notifications") await renderNotifications();
      else if (parts[0] === "user") await renderUser(parts[1]);
      else await renderHome();
    } catch (err) {
      console.error(err);
      main.innerHTML = `<div class="empty err">${esc(err.message || "Something went wrong.")}</div>`;
    }
  }

  document.addEventListener("click", async (event) => {
    const target = event.target.closest("button, a");
    if (!target) return;

    if (target.dataset.authTab) {
      renderAccountBox(target.dataset.authTab);
      return;
    }

    if (target.dataset.action === "logout") {
      event.preventDefault();
      await api("/logout", { method: "POST", body: "{}" }).catch(() => null);
      state.me = null;
      state.counts = {};
      updateBadges();
      if (state.ws) state.ws.close();
      renderAccountBox();
      showNotice("Logged out.");
      route();
      return;
    }

    if (target.dataset.action === "markNotificationsRead") {
      event.preventDefault();
      await api("/notifications/read", { method: "POST", body: "{}" });
      await renderNotifications();
      return;
    }
  });

  document.addEventListener("submit", async (event) => {
    const form = event.target;
    if (!(form instanceof HTMLFormElement)) return;

    try {
      if (form.id === "authForm") {
        event.preventDefault();
        const fd = new FormData(form);
        const mode = fd.get("mode");
        const body = JSON.stringify(Object.fromEntries(fd.entries()));
        const data = await api(mode === "register" ? "/register" : "/login", { method: "POST", body });
        state.me = data.user;
        showNotice(mode === "register" ? "Account registered." : "Logged in.");
        await loadMe();
        await route();
      }

      if (form.id === "searchForm") {
        event.preventDefault();
        const q = $("searchInput").value.trim();
        location.hash = q ? `#/search/${encodeURIComponent(q)}` : "#/threads";
      }

      if (form.id === "newThreadForm") {
        event.preventDefault();
        const data = Object.fromEntries(new FormData(form).entries());
        const res = await api("/threads", { method: "POST", body: JSON.stringify(data) });
        showNotice("Thread created.");
        location.hash = `#/thread/${res.thread_id}`;
      }

      if (form.id === "replyForm") {
        event.preventDefault();
        const id = form.dataset.threadId;
        const body = $("replyBody").value;
        await api(`/threads/${id}/replies`, { method: "POST", body: JSON.stringify({ body }) });
        $("replyBody").value = "";
        await renderThread(id, true);
      }

      if (form.id === "startMessageForm") {
        event.preventDefault();
        const to = new FormData(form).get("to").trim();
        if (to) location.hash = `#/messages/${encodeURIComponent(to)}`;
      }

      if (form.id === "messageForm") {
        event.preventDefault();
        const to = form.dataset.to;
        const bodyEl = $("messageBody");
        const body = bodyEl.value;
        await api("/messages", { method: "POST", body: JSON.stringify({ to, body }) });
        bodyEl.value = "";
        await renderMessages(to, true);
      }
    } catch (err) {
      showNotice(err.message || "Request failed.", "error");
    }
  });

  window.addEventListener("hashchange", route);

  async function init() {
    await loadMe();
    await loadForums();
    await route();
    window.setInterval(() => softRefresh("poll"), 15000);
  }

  init();
})();
