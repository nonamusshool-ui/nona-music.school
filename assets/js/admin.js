import { supabase } from "./supabase-client.js";
import { initAdminLearning, openAdminLearning } from "./admin-learning.js?v=3";
import { initAdminJournal } from "./admin-journal.js?v=2";
import { initChat } from "./chat.js?v=3";

const roles = { student: "Учень", teacher: "Викладач", admin: "Адміністратор" };
const statuses = { pending: "Очікує", active: "Активний", suspended: "Призупинено" };
const metricNames = ["students", "teachers", "lessons_today", "active_packages"];
const dateFormat = new Intl.DateTimeFormat("uk-UA", { dateStyle: "medium", timeZone: "Europe/Kyiv" });
const page = {
  filter: document.getElementById("admin-filter"),
  search: document.getElementById("admin-search"),
  feedback: document.getElementById("admin-feedback"),
  metricsLoading: document.getElementById("admin-metrics-loading"),
  metricsError: document.getElementById("admin-metrics-error"),
  usersLoading: document.getElementById("admin-users-loading"),
  usersError: document.getElementById("admin-users-error"),
  resultsCount: document.getElementById("admin-results-count"),
  usersEmpty: document.getElementById("admin-users-empty"),
  tableWrap: document.getElementById("admin-table-wrap"),
  usersBody: document.getElementById("admin-users-body"),
  dialog: document.getElementById("admin-access-dialog"),
  form: document.getElementById("admin-access-form"),
  dialogName: document.getElementById("admin-dialog-name"),
  dialogEmail: document.getElementById("admin-dialog-email"),
  currentAccess: document.getElementById("admin-current-access"),
  role: document.getElementById("admin-role"),
  status: document.getElementById("admin-status"),
  dialogError: document.getElementById("admin-dialog-error"),
  save: document.getElementById("admin-dialog-save"),
};

let ownUserId = null;
let users = [];
let selectedUser = null;
let opener = null;
let initialized = false;

function showDialogError(message) {
  page.dialogError.textContent = message;
  page.dialogError.hidden = false;
}

function cell(label, value) {
  const item = document.createElement("td");
  item.dataset.label = label;
  if (value instanceof Node) item.append(value);
  else item.textContent = value;
  return item;
}

function matchesFilter(user) {
  const filter = page.filter.value;
  if (filter === "pending" || filter === "suspended") return user.status === filter;
  if (filter === "student" || filter === "teacher" || filter === "admin") return user.role === filter;
  return true;
}

function renderUsers() {
  const search = page.search.value.trim().toLocaleLowerCase("uk");
  const visible = users.filter((user) => matchesFilter(user)
    && (!search || [user.full_name, user.email].some((value) => (value || "").toLocaleLowerCase("uk").includes(search))));
  const rows = document.createDocumentFragment();

  for (const user of visible) {
    const row = document.createElement("tr");
    row.append(
      cell("Ім’я", user.full_name || "Ім’я не вказано"),
      cell("Email", user.email || "Не вказано"),
      cell("Телефон", user.phone || "Не вказано"),
      cell("Роль", roles[user.role] || "Не призначено")
    );
    const badge = document.createElement("span");
    badge.className = `admin-state admin-state-${user.status}`;
    badge.textContent = statuses[user.status] || user.status;
    row.append(cell("Статус", badge));
    row.append(cell("Створено", user.created_at ? dateFormat.format(new Date(user.created_at)) : "—"));

    if (user.id === ownUserId) {
      row.append(cell("Дія", "Власний обліковий запис"));
    } else {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "button button-light admin-manage";
      button.textContent = "Керувати";
      button.addEventListener("click", () => openManage(user, button));
      if (user.role === "student" && user.status === "active") {
        const actions = document.createElement("div");
        actions.className = "admin-row-actions";
        const learning = document.createElement("button");
        learning.type = "button";
        learning.className = "button admin-manage";
        learning.textContent = "Навчання";
        learning.addEventListener("click", () => openAdminLearning(user, learning));
        actions.append(button, learning);
        row.append(cell("Дія", actions));
      } else row.append(cell("Дія", button));
    }
    rows.append(row);
  }
  page.usersBody.replaceChildren(rows);
  page.tableWrap.hidden = visible.length === 0;
  page.usersEmpty.hidden = visible.length !== 0;
  page.resultsCount.hidden = false;
  page.resultsCount.textContent = `Показано ${visible.length} з ${users.length} користувачів`;
}

async function loadMetrics() {
  page.metricsLoading.hidden = false;
  page.metricsError.hidden = true;
  for (const name of metricNames) {
    const value = document.querySelector(`[data-metric="${name}"]`);
    value.replaceChildren();
    const skeleton = document.createElement("span");
    skeleton.className = "admin-skeleton";
    skeleton.setAttribute("aria-hidden", "true");
    value.append(skeleton);
  }
  try {
    const { data, error } = await supabase.rpc("admin_dashboard_metrics").single();
    if (error || !data) throw error || new Error("Missing metrics");
    for (const name of metricNames) {
      const count = Number(data[name]);
      if (!Number.isSafeInteger(count) || count < 0) throw new Error("Invalid metrics");
      document.querySelector(`[data-metric="${name}"]`).textContent = count.toLocaleString("uk-UA");
    }
    page.metricsLoading.hidden = true;
  } catch {
    page.metricsLoading.hidden = true;
    page.metricsError.hidden = false;
  }
}

async function loadUsers() {
  page.usersLoading.hidden = false;
  page.usersError.hidden = true;
  page.tableWrap.hidden = true;
  page.usersEmpty.hidden = true;
  page.resultsCount.hidden = true;
  try {
    const all = [];
    const pageSize = 500;
    for (let offset = 0; ; offset += pageSize) {
      const { data, error } = await supabase.rpc("admin_list_users").range(offset, offset + pageSize - 1);
      if (error || !Array.isArray(data)) throw error || new Error("Missing users");
      all.push(...data);
      if (data.length < pageSize) break;
    }
    users = all;
    page.usersLoading.hidden = true;
    renderUsers();
  } catch {
    page.usersLoading.hidden = true;
    page.usersError.hidden = false;
  }
}

function openManage(user, button) {
  if (user.id === ownUserId) return;
  selectedUser = user;
  opener = button;
  page.dialogName.textContent = user.full_name || "Ім’я не вказано";
  page.dialogEmail.textContent = user.email || "Email не вказано";
  page.currentAccess.textContent = `Зараз: ${roles[user.role] || "роль не призначено"} · ${statuses[user.status] || user.status}`;
  page.role.value = user.role || "";
  page.status.value = user.status;
  page.dialogError.hidden = true;
  page.dialog.showModal();
  document.body.classList.add("admin-dialog-open");
  page.role.focus();
}

async function saveAccess(event) {
  event.preventDefault();
  if (!selectedUser || selectedUser.id === ownUserId) return;
  const role = page.role.value || null;
  const status = page.status.value;
  if (status === "active" && !role) {
    showDialogError("Для активного кабінету оберіть роль.");
    return;
  }
  if (role === selectedUser.role && status === selectedUser.status) {
    page.dialog.close();
    return;
  }
  if (status === "suspended" && selectedUser.status !== "suspended"
    && !window.confirm("Призупинити доступ цього користувача до кабінету?")) return;

  page.save.disabled = true;
  page.save.textContent = "Зберігаємо…";
  document.getElementById("admin-dialog-close").disabled = true;
  document.getElementById("admin-dialog-cancel").disabled = true;
  page.dialogError.hidden = true;
  try {
    const { data, error } = await supabase.rpc("admin_update_user_access", {
      target_user_id: selectedUser.id,
      new_role: role,
      new_status: status,
    }).single();
    if (error || !data) throw error || new Error("Missing updated user");
    users = users.map((user) => user.id === data.id ? data : user);
    renderUsers();
    page.dialog.close();
    page.feedback.classList.remove("is-error");
    page.feedback.textContent = "Доступ користувача оновлено.";
    await loadMetrics();
  } catch (error) {
    showDialogError(error?.code === "42501"
      ? "Немає прав для цієї дії. Перевірте свій доступ."
      : error?.code === "23514"
        ? "Роль не можна змінити, поки з акаунтом пов’язані учні, уроки або пакети. Статус можна змінити окремо."
      : "Не вдалося зберегти зміни. Спробуйте ще раз.");
  } finally {
    page.save.disabled = false;
    page.save.textContent = "Зберегти зміни";
    document.getElementById("admin-dialog-close").disabled = false;
    document.getElementById("admin-dialog-cancel").disabled = false;
  }
}

export function initAdmin(userId) {
  ownUserId = userId;
  if (!initialized) {
    initialized = true;
    page.filter.addEventListener("change", renderUsers);
    page.search.addEventListener("input", renderUsers);
    document.getElementById("admin-metrics-retry").addEventListener("click", loadMetrics);
    document.getElementById("admin-users-retry").addEventListener("click", loadUsers);
    document.getElementById("admin-dialog-close").addEventListener("click", () => page.dialog.close());
    document.getElementById("admin-dialog-cancel").addEventListener("click", () => page.dialog.close());
    page.dialog.addEventListener("cancel", (event) => {
      if (page.save.disabled) event.preventDefault();
    });
    page.dialog.addEventListener("close", () => {
      document.body.classList.remove("admin-dialog-open");
      selectedUser = null;
      if (opener?.isConnected) opener.focus();
      else page.filter.focus();
      opener = null;
    });
    page.form.addEventListener("submit", saveAccess);
    initAdminLearning();
    initAdminJournal();
  }
  initChat("admin", userId);
  loadMetrics();
  loadUsers();
}
