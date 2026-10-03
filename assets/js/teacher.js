import { supabase } from "./supabase-client.js";
import { detail, empty, kyivDateTime, kyivDay, kyivTime, meetLink, requireData } from "./learning-ui.js";

const todayTarget = document.getElementById("teacher-today");
const studentsTarget = document.getElementById("teacher-students");
const status = document.getElementById("cabinet-status");
const refresh = document.getElementById("teacher-refresh");
let teacherId;

function makeLesson(lesson, studentName) {
  const item = document.createElement("div");
  item.className = "learning-item";
  item.append(detail("Час", kyivTime.format(new Date(lesson.scheduled_at))),
    detail("Учень", studentName), detail("Тривалість", `${lesson.duration_minutes} хв`),
    detail("Статус", lesson.status === "completed" ? "Проведено" : lesson.status === "scheduled" ? "Заплановано" : lesson.status));
  const link = meetLink(lesson.meet_url);
  if (link) item.append(link);
  if (lesson.status === "scheduled") {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "button";
    button.textContent = "Урок проведено";
    button.disabled = Date.now() < new Date(lesson.scheduled_at).getTime() + lesson.duration_minutes * 60000;
    if (button.disabled) button.title = "Можна позначити після завершення уроку";
    button.addEventListener("click", async () => {
      button.disabled = true;
      button.textContent = "Зберігаємо…";
      try {
        requireData(await supabase.rpc("teacher_complete_lesson", { target_lesson_id: lesson.id }));
        await loadTeacher();
      } catch {
        status.textContent = "Не вдалося позначити урок проведеним. Оновіть дані й спробуйте ще раз.";
        status.classList.add("is-error");
        button.disabled = false;
        button.textContent = "Урок проведено";
      }
    });
    item.append(button);
  }
  return item;
}

async function loadTeacher() {
  refresh.disabled = true;
  status.textContent = "Завантажуємо дані…";
  status.classList.remove("is-error");
  todayTarget.textContent = "Завантажуємо…";
  studentsTarget.textContent = "Завантажуємо…";
  try {
    const assignments = requireData(await supabase.from("teacher_students")
      .select("student_id").eq("teacher_id", teacherId).eq("active", true));
    const ids = assignments.map((item) => item.student_id);
    const now = new Date();
    // Wider UTC window covers every Kyiv calendar day, including DST transitions.
    const from = new Date(now.getTime() - 36 * 3600000).toISOString();
    const to = new Date(now.getTime() + 60 * 3600000).toISOString();
    const [dayResult, nextResult] = await Promise.all([
      supabase.from("lessons").select("id,student_id,scheduled_at,duration_minutes,status,meet_url")
        .eq("teacher_id", teacherId).gte("scheduled_at", from).lt("scheduled_at", to)
        .order("scheduled_at").limit(200),
      supabase.from("lessons").select("id,student_id,scheduled_at")
        .eq("teacher_id", teacherId).eq("status", "scheduled")
        .gte("scheduled_at", now.toISOString()).order("scheduled_at").limit(200),
    ]);
    const lessons = requireData(dayResult).filter((item) => kyivDay(new Date(item.scheduled_at)) === kyivDay(now));
    const upcoming = requireData(nextResult);
    const names = new Map();
    if (ids.length) {
      const students = requireData(await supabase.from("profiles").select("id,full_name").in("id", ids));
      for (const student of students) names.set(student.id, student.full_name || "Учень НОНА");
    }
    if (lessons.length) {
      const list = document.createElement("div");
      list.className = "learning-list";
      for (const lesson of lessons) list.append(makeLesson(lesson, names.get(lesson.student_id) || "Учень НОНА"));
      todayTarget.replaceChildren(list);
    } else todayTarget.replaceChildren(empty("На сьогодні уроків немає"));

    if (ids.length) {
      const balances = requireData(await supabase.from("package_balances")
        .select("student_id,lessons_remaining,status,valid_from,valid_until").in("student_id", ids));
      const list = document.createElement("div");
      list.className = "learning-list";
      for (const id of ids) {
        const item = document.createElement("div");
        item.className = "learning-item";
        const heading = document.createElement("h4");
        heading.textContent = names.get(id) || "Учень НОНА";
        item.append(heading);
        const next = upcoming.find((lesson) => lesson.student_id === id);
        item.append(detail("Наступний урок", next ? kyivDateTime.format(new Date(next.scheduled_at)) : "не заплановано"));
        const today = kyivDay();
        const active = balances.filter((balance) => balance.student_id === id && balance.status === "active"
          && (!balance.valid_from || balance.valid_from <= today)
          && (!balance.valid_until || balance.valid_until >= today));
        item.append(detail("Залишок занять", active.length
          ? active.reduce((sum, balance) => sum + Number(balance.lessons_remaining), 0)
          : "активного пакета немає"));
        list.append(item);
      }
      studentsTarget.replaceChildren(list);
    } else studentsTarget.replaceChildren(empty("Учнів ще не призначено"));
    status.textContent = "";
  } catch {
    todayTarget.replaceChildren(empty("Не вдалося завантажити розклад."));
    studentsTarget.replaceChildren(empty("Не вдалося завантажити учнів."));
    status.textContent = "Перевірте з’єднання та натисніть «Оновити дані».";
    status.classList.add("is-error");
  } finally {
    refresh.disabled = false;
  }
}

export function initTeacher(id) {
  teacherId = id;
  refresh.addEventListener("click", loadTeacher);
  loadTeacher();
}
