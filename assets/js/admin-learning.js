import { supabase } from "./supabase-client.js";
import { detail, empty, kyivDateTime, lessonStatuses, outcomeReasons, requireData, safeMeetUrl } from "./learning-ui.js?v=3";

const dialog = document.getElementById("admin-learning-dialog");
const overview = document.getElementById("learning-overview");
const errorBox = document.getElementById("learning-error");
const feedback = document.getElementById("learning-feedback");
const assignForm = document.getElementById("assign-teacher-form");
const packageForm = document.getElementById("create-package-form");
const scheduleForm = document.getElementById("schedule-lesson-form");
const teacherSelect = document.getElementById("learning-teacher");
const scheduleTeacher = document.getElementById("schedule-teacher");
const packageSelect = document.getElementById("schedule-package");
let student;
let opener;
let busy = false;

function options(select, entries, placeholder) {
  select.replaceChildren();
  const first = document.createElement("option");
  first.value = "";
  first.textContent = placeholder;
  select.append(first);
  for (const [value, label] of entries) {
    const option = document.createElement("option");
    option.value = value;
    option.textContent = label;
    select.append(option);
  }
}

function setFeedback(message, isError = false) {
  feedback.textContent = message;
  feedback.classList.toggle("is-error", isError);
}

async function loadOverview() {
  if (!student) return;
  errorBox.hidden = true;
  overview.textContent = "Завантажуємо дані…";
  try {
    const [assignmentsResult, balancesResult, nextResult, activeResult, teachersResult, historyResult] = await Promise.all([
      supabase.from("teacher_students").select("teacher_id,active")
        .eq("student_id", student.id).eq("active", true),
      supabase.from("package_balances")
        .select("package_id,lessons_purchased,lessons_used,lessons_remaining,status,valid_from,valid_until")
        .eq("student_id", student.id),
      supabase.from("lessons").select("scheduled_at,duration_minutes,teacher_id,status")
        .eq("student_id", student.id).eq("status", "scheduled")
        .gte("scheduled_at", new Date().toISOString()).order("scheduled_at").limit(1),
      supabase.from("lessons").select("scheduled_at,duration_minutes,teacher_id,status")
        .eq("student_id", student.id).eq("status", "in_progress").limit(1),
      supabase.from("profiles").select("id,full_name").eq("role", "teacher").eq("status", "active"),
      supabase.from("lessons").select("scheduled_at,started_at,completed_at,completion_source,status,outcome_reason,outcome_note,consumes_lesson,resolved_at")
        .eq("student_id", student.id).in("status", ["completed", "cancelled", "rescheduled", "no_show"])
        .order("scheduled_at", { ascending: false }).limit(10),
    ]);
    const assignments = requireData(assignmentsResult);
    const balances = requireData(balancesResult);
    const next = requireData(activeResult)[0] || requireData(nextResult)[0];
    const teachers = requireData(teachersResult);
    const history = requireData(historyResult);
    const names = new Map(teachers.map((teacher) => [teacher.id, teacher.full_name || "Викладач НОНА"]));
    const active = balances.filter((balance) => balance.status === "active");
    const box = document.createElement("div");
    box.className = "learning-overview-list";
    box.append(detail("Призначений викладач", assignments.length
      ? assignments.map((item) => names.get(item.teacher_id) || "Викладач НОНА").join(", ")
      : "ще не призначено"));
    if (active.length) {
      for (const item of active) {
        const label = active.length > 1 ? `Пакет від ${item.valid_from || "без дати"}` : "Активний пакет";
        box.append(detail(label, `${item.lessons_purchased} придбано · ${item.lessons_used} списано · ${item.lessons_remaining} залишилось`));
      }
    } else box.append(empty("Активного пакета поки немає"));
    box.append(detail("Наступний урок", next
      ? `${next.status === "in_progress" ? "Триває · " : ""}${kyivDateTime.format(new Date(next.scheduled_at))} · ${names.get(next.teacher_id) || "Викладач НОНА"} · ${next.duration_minutes} хв`
      : "ще не заплановано"));
    const historyHeading = document.createElement("h3");
    historyHeading.textContent = "Результати уроків";
    box.append(historyHeading);
    if (history.length) {
      for (const lesson of history) {
        const item = document.createElement("div");
        item.className = "learning-item";
        item.append(detail("Заплановано", kyivDateTime.format(new Date(lesson.scheduled_at))),
          detail("Результат", lessonStatuses[lesson.status] || lesson.status));
        if (lesson.started_at) item.append(detail("Почато", kyivDateTime.format(new Date(lesson.started_at))));
        if (lesson.completed_at) item.append(detail("Завершено", kyivDateTime.format(new Date(lesson.completed_at))));
        if (lesson.status === "completed") item.append(detail("Спосіб завершення",
          lesson.completion_source === "automatic" ? "Проведено автоматично"
            : lesson.completion_source === "teacher" ? "Завершив викладач" : "Невідомо"));
        if (lesson.outcome_reason) item.append(detail("Причина", outcomeReasons[lesson.outcome_reason] || "Інше"));
        if (lesson.outcome_note) item.append(detail("Внутрішній коментар", lesson.outcome_note));
        const charged = lesson.consumes_lesson &&
          (lesson.status === "completed" || (lesson.status === "cancelled" && lesson.resolved_at));
        item.append(detail("Списано з пакета", charged ? "Так" : "Ні"));
        box.append(item);
      }
    } else box.append(empty("Результатів уроків ще немає"));
    overview.replaceChildren(box);

    options(teacherSelect, teachers.map((item) => [item.id, names.get(item.id)]), "Оберіть викладача");
    options(scheduleTeacher, assignments.map((item) => [item.teacher_id, names.get(item.teacher_id) || "Викладач НОНА"]),
      "Спочатку призначте викладача");
    options(packageSelect, active.map((item) => [item.package_id,
      `${item.lessons_remaining} з ${item.lessons_purchased} залишилось${item.valid_until ? ` · до ${item.valid_until}` : ""}`]), "Без пакета");
    if (assignments.length === 1) scheduleTeacher.value = assignments[0].teacher_id;
    if (active.length === 1) packageSelect.value = active[0].package_id;
  } catch {
    overview.replaceChildren();
    errorBox.hidden = false;
  }
}

async function runAction(form, action, success) {
  if (!student || busy || !form.reportValidity()) return;
  busy = true;
  const button = form.querySelector('[type="submit"]');
  const original = button.textContent;
  button.disabled = true;
  button.textContent = "Зберігаємо…";
  setFeedback("");
  try {
    requireData(await action());
    setFeedback(success);
    form.reset();
    await loadOverview();
  } catch (error) {
    setFeedback(error?.code === "42501"
      ? "Немає прав для цієї дії. Оновіть сторінку й перевірте доступ."
      : error?.message?.includes("Resolve future lessons with the previous teacher")
        ? "Перед зміною викладача потрібно узгодити вже заплановані уроки з попереднім викладачем."
      : error?.code === "22023" || error?.code === "23514"
        ? "Перевірте викладача, пакет, дату та доступний залишок занять."
        : "Не вдалося зберегти. Спробуйте ще раз.", true);
  } finally {
    busy = false;
    button.disabled = false;
    button.textContent = original;
  }
}

export function openAdminLearning(user, button) {
  student = user;
  opener = button;
  document.getElementById("learning-student-name").textContent = user.full_name || "Учень НОНА";
  setFeedback("");
  dialog.showModal();
  document.body.classList.add("admin-dialog-open");
  loadOverview();
}

export function initAdminLearning() {
  document.getElementById("learning-close").addEventListener("click", () => dialog.close());
  document.getElementById("learning-retry").addEventListener("click", loadOverview);
  dialog.addEventListener("cancel", (event) => { if (busy) event.preventDefault(); });
  dialog.addEventListener("close", () => {
    document.body.classList.remove("admin-dialog-open");
    student = null;
    if (opener?.isConnected) opener.focus();
    opener = null;
  });
  assignForm.addEventListener("submit", (event) => {
    event.preventDefault();
    runAction(assignForm, () => supabase.rpc("admin_assign_teacher", {
      target_student_id: student.id, target_teacher_id: teacherSelect.value,
    }), "Викладача призначено.");
  });
  packageForm.addEventListener("submit", (event) => {
    event.preventDefault();
    runAction(packageForm, () => supabase.rpc("admin_create_lesson_package", {
      target_student_id: student.id,
      lessons_count: Number(document.getElementById("learning-count").value),
      starts_on: document.getElementById("learning-start").value || null,
      ends_on: document.getElementById("learning-end").value || null,
    }), "Пакет додано.");
  });
  scheduleForm.addEventListener("submit", (event) => {
    event.preventDefault();
    const packageId = packageSelect.value || null;
    const consumes = document.getElementById("schedule-consumes").checked;
    const meeting = document.getElementById("schedule-meet").value.trim();
    if (consumes && !packageId) {
      setFeedback("Оберіть пакет або зніміть позначку списання заняття.", true);
      return;
    }
    if (meeting && !safeMeetUrl(meeting)) {
      setFeedback("Вкажіть коректне HTTPS-посилання Google Meet.", true);
      return;
    }
    runAction(scheduleForm, () => supabase.rpc("admin_schedule_lesson", {
      target_student_id: student.id,
      target_teacher_id: scheduleTeacher.value,
      lesson_date: document.getElementById("schedule-date").value,
      lesson_time: document.getElementById("schedule-time").value,
      lesson_duration: Number(document.getElementById("schedule-duration").value),
      target_package_id: packageId,
      meeting_url: meeting || null,
      takes_package_lesson: consumes,
    }), "Урок заплановано.");
  });
}
