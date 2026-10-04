import { supabase } from "./supabase-client.js";
import { detail, empty, kyivDateTime, kyivDay, kyivTime, lessonPlace, lessonStatuses,
  outcomeReasons, requireData } from "./learning-ui.js?v=3";
import { completeTeacherLesson, initTeacherActions, openTeacherOutcome,
  openTeacherSchedule, startTeacherLesson } from "./teacher-actions.js?v=4";
import { initChat } from "./chat.js?v=2";

const todayTarget = document.getElementById("teacher-today");
const studentsTarget = document.getElementById("teacher-students");
const upcomingTarget = document.getElementById("teacher-upcoming");
const status = document.getElementById("cabinet-status");
const refresh = document.getElementById("teacher-refresh");
const lessonColumns = "id,student_id,package_id,scheduled_at,duration_minutes,status,started_at,consumes_lesson,lesson_format,lesson_url,location_text,meet_url,outcome_reason,outcome_note,resolved_at";
let teacherId;
let teacherInitialized = false;

function reportStatus(message, isError = false) {
  status.textContent = message;
  status.classList.toggle("is-error", isError);
}

function action(label, handler, style = "button button-light") {
  const button = document.createElement("button");
  button.type = "button";
  button.className = style;
  button.textContent = label;
  button.addEventListener("click", () => handler(button));
  return button;
}

function lessonCard(lesson, student) {
  const item = document.createElement("div");
  item.className = "learning-item";
  item.append(detail("Коли", kyivDateTime.format(new Date(lesson.scheduled_at))),
    detail("Учень", student.name), detail("Тривалість", `${lesson.duration_minutes} хв`),
    detail("Статус", lessonStatuses[lesson.status] || lesson.status), lessonPlace(lesson));
  if (lesson.outcome_reason) item.append(detail("Причина", outcomeReasons[lesson.outcome_reason] || "Інше"));
  if (lesson.outcome_note) item.append(detail("Внутрішній коментар", lesson.outcome_note));
  if (lesson.status === "in_progress") item.append(detail("Почато", lesson.started_at
    ? kyivTime.format(new Date(lesson.started_at)) : "час не вказано"));
  if (lesson.status === "cancelled") item.append(detail("Списано з пакета",
    lesson.consumes_lesson && lesson.resolved_at ? "Так" : "Ні"));
  if (lesson.status === "scheduled") {
    const actions = document.createElement("div");
    actions.className = "learning-actions";
    actions.append(
      action("Почати урок", (button) => startTeacherLesson(lesson, button), "button"),
      action("Перенести", (button) => openTeacherSchedule(student, lesson, button)),
      action("Скасувати урок", (button) => openTeacherOutcome(lesson, button)));
    item.append(actions);
  } else if (lesson.status === "in_progress") {
    const actions = document.createElement("div");
    actions.className = "learning-actions";
    actions.append(
      action("Завершити урок", (button) => completeTeacherLesson(lesson, button), "button"),
      action("Не проведено", (button) => openTeacherOutcome(lesson, button)));
    item.append(actions);
  }
  return item;
}

async function loadTeacher() {
  refresh.disabled = true;
  reportStatus("Завантажуємо дані…");
  for (const target of [todayTarget, studentsTarget, upcomingTarget]) target.textContent = "Завантажуємо…";
  try {
    const assignments = requireData(await supabase.from("teacher_students")
      .select("student_id").eq("teacher_id", teacherId).eq("active", true));
    const ids = assignments.map((item) => item.student_id);
    const now = new Date();
    const today = kyivDay(now);
    const [dayResult, overdueResult, futureResult, activeResult] = await Promise.all([
      supabase.from("lessons").select(lessonColumns).eq("teacher_id", teacherId)
        .gte("scheduled_at", new Date(now.getTime() - 36 * 3600000).toISOString())
        .lt("scheduled_at", new Date(now.getTime() + 60 * 3600000).toISOString())
        .order("scheduled_at").limit(200),
      supabase.from("lessons").select(lessonColumns).eq("teacher_id", teacherId)
        .eq("status", "scheduled").lt("scheduled_at", now.toISOString())
        .order("scheduled_at", { ascending: false }).limit(30),
      supabase.from("lessons").select(lessonColumns).eq("teacher_id", teacherId)
        .eq("status", "scheduled").gte("scheduled_at", now.toISOString())
        .order("scheduled_at").limit(100),
      supabase.from("lessons").select(lessonColumns).eq("teacher_id", teacherId)
        .eq("status", "in_progress").order("started_at", { ascending: false }).limit(100),
    ]);
    const dayLessons = requireData(dayResult).filter((lesson) => kyivDay(new Date(lesson.scheduled_at)) === today);
    const past = requireData(overdueResult).filter((lesson) => kyivDay(new Date(lesson.scheduled_at)) !== today);
    const future = requireData(futureResult);
    const active = requireData(activeResult);
    const otherLessons = [...active.filter((lesson) => kyivDay(new Date(lesson.scheduled_at)) !== today),
      ...past.reverse(), ...future.filter((lesson) => kyivDay(new Date(lesson.scheduled_at)) !== today)];
    const students = new Map();
    if (ids.length) {
      const profiles = requireData(await supabase.from("profiles")
        .select("id,full_name,status").in("id", ids));
      for (const profile of profiles) students.set(profile.id, {
        id: profile.id, name: profile.full_name || "Учень НОНА", active: profile.status === "active",
      });
    }
    const studentFor = (id) => students.get(id) || { id, name: "Учень НОНА", active: false };
    for (const [lessons, target, message] of [
      [dayLessons, todayTarget, "На сьогодні уроків немає"],
      [otherLessons, upcomingTarget, "Інших запланованих уроків немає"],
    ]) {
      if (!lessons.length) { target.replaceChildren(empty(message)); continue; }
      const list = document.createElement("div");
      list.className = "learning-list";
      for (const lesson of lessons) list.append(lessonCard(lesson, studentFor(lesson.student_id)));
      target.replaceChildren(list);
    }
    if (ids.length) {
      const balances = requireData(await supabase.from("package_balances")
        .select("student_id,lessons_remaining,status,valid_from,valid_until").in("student_id", ids));
      const list = document.createElement("div");
      list.className = "learning-list";
      for (const id of ids) {
        const student = studentFor(id);
        const item = document.createElement("div");
        item.className = "learning-item";
        const heading = document.createElement("h4");
        heading.textContent = student.name;
        item.append(heading);
        const next = active.find((lesson) => lesson.student_id === id)
          || future.find((lesson) => lesson.student_id === id);
        item.append(detail("Наступний урок", next
          ? next.status === "in_progress" ? "урок триває" : kyivDateTime.format(new Date(next.scheduled_at))
          : "не заплановано"));
        const activePackages = balances.filter((balance) => balance.student_id === id && balance.status === "active"
          && (!balance.valid_from || balance.valid_from <= today)
          && (!balance.valid_until || balance.valid_until >= today));
        item.append(detail("Залишок занять", activePackages.length
          ? activePackages.reduce((sum, balance) => sum + Number(balance.lessons_remaining), 0)
          : "активного пакета немає"));
        const button = action("Запланувати урок", (element) => openTeacherSchedule(student, null, element), "button");
        button.disabled = !student.active;
        if (!student.active) button.title = "Акаунт учня неактивний";
        item.append(button);
        list.append(item);
      }
      studentsTarget.replaceChildren(list);
    } else studentsTarget.replaceChildren(empty("Учнів ще не призначено"));
    reportStatus("");
  } catch {
    todayTarget.replaceChildren(empty("Не вдалося завантажити розклад."));
    studentsTarget.replaceChildren(empty("Не вдалося завантажити учнів."));
    upcomingTarget.replaceChildren(empty("Не вдалося завантажити уроки."));
    reportStatus("Перевірте з’єднання та натисніть «Оновити дані».", true);
  } finally {
    refresh.disabled = false;
  }
}

export function initTeacher(id) {
  teacherId = id;
  if (teacherInitialized) {
    loadTeacher();
    initChat("teacher", id);
    return;
  }
  teacherInitialized = true;
  initTeacherActions(loadTeacher, reportStatus);
  refresh.addEventListener("click", loadTeacher);
  initChat("teacher", id);
  loadTeacher();
}
