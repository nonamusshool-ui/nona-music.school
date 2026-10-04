import { supabase } from "./supabase-client.js";
import { requireData } from "./learning-ui.js?v=3";

const el = (name) => document.getElementById(`chat-${name}`);
const dayFormatter = new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Kyiv", year: "numeric", month: "2-digit", day: "2-digit" });
const dateFormatter = new Intl.DateTimeFormat("uk-UA", { timeZone: "Europe/Kyiv", day: "numeric", month: "long", year: "numeric" });
const timeFormatter = new Intl.DateTimeFormat("uk-UA", { timeZone: "Europe/Kyiv", hour: "2-digit", minute: "2-digit" });
let role, userId, contacts = [], summaries = new Map(), active = null, channel = null;
const drafts = new Map();
let messages = [], hasOlder = false, busy = false, readBusy = false, pendingRead = null;
let initialized = false, openToken = 0, contactsToken = 0;

function error(message) {
  el("error").textContent = message;
  el("error").hidden = !message;
}

function status(message, retry = false) {
  el("status").textContent = message;
  el("status").hidden = !message;
  el("retry").hidden = !retry;
}

function dayKey(value) {
  const parts = Object.fromEntries(dayFormatter.formatToParts(new Date(value)).map(({ type, value: part }) => [type, part]));
  return `${parts.year}-${parts.month}-${parts.day}`;
}

function dayLabel(value) {
  const key = dayKey(value);
  const today = dayKey(Date.now());
  const yesterday = new Date(`${today}T12:00:00Z`);
  yesterday.setUTCDate(yesterday.getUTCDate() - 1);
  if (key === today) return "Сьогодні";
  if (key === yesterday.toISOString().slice(0, 10)) return "Вчора";
  return dateFormatter.format(new Date(value));
}

function nearBottom() {
  const log = el("log");
  return log.scrollHeight - log.scrollTop - log.clientHeight < 90;
}

function addMessageNode(message, previous) {
  if (!previous || dayKey(previous.created_at) !== dayKey(message.created_at)) {
    const divider = document.createElement("div");
    divider.className = "chat-day";
    divider.textContent = dayLabel(message.created_at);
    el("log").append(divider);
  }
  const item = document.createElement("div");
  item.className = `chat-bubble ${message.sender_id === userId ? "chat-bubble--own" : "chat-bubble--other"}`;
  const body = document.createElement("p");
  body.textContent = message.body;
  const time = document.createElement("time");
  time.dateTime = message.created_at;
  time.textContent = timeFormatter.format(new Date(message.created_at));
  item.append(body, time);
  el("log").append(item);
}

function redraw(preserve = false) {
  const log = el("log");
  const top = log.scrollTop;
  const height = log.scrollHeight;
  log.setAttribute("aria-live", "off");
  log.replaceChildren();
  for (let i = 0; i < messages.length; i++) addMessageNode(messages[i], messages[i - 1]);
  if (!messages.length) {
    const empty = document.createElement("p");
    empty.className = "chat-empty";
    empty.textContent = "Повідомлень поки немає. Напишіть першим.";
    log.append(empty);
  }
  log.scrollTop = preserve ? top + log.scrollHeight - height : log.scrollHeight;
  requestAnimationFrame(() => log.setAttribute("aria-live", "polite"));
}

function appendMessage(message) {
  if (messages.some((item) => item.id === message.id)) return;
  const atBottom = message.sender_id === userId || nearBottom();
  const previous = messages.at(-1);
  messages.push(message);
  if (messages.length === 1) el("log").replaceChildren();
  addMessageNode(message, previous);
  if (atBottom) {
    el("log").scrollTop = el("log").scrollHeight;
    if (message.sender_id !== userId && !document.hidden) markRead(active.id);
  } else el("new").hidden = false;
}

function renderContacts() {
  const list = el("contacts");
  list.replaceChildren();
  for (const contact of contacts) {
    const summary = summaries.get(contact.id);
    const button = document.createElement("button");
    button.type = "button";
    button.className = "chat-contact";
    button.classList.toggle("is-selected", active?.peer.id === contact.id);
    const name = document.createElement("strong");
    name.textContent = contact.name;
    const preview = document.createElement("span");
    preview.textContent = summary?.last_message_body || "Ще немає повідомлень";
    const meta = document.createElement("small");
    meta.textContent = summary?.last_message_at ? timeFormatter.format(new Date(summary.last_message_at)) : "";
    button.append(name, preview, meta);
    if (Number(summary?.unread_count) > 0) {
      const badge = document.createElement("b");
      badge.className = "chat-unread";
      badge.textContent = String(summary.unread_count);
      badge.setAttribute("aria-label", `${summary.unread_count} непрочитаних`);
      button.append(badge);
    }
    button.addEventListener("click", () => openConversation(contact, button));
    list.append(button);
  }
  const total = [...summaries.values()].reduce((n, row) => n + Number(row.unread_count || 0), 0);
  el("total-unread").textContent = String(total);
  el("total-unread").hidden = !total;
  el("layout").classList.toggle("chat-layout--single", role === "student" && contacts.length === 1);
}

async function refreshSummaries() {
  const rows = requireData(await supabase.rpc("my_conversation_summaries"));
  summaries = new Map(rows.map((row) => [row.other_user_id, row]));
  renderContacts();
}

async function loadContacts() {
  const token = ++contactsToken;
  status("Завантажуємо чат…");
  el("layout").hidden = true;
  try {
    const ownColumn = role === "student" ? "student_id" : "teacher_id";
    const otherColumn = role === "student" ? "teacher_id" : "student_id";
    const links = requireData(await supabase.from("teacher_students").select(otherColumn)
      .eq(ownColumn, userId).eq("active", true));
    const ids = [...new Set(links.map((link) => link[otherColumn]))];
    if (token !== contactsToken) return;
    if (!ids.length) {
      ++openToken;
      unsubscribe();
      active = null;
      el("panel").hidden = true;
      el("layout").classList.remove("is-conversation");
      contacts = [];
      status(role === "student" ? "Викладача ще не призначено." : "Призначених учнів поки немає.");
      return;
    }
    const people = requireData(await supabase.from("profiles").select("id,full_name,status").in("id", ids));
    if (token !== contactsToken) return;
    contacts = people.filter((person) => person.status === "active")
      .map((person) => ({ id: person.id, name: person.full_name || (role === "student" ? "Викладач НОНА" : "Учень НОНА") }));
    if (!contacts.length) { status("Чат недоступний."); return; }
    if (active && !contacts.some((person) => person.id === active.peer.id)) {
      ++openToken;
      unsubscribe();
      active = null;
      el("panel").hidden = true;
      el("layout").classList.remove("is-conversation");
    }
    await refreshSummaries();
    if (token !== contactsToken) return;
    status("");
    el("layout").hidden = false;
    if (role === "student" && contacts.length === 1 && !active) await openConversation(contacts[0]);
  } catch {
    if (token === contactsToken) status("Чат недоступний. Спробуйте ще раз.", true);
  }
}

async function loadLatest(conversationId, token) {
  error("");
  el("log").textContent = "Завантажуємо повідомлення…";
  el("retry-messages").hidden = true;
  try {
    const rows = requireData(await supabase.from("messages")
      .select("id,conversation_id,sender_id,body,created_at,read_at")
      .eq("conversation_id", conversationId)
      .order("created_at", { ascending: false }).order("id", { ascending: false }).limit(51));
    if (token !== openToken) return;
    hasOlder = rows.length > 50;
    messages = rows.slice(0, 50).reverse();
    el("older").hidden = !hasOlder;
    redraw();
    subscribe(conversationId, token);
    await markRead(conversationId);
  } catch {
    if (token !== openToken) return;
    el("log").textContent = "";
    error("Не вдалося завантажити повідомлення.");
    el("retry-messages").hidden = false;
  }
}

async function loadOlder() {
  if (!active || !hasOlder || busy || !messages.length) return;
  const conversationId = active.id;
  const cursor = messages[0];
  busy = true;
  el("older").disabled = true;
  try {
    const rows = requireData(await supabase.from("messages")
      .select("id,conversation_id,sender_id,body,created_at,read_at")
      .eq("conversation_id", conversationId)
      .or(`created_at.lt.${cursor.created_at},and(created_at.eq.${cursor.created_at},id.lt.${cursor.id})`)
      .order("created_at", { ascending: false }).order("id", { ascending: false }).limit(51));
    if (active?.id !== conversationId) return;
    hasOlder = rows.length > 50;
    messages = [...rows.slice(0, 50).reverse(), ...messages];
    el("older").hidden = !hasOlder;
    redraw(true);
  } catch { error("Не вдалося завантажити повідомлення."); }
  finally { busy = false; el("older").disabled = false; }
}

async function markRead(conversationId) {
  if (!conversationId || document.hidden) return;
  if (readBusy) { pendingRead = conversationId; return; }
  readBusy = true;
  try {
    requireData(await supabase.rpc("mark_conversation_read", { target_conversation_id: conversationId }));
    if (active?.id === conversationId) await refreshSummaries();
  } catch { /* A stale assignment or temporary network error must not hide history. */ }
  finally {
    readBusy = false;
    const next = pendingRead;
    pendingRead = null;
    if (next && active?.id === next) void markRead(next);
  }
}

function unsubscribe() {
  if (channel) {
    const previous = channel;
    channel = null;
    void supabase.removeChannel(previous);
  }
}

function subscribe(conversationId, token) {
  unsubscribe();
  channel = supabase.channel(`private-chat:${conversationId}`)
    .on("postgres_changes", { event: "INSERT", schema: "public", table: "messages",
      filter: `conversation_id=eq.${conversationId}` }, (payload) => {
      if (token !== openToken || active?.id !== conversationId) return;
      appendMessage(payload.new);
      void refreshSummaries().catch(() => {});
    }).subscribe((state) => {
      if (state !== "SUBSCRIBED" || token !== openToken) return;
      // Reconcile the small gap between initial SELECT and subscription readiness.
      void supabase.from("messages").select("id,conversation_id,sender_id,body,created_at,read_at")
        .eq("conversation_id", conversationId).order("created_at", { ascending: false })
        .order("id", { ascending: false }).limit(50).then((result) => {
          if (token !== openToken || result.error) return;
          for (const message of result.data.reverse()) appendMessage(message);
        });
    });
}

async function openConversation(peer, opener) {
  const token = ++openToken;
  if (active) drafts.set(active.id, el("draft").value);
  unsubscribe();
  active = null;
  el("panel").hidden = false;
  el("form").hidden = true;
  el("peer").textContent = peer.name;
  el("log").textContent = "Завантажуємо повідомлення…";
  el("new").hidden = true;
  el("layout").classList.add("is-conversation");
  el("back").hidden = role === "student" && contacts.length === 1;
  error("");
  try {
    const result = requireData(await supabase.rpc("open_assigned_conversation", { target_user_id: peer.id }));
    if (token !== openToken) return;
    active = { id: result.conversation_id, peer, opener };
    el("draft").value = drafts.get(active.id) || "";
    el("form").hidden = false;
    renderContacts();
    await loadLatest(active.id, token);
    if (opener && token === openToken) {
      el("peer").tabIndex = -1;
      el("peer").focus({ preventScroll: true });
    }
  } catch {
    if (token !== openToken) return;
    error("Чат недоступний.");
    el("retry-messages").hidden = false;
  }
}

async function send(event) {
  event.preventDefault();
  if (busy || !active) return;
  const body = el("draft").value.trim();
  if (!body || body.length > 4000) { error("Введіть повідомлення до 4000 символів."); return; }
  const conversationId = active.id;
  busy = true;
  el("send").disabled = true;
  error("");
  try {
    const message = requireData(await supabase.from("messages")
      .insert({ conversation_id: conversationId, sender_id: userId, body })
      .select("id,conversation_id,sender_id,body,created_at,read_at").single());
    drafts.set(conversationId, "");
    if (active?.id === conversationId) {
      el("draft").value = "";
      appendMessage(message);
      await refreshSummaries();
    }
  } catch { if (active?.id === conversationId) error("Не вдалося надіслати повідомлення."); }
  finally { busy = false; el("send").disabled = false; }
}

export function initChat(currentRole, currentUserId) {
  role = currentRole;
  userId = currentUserId;
  if (initialized) { void loadContacts(); return; }
  initialized = true;
  el("retry").addEventListener("click", loadContacts);
  el("retry-messages").addEventListener("click", () => {
    if (active) void loadLatest(active.id, openToken);
    else void loadContacts();
  });
  el("older").addEventListener("click", loadOlder);
  el("back").addEventListener("click", () => {
    ++openToken;
    unsubscribe();
    if (active) drafts.set(active.id, el("draft").value);
    const opener = active?.opener;
    active = null;
    el("panel").hidden = true;
    el("layout").classList.remove("is-conversation");
    renderContacts();
    if (opener?.isConnected) opener.focus();
  });
  el("new").addEventListener("click", () => {
    el("log").scrollTop = el("log").scrollHeight;
    el("new").hidden = true;
    void markRead(active?.id);
  });
  el("log").addEventListener("scroll", () => {
    if (!el("new").hidden && nearBottom()) { el("new").hidden = true; void markRead(active?.id); }
  });
  el("form").addEventListener("submit", send);
  el("draft").addEventListener("keydown", (event) => {
    if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
      event.preventDefault();
      el("form").requestSubmit();
    }
  });
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) { void refreshSummaries().catch(() => {}); if (nearBottom()) void markRead(active?.id); }
  });
  window.addEventListener("pagehide", unsubscribe);
  supabase.auth.onAuthStateChange((event) => {
    if (event === "SIGNED_OUT") { unsubscribe(); drafts.clear(); messages = []; active = null; }
  });
  void loadContacts();
}
