import { supabase } from "./supabase-client.js";
import { detail, kyivDate, kyivDateTime, kyivTime, lessonStatuses, outcomeReasons, safeLessonUrl } from "./learning-ui.js?v=3";

const pageSize = 100;
const monthName = new Intl.DateTimeFormat("uk-UA", { month: "long", year: "numeric", timeZone: "UTC" });
const monthParts = new Intl.DateTimeFormat("en-US", { year: "numeric", month: "2-digit", timeZone: "Europe/Kyiv" });
const elements = {
  month: document.getElementById("journal-month-label"), prev: document.getElementById("journal-prev"), next: document.getElementById("journal-next"),
  teacher: document.getElementById("journal-teacher"), student: document.getElementById("journal-student"),
  status: document.getElementById("journal-status"), search: document.getElementById("journal-search"),
  summary: document.getElementById("journal-summary"), summaryScope: document.getElementById("journal-summary-scope"),
  loading: document.getElementById("journal-loading"),
  error: document.getElementById("journal-error"), retry: document.getElementById("journal-retry"),
  empty: document.getElementById("journal-empty"), count: document.getElementById("journal-count"),
  wrap: document.getElementById("journal-table-wrap"), body: document.getElementById("journal-body"),
  more: document.getElementById("journal-more"), dialog: document.getElementById("journal-details-dialog"),
  details: document.getElementById("journal-details"), close: document.getElementById("journal-details-close"),
};

function currentKyivMonth() {
  const parts = Object.fromEntries(monthParts.formatToParts(new Date()).map(({ type, value }) => [type, value]));
  return `${parts.year}-${parts.month}-01`;
}

let month = currentKyivMonth();
let rows = [];
let total = 0;
let generation = 0;
let busy = false;
let opener = null;

function shiftMonth(amount) {
  const [year, number] = month.split("-").map(Number);
  const date = new Date(Date.UTC(year, number - 1 + amount, 1));
  month = `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, "0")}-01`;
  elements.month.textContent = monthName.format(date);
  elements.teacher.value = "";
  elements.student.value = "";
  loadJournal();
}

function setOptions(select, values, allLabel) {
  const selected = select.value;
  select.replaceChildren(new Option(allLabel, ""));
  for (const item of values) select.add(new Option(item.name || "Ім’я не вказано", item.id));
  select.value = values.some(({ id }) => id === selected) ? selected : "";
}

function renderSummary(summary) {
  const labels = [
    ["total", "Усього уроків"], ["completed", "Проведено"],
    ["cancelled", "Не проведено / скасовано"], ["rescheduled", "Перенесено"],
    ["scheduled", "Заплановано"], ["in_progress", "Триває"],
    ["charged", "Списано занять з пакетів"],
  ];
  const cards = document.createDocumentFragment();
  for (const [key, label] of labels) {
    const card = document.createElement("div");
    card.className = "overview-card";
    const caption = document.createElement("span");
    const value = document.createElement("strong");
    caption.textContent = label;
    value.textContent = Number(summary[key] || 0).toLocaleString("uk-UA");
    card.append(caption, value);
    cards.append(card);
  }
  elements.summary.replaceChildren(cards);
}

function cell(label, value) {
  const td = document.createElement("td");
  td.dataset.label = label;
  if (value instanceof Node) td.append(value);
  else td.textContent = value;
  return td;
}

function packageText(lesson) {
  if (!lesson.package_id) return "Без пакета · не списано";
  return `${lesson.lessons_purchased ? `Пакет ${lesson.lessons_purchased} занять` : "Пакет"} · ${lesson.charged ? "Списано 1 заняття" : "Не списано"}`;
}

function renderRows() {
  const fragment = document.createDocumentFragment();
  for (const lesson of rows) {
    const tr = document.createElement("tr");
    const when = document.createElement("span");
    when.append(document.createTextNode(kyivDate.format(new Date(lesson.scheduled_at))));
    const time = document.createElement("small");
    time.textContent = kyivTime.format(new Date(lesson.scheduled_at));
    when.append(time);
    const badge = document.createElement("span");
    badge.className = `journal-badge journal-badge--${lesson.status}`;
    badge.textContent = lessonStatuses[lesson.status] || "Невідомий статус";
    const reason = outcomeReasons[lesson.outcome_reason] || (lesson.outcome_reason ? "Інша причина" : "—");
    const reasonLabel = document.createElement("span");
    reasonLabel.textContent = reason;
    if (lesson.outcome_note) {
      const note = document.createElement("small");
      note.textContent = "Є коментар";
      reasonLabel.append(note);
    }
    const button = document.createElement("button");
    button.type = "button";
    button.className = "button button-light";
    button.textContent = "Деталі";
    button.setAttribute("aria-label", `Деталі уроку: ${lesson.student_name}, ${kyivDateTime.format(new Date(lesson.scheduled_at))}`);
    button.addEventListener("click", () => openDetails(lesson, button));
    tr.append(cell("Дата · час", when), cell("Учень", lesson.student_name),
      cell("Викладач", lesson.teacher_name), cell("Тривалість", `${lesson.duration_minutes} хв`),
      cell("Статус", badge), cell("Пакет / списання", packageText(lesson)),
      cell("Причина", reasonLabel), cell("Дія", button));
    fragment.append(tr);
  }
  elements.body.replaceChildren(fragment);
  elements.wrap.hidden = rows.length === 0;
  elements.empty.hidden = rows.length !== 0;
  if (!rows.length) elements.empty.textContent =
    elements.teacher.value || elements.student.value || elements.status.value || elements.search.value.trim()
      ? "За вибраними фільтрами уроків немає." : "У цьому місяці уроків ще немає.";
  elements.count.hidden = rows.length === 0;
  elements.count.textContent = `Показано ${rows.length} із ${total} уроків`;
  elements.more.hidden = rows.length >= total;
}

function openDetails(lesson, button) {
  opener = button;
  const fields = [
    ["Учень", lesson.student_name], ["Викладач", lesson.teacher_name],
    ["Планова дата і час (Київ)", kyivDateTime.format(new Date(lesson.scheduled_at))],
    ["Тривалість", `${lesson.duration_minutes} хв`],
    ["Формат", lesson.lesson_format === "online" ? "Онлайн" : lesson.lesson_format === "offline" ? "Офлайн" : "Не вказано"],
    ["Місце", lesson.location_text],
    ["Статус", lessonStatuses[lesson.status] || "Невідомий статус"],
    ["Пакет", lesson.package_id ? `Пакет ${lesson.lessons_purchased || "—"} занять` : "Без пакета"],
    ["Списання", lesson.charged ? "Списано 1 заняття" : "Не списано"],
    ["Причина", outcomeReasons[lesson.outcome_reason] || (lesson.outcome_reason ? "Інша причина" : "—")],
    ["Коментар викладача", lesson.outcome_note],
    ["scheduled_at (UTC)", lesson.scheduled_at ? new Date(lesson.scheduled_at).toISOString() : null],
    ["started_at (UTC)", lesson.started_at ? new Date(lesson.started_at).toISOString() : null],
    ["completed_at (UTC)", lesson.completed_at ? new Date(lesson.completed_at).toISOString() : null],
    ["resolved_at (UTC)", lesson.resolved_at ? new Date(lesson.resolved_at).toISOString() : null],
    ["Завершення", lesson.completion_source === "automatic" ? "Проведено автоматично" : lesson.completion_source === "teacher" ? "Завершив викладач" : "—"],
  ];
  const content = document.createDocumentFragment();
  for (const [label, value] of fields) content.append(detail(label, value));
  const url = safeLessonUrl(lesson.lesson_url || lesson.meet_url);
  if (url) {
    const line = document.createElement("p");
    const link = document.createElement("a");
    link.href = url;
    link.target = "_blank";
    link.rel = "noopener noreferrer";
    link.textContent = "Відкрити посилання на заняття";
    line.append(link);
    content.append(line);
  }
  elements.details.replaceChildren(content);
  elements.dialog.showModal();
  document.body.classList.add("admin-dialog-open");
  elements.close.focus();
}

async function loadJournal(append = false) {
  if (busy && append) return;
  const request = ++generation;
  busy = true;
  elements.loading.hidden = false;
  elements.loading.textContent = append ? "Завантажуємо наступні уроки…" : "Завантажуємо журнал…";
  elements.error.hidden = true;
  elements.more.hidden = true;
  if (!append) {
    rows = [];
    total = 0;
    elements.summary.replaceChildren();
    elements.body.replaceChildren();
    elements.wrap.hidden = true;
    elements.empty.hidden = true;
    elements.count.hidden = true;
  }
  try {
    const { data, error } = await supabase.rpc("admin_lesson_journal", {
      month_start: month, teacher_filter: elements.teacher.value || null,
      student_filter: elements.student.value || null, status_filter: elements.status.value || null,
      name_query: elements.search.value.trim() || null, page_size: pageSize,
      page_offset: append ? rows.length : 0,
    });
    if (request !== generation) return;
    if (error || !data || !Array.isArray(data.rows)) throw error || new Error("Invalid journal response");
    rows = append ? rows.concat(data.rows) : data.rows;
    total = Number(data.total) || 0;
    setOptions(elements.teacher, data.teachers || [], "Усі викладачі");
    setOptions(elements.student, data.students || [], "Усі учні");
    elements.summaryScope.textContent = elements.teacher.value || elements.student.value || elements.status.value || elements.search.value.trim()
      ? "Підсумок за вибраними фільтрами" : "Підсумок місяця";
    renderSummary(data.summary || {});
    renderRows();
  } catch {
    if (request === generation) elements.error.hidden = false;
  } finally {
    if (request === generation) {
      busy = false;
      elements.loading.hidden = true;
      if (elements.error.hidden) elements.more.hidden = rows.length >= total;
    }
  }
}

export function initAdminJournal() {
  elements.month.textContent = monthName.format(new Date(`${month}T12:00:00Z`));
  elements.prev.addEventListener("click", () => shiftMonth(-1));
  elements.next.addEventListener("click", () => shiftMonth(1));
  for (const select of [elements.teacher, elements.student, elements.status]) select.addEventListener("change", () => loadJournal());
  let timer;
  elements.search.addEventListener("input", () => {
    clearTimeout(timer);
    timer = setTimeout(() => loadJournal(), 250);
  });
  elements.retry.addEventListener("click", () => loadJournal(rows.length > 0));
  elements.more.addEventListener("click", () => loadJournal(true));
  elements.close.addEventListener("click", () => elements.dialog.close());
  elements.dialog.addEventListener("click", (event) => { if (event.target === elements.dialog) elements.dialog.close(); });
  elements.dialog.addEventListener("close", () => {
    document.body.classList.remove("admin-dialog-open");
    if (opener?.isConnected) opener.focus();
    opener = null;
  });
  loadJournal();
}
