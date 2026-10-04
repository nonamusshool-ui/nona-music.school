import { supabase } from "./supabase-client.js";
import { detail, empty, kyivDateTime, kyivDay, lessonPlace, lessonStatuses, outcomeReasons, requireData } from "./learning-ui.js?v=3";
import { initChat } from "./chat.js?v=3";
import { initSchedule, refreshSchedule } from "./schedule.js?v=1";

const targets = {
  next: document.getElementById("student-next"),
  package: document.getElementById("student-package"),
  teacher: document.getElementById("student-teacher"),
  history: document.getElementById("student-history"),
};
const status = document.getElementById("cabinet-status");
const refresh = document.getElementById("student-refresh");
let studentId;
let studentInitialized = false;

function renderPackage(packages) {
  const today = kyivDay();
  const active = packages.filter((item) => item.status === "active"
      && (!item.valid_from || item.valid_from <= today)
      && (!item.valid_until || item.valid_until >= today))
    .sort((a, b) => (b.valid_from || "").localeCompare(a.valid_from || ""));
  if (!active.length) {
    targets.package.replaceChildren(empty("Активного пакета поки немає"));
    return;
  }
  const rows = active.map((item) => {
    const box = document.createElement("div");
    box.className = "package-summary";
    if (active.length > 1) box.append(detail("Пакет", item.valid_from ? `від ${item.valid_from}` : "без дати початку"));
    const stats = document.createElement("div");
    stats.className = "placeholder-stats";
    for (const [label, value] of [["Придбано", item.lessons_purchased], ["Списано", item.lessons_used], ["Залишилось", item.lessons_remaining]]) {
      const part = document.createElement("div");
      const caption = document.createElement("span");
      const number = document.createElement("strong");
      caption.textContent = label;
      number.textContent = String(value);
      part.append(caption, number);
      stats.append(part);
    }
    box.append(stats);
    return box;
  });
  targets.package.replaceChildren(...rows);
}

async function loadStudent() {
  refresh.disabled = true;
  status.textContent = "Завантажуємо дані…";
  status.classList.remove("is-error");
  for (const element of Object.values(targets)) element.textContent = "Завантажуємо…";
  try {
    const [nextResult, activeResult, historyResult, assignmentResult, packagesResult] = await Promise.all([
      supabase.from("lessons").select("id,scheduled_at,duration_minutes,teacher_id,lesson_format,lesson_url,location_text,meet_url")
        .eq("student_id", studentId).eq("status", "scheduled")
        .gte("scheduled_at", new Date().toISOString()).order("scheduled_at").limit(1),
      supabase.from("lessons").select("id,scheduled_at,started_at,duration_minutes,teacher_id,lesson_format,lesson_url,location_text,meet_url,status")
        .eq("student_id", studentId).eq("status", "in_progress")
        .order("started_at", { ascending: false }).limit(1),
      supabase.from("lessons").select("id,scheduled_at,duration_minutes,teacher_id,homework,status,outcome_reason")
        .eq("student_id", studentId).in("status", ["completed", "cancelled", "rescheduled", "no_show"])
        .order("scheduled_at", { ascending: false }).limit(10),
      supabase.from("teacher_students").select("teacher_id")
        .eq("student_id", studentId).eq("active", true),
      supabase.from("package_balances").select("package_id,lessons_purchased,lessons_used,lessons_remaining,status,valid_from,valid_until")
        .eq("student_id", studentId),
    ]);
    const next = requireData(activeResult)[0] || requireData(nextResult)[0];
    const history = requireData(historyResult);
    const assignments = requireData(assignmentResult);
    const packages = requireData(packagesResult);
    const teacherIds = [...new Set(assignments.map((item) => item.teacher_id))];
    const names = new Map();
    const lessonTeachers = requireData(await supabase.rpc("student_lesson_teacher_names"));
    for (const teacher of lessonTeachers) names.set(teacher.teacher_id, teacher.full_name || "Викладач НОНА");
    if (teacherIds.length) {
      const teachers = requireData(await supabase.from("profiles").select("id,full_name").in("id", teacherIds));
      for (const teacher of teachers) names.set(teacher.id, teacher.full_name || "Викладач НОНА");
    }

    if (next) {
      const box = document.createElement("div");
      box.className = "learning-item";
      box.append(detail("Коли", kyivDateTime.format(new Date(next.scheduled_at))),
        detail("Викладач", names.get(next.teacher_id) || "Викладач НОНА"),
        detail("Тривалість", `${next.duration_minutes} хв`),
        detail("Статус", lessonStatuses[next.status] || "Заплановано"), lessonPlace(next));
      targets.next.replaceChildren(box);
    } else targets.next.replaceChildren(empty("Наступний урок ще не заплановано"));
    renderPackage(packages);
    targets.teacher.replaceChildren(assignments.length
      ? detail("Викладач", assignments.map((item) => names.get(item.teacher_id) || "Викладач НОНА").join(", "))
      : empty("Викладача ще не призначено"));
    if (history.length) {
      const list = document.createElement("div");
      list.className = "learning-list";
      for (const lesson of history) {
        const item = document.createElement("div");
        item.className = "learning-item";
        item.append(detail("Коли", kyivDateTime.format(new Date(lesson.scheduled_at))),
          detail("Тривалість", `${lesson.duration_minutes} хв`),
          detail("Викладач", names.get(lesson.teacher_id) || "Викладач НОНА"),
          detail("Результат", lessonStatuses[lesson.status] || "Не проведено"));
        if (lesson.outcome_reason) item.append(detail("Причина", outcomeReasons[lesson.outcome_reason] || "Інше"));
        if (lesson.status === "completed" && lesson.homework?.trim()) item.append(detail("Домашнє завдання", lesson.homework));
        list.append(item);
      }
      targets.history.replaceChildren(list);
    } else targets.history.replaceChildren(empty("Історія з’явиться після першого заняття."));
    status.textContent = "";
  } catch {
    for (const element of Object.values(targets)) element.replaceChildren(empty("Не вдалося завантажити дані. Спробуйте ще раз."));
    status.textContent = "Не вдалося оновити кабінет.";
    status.classList.add("is-error");
  } finally {
    refresh.disabled = false;
  }
}

export function initStudent(id) {
  studentId = id;
  if (studentInitialized) {
    loadStudent();
    initChat("student", id);
    initSchedule("student", id);
    return;
  }
  studentInitialized = true;
  refresh.addEventListener("click", () => { loadStudent(); refreshSchedule(); });
  initChat("student", id);
  initSchedule("student", id);
  loadStudent();
}
