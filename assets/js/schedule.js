import { supabase } from "./supabase-client.js";
import { detail, kyivDay, kyivTime, lessonPlace, lessonStatuses, requireData } from "./learning-ui.js?v=3";
import { kyivMidnightUtc, mondayOf, shiftDay } from "./schedule-time.js?v=1";

const byId = (name) => document.getElementById(`schedule-${name}`);
const dayShort = new Intl.DateTimeFormat("uk-UA", { weekday: "short", timeZone: "UTC" });
const dayLong = new Intl.DateTimeFormat("uk-UA", { weekday: "long", day: "numeric", month: "long", timeZone: "UTC" });
const dayDate = new Intl.DateTimeFormat("uk-UA", { day: "numeric", month: "long", timeZone: "UTC" });
const rangeStart = new Intl.DateTimeFormat("uk-UA", { day: "numeric", month: "long", timeZone: "UTC" });
const rangeEnd = new Intl.DateTimeFormat("uk-UA", { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" });
const fullDate = new Intl.DateTimeFormat("uk-UA", { day: "numeric", month: "long", year: "numeric", timeZone: "Europe/Kyiv" });
const columns = "id,student_id,teacher_id,scheduled_at,duration_minutes,status,lesson_format,lesson_url,location_text,meet_url,package_id,consumes_lesson,resolved_at";

let role, userId, initialized = false, monday = mondayOf(kyivDay());
let lessons = [], names = new Map(), requestId = 0, detailOpener = null;

function civilDate(day) { return new Date(`${day}T12:00:00Z`); }
function statusLabel(value) {
  if (value === "cancelled") return "Скасовано";
  if (value === "no_show") return "Не проведено";
  return lessonStatuses[value] || "Статус невідомий";
}
function formatLabel(lesson) {
  const format = lesson.lesson_format || (lesson.lesson_url || lesson.meet_url ? "online" : lesson.location_text ? "offline" : null);
  return format === "online" ? "Онлайн" : format === "offline" ? "Офлайн" : "Формат не вказано";
}
function chargeLabel(lesson) {
  if (!lesson.package_id) return "Без пакета";
  if (lesson.consumes_lesson && (lesson.status === "completed"
    || (lesson.status === "cancelled" && lesson.resolved_at))) return "Списано 1 заняття";
  if (lesson.consumes_lesson && ["scheduled", "in_progress"].includes(lesson.status)) {
    return "Буде списано після проведення";
  }
  return "Не списано";
}
function person(id, fallback) { return names.get(id) || fallback; }
function identity(lesson) {
  const student = person(lesson.student_id, "Учень НОНА");
  const teacher = person(lesson.teacher_id, "Викладач НОНА");
  return role === "admin" ? `${student} · ${teacher}` : role === "teacher" ? student : teacher;
}

function openDetails(lesson, opener) {
  const dialog = byId("details-dialog");
  const body = byId("details");
  const when = new Date(lesson.scheduled_at);
  const fields = [
    detail("Дата", fullDate.format(when)),
    detail("Час", kyivTime.format(when)),
    detail("Тривалість", `${lesson.duration_minutes} хв`),
  ];
  if (role === "admin" || role === "teacher") fields.push(detail("Учень", person(lesson.student_id, "Учень НОНА")));
  if (role === "admin" || role === "student") fields.push(detail("Викладач", person(lesson.teacher_id, "Викладач НОНА")));
  fields.push(detail("Статус", statusLabel(lesson.status)),
    detail("Пакет", chargeLabel(lesson)));
  if (lesson.lesson_format || lesson.lesson_url || lesson.meet_url || lesson.location_text) {
    fields.push(lessonPlace({ ...lesson, lesson_format: lesson.lesson_format || (lesson.lesson_url || lesson.meet_url ? "online" : "offline") }));
  }
  else fields.push(detail("Формат", "Не вказано"));
  body.replaceChildren(...fields);
  detailOpener = opener;
  dialog.showModal();
  document.body.classList.add("admin-dialog-open");
  byId("details-close").focus();
}

function lessonCard(lesson) {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "schedule-lesson";
  const time = document.createElement("strong");
  time.textContent = kyivTime.format(new Date(lesson.scheduled_at));
  const name = document.createElement("span");
  name.className = "schedule-person";
  name.textContent = identity(lesson);
  const meta = document.createElement("span");
  meta.className = "schedule-meta";
  meta.textContent = `${lesson.duration_minutes} хв · ${formatLabel(lesson)}`;
  const badge = document.createElement("span");
  badge.className = `journal-badge journal-badge--${lesson.status}`;
  badge.textContent = statusLabel(lesson.status);
  button.append(time, name, meta, badge);
  button.addEventListener("click", () => openDetails(lesson, button));
  return button;
}

function render() {
  const teacherId = role === "admin" ? byId("teacher-filter").value : "";
  const visible = teacherId ? lessons.filter((lesson) => lesson.teacher_id === teacherId) : lessons;
  const empty = byId("empty");
  const grid = byId("grid");
  empty.textContent = lessons.length ? "Для цього викладача уроків на тижні немає." : "На цей тиждень уроків немає.";
  empty.hidden = Boolean(visible.length);
  const days = Array.from({ length: 7 }, (_, index) => shiftDay(monday, index));
  const grouped = new Map(days.map((day) => [day, []]));
  for (const lesson of visible) grouped.get(kyivDay(new Date(lesson.scheduled_at)))?.push(lesson);
  const fragment = document.createDocumentFragment();
  for (const day of days) {
    const column = document.createElement("div");
    column.className = "schedule-day";
    column.classList.toggle("is-today", day === kyivDay());
    const heading = document.createElement("h3");
    const date = civilDate(day);
    const short = document.createElement("span");
    short.className = "schedule-day-short";
    short.textContent = dayShort.format(date);
    const compact = document.createElement("span");
    compact.className = "schedule-day-date";
    compact.textContent = dayDate.format(date);
    const long = document.createElement("span");
    long.className = "schedule-day-long";
    long.textContent = dayLong.format(date);
    heading.append(short, compact, long);
    column.append(heading);
    const items = grouped.get(day);
    if (items.length) for (const lesson of items) column.append(lessonCard(lesson));
    else {
      const note = document.createElement("p");
      note.className = "schedule-day-empty";
      note.textContent = "Уроків немає";
      column.append(note);
    }
    fragment.append(column);
  }
  grid.replaceChildren(fragment);
  grid.hidden = false;
}

function updateTeacherFilter() {
  if (role !== "admin") return;
  const select = byId("teacher-filter");
  const selected = select.value;
  const ids = [...new Set(lessons.map((lesson) => lesson.teacher_id))];
  select.replaceChildren(new Option("Усі викладачі", ""));
  for (const id of ids) select.add(new Option(person(id, "Викладач НОНА"), id));
  select.value = ids.includes(selected) ? selected : "";
}

async function loadWeek() {
  const current = ++requestId;
  const from = kyivMidnightUtc(monday);
  const until = kyivMidnightUtc(shiftDay(monday, 7));
  byId("range").textContent = `${rangeStart.format(civilDate(monday))} — ${rangeEnd.format(civilDate(shiftDay(monday, 6)))}`;
  byId("status").textContent = "Завантажуємо розклад…";
  byId("retry").hidden = true;
  byId("empty").hidden = true;
  byId("grid").hidden = true;
  if (byId("details-dialog").open) byId("details-dialog").close();
  try {
    let query = supabase.from("lessons").select(columns)
      .gte("scheduled_at", from).lt("scheduled_at", until)
      .neq("status", "rescheduled").order("scheduled_at").limit(1000);
    if (role === "teacher") query = query.eq("teacher_id", userId);
    if (role === "student") query = query.eq("student_id", userId);
    const rows = requireData(await query);
    if (current !== requestId) return;
    const ids = [...new Set(rows.flatMap((lesson) => [lesson.student_id, lesson.teacher_id]))];
    let people = [];
    if (role === "student" && rows.length) people = requireData(await supabase.rpc("student_lesson_teacher_names"));
    else if (ids.length) people = requireData(await supabase.from("profiles").select("id,full_name").in("id", ids));
    if (current !== requestId) return;
    lessons = rows;
    names = new Map(people.map((person) => [person.id || person.teacher_id, person.full_name]));
    updateTeacherFilter();
    render();
    byId("status").textContent = rows.length === 1000 ? "Показано перші 1000 уроків цього тижня." : "";
  } catch {
    if (current !== requestId) return;
    byId("status").textContent = "Не вдалося завантажити розклад.";
    byId("retry").hidden = false;
  }
}

export function refreshSchedule() { return initialized ? loadWeek() : Promise.resolve(); }

export function initSchedule(currentRole, currentUserId) {
  if (initialized) { void refreshSchedule(); return; }
  role = currentRole;
  userId = currentUserId;
  initialized = true;
  byId("prev").addEventListener("click", () => { monday = shiftDay(monday, -7); void loadWeek(); });
  byId("next").addEventListener("click", () => { monday = shiftDay(monday, 7); void loadWeek(); });
  byId("today").addEventListener("click", () => { monday = mondayOf(kyivDay()); void loadWeek(); });
  byId("refresh").addEventListener("click", refreshSchedule);
  byId("retry").addEventListener("click", refreshSchedule);
  if (role === "admin") {
    byId("admin-filter").hidden = false;
    byId("teacher-filter").addEventListener("change", render);
  }
  const dialog = byId("details-dialog");
  byId("details-close").addEventListener("click", () => dialog.close());
  dialog.addEventListener("click", (event) => { if (event.target === dialog) dialog.close(); });
  dialog.addEventListener("close", () => {
    document.body.classList.remove("admin-dialog-open");
    if (detailOpener?.isConnected) detailOpener.focus();
    detailOpener = null;
  });
  void loadWeek();
}
