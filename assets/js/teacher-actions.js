import { supabase } from "./supabase-client.js";
import { kyivDay, kyivTime, requireData, safeLessonUrl } from "./learning-ui.js?v=3";

const scheduleDialog = document.getElementById("teacher-schedule-dialog");
const scheduleForm = document.getElementById("teacher-schedule-form");
const scheduleError = document.getElementById("teacher-schedule-error");
const outcomeDialog = document.getElementById("teacher-outcome-dialog");
const outcomeForm = document.getElementById("teacher-outcome-form");
const outcomeError = document.getElementById("teacher-outcome-error");
const field = (id) => document.getElementById(id);
let selectedStudent;
let selectedLesson;
let outcomeLesson;
let scheduleOpener;
let outcomeOpener;
let scheduleBusy = false;
let outcomeBusy = false;
let onChanged;
let setStatus;

function showError(target, message) {
  target.textContent = message;
  target.hidden = !message;
}

function nextKyivDay() {
  const date = new Date(`${kyivDay()}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + 1);
  return date.toISOString().slice(0, 10);
}

function updateFormat() {
  const online = field("teacher-lesson-format").value === "online";
  field("teacher-url-field").hidden = !online;
  field("teacher-location-field").hidden = online;
  field("teacher-lesson-url").required = online;
  field("teacher-lesson-location").required = !online;
}

function updateReason() {
  const reason = field("teacher-outcome-reason").value;
  field("teacher-outcome-charge").checked = reason === "student_no_show" && !!outcomeLesson?.package_id;
  field("teacher-outcome-note").required = reason === "other";
  field("teacher-note-optional").textContent = reason === "other" ? "(обов’язково)" : "(необов’язково)";
}

async function loadPackages(studentId, preferredId) {
  const select = field("teacher-lesson-package");
  select.replaceChildren();
  const blank = document.createElement("option");
  blank.value = "";
  blank.textContent = "Без пакета";
  select.append(blank);
  const balances = requireData(await supabase.from("package_balances")
    .select("package_id,student_id,lessons_purchased,lessons_remaining,status,valid_from,valid_until")
    .eq("student_id", studentId));
  for (const balance of balances.filter((item) => item.status === "active")) {
    const option = document.createElement("option");
    option.value = balance.package_id;
    option.textContent = `${balance.lessons_remaining} з ${balance.lessons_purchased} залишилось${balance.valid_until ? ` · до ${balance.valid_until}` : ""}`;
    select.append(option);
  }
  if (preferredId && [...select.options].some((option) => option.value === preferredId)) select.value = preferredId;
  else if (select.options.length === 2) select.selectedIndex = 1;
  field("teacher-lesson-consumes").checked = !!select.value;
}

export async function openTeacherSchedule(student, lesson, opener) {
  if (scheduleDialog.open) return;
  selectedStudent = student;
  selectedLesson = lesson || null;
  scheduleOpener = opener;
  scheduleForm.reset();
  showError(scheduleError, "");
  field("teacher-schedule-title").textContent = lesson ? "Перенести урок" : "Запланувати урок";
  field("teacher-schedule-save").textContent = lesson ? "Перенести урок" : "Запланувати урок";
  field("teacher-schedule-student").textContent = student.name;
  field("teacher-lesson-date").value = nextKyivDay();
  field("teacher-lesson-date").min = kyivDay();
  field("teacher-lesson-time").value = lesson ? kyivTime.format(new Date(lesson.scheduled_at)) : "16:00";
  field("teacher-lesson-duration").value = lesson?.duration_minutes || 60;
  field("teacher-lesson-format").value = lesson?.lesson_format ||
    (lesson?.lesson_url || lesson?.meet_url ? "online" : lesson?.location_text ? "offline" : "online");
  field("teacher-lesson-url").value = lesson?.lesson_url || lesson?.meet_url || "";
  field("teacher-lesson-location").value = lesson?.location_text || "";
  updateFormat();
  scheduleDialog.showModal();
  document.body.classList.add("admin-dialog-open");
  try {
    await loadPackages(student.id, lesson?.package_id);
  } catch {
    showError(scheduleError, "Не вдалося завантажити пакети. Закрийте вікно й спробуйте ще раз.");
  }
}

export function openTeacherOutcome(lesson, opener) {
  if (outcomeDialog.open) return;
  outcomeLesson = lesson;
  outcomeOpener = opener;
  outcomeForm.reset();
  showError(outcomeError, "");
  field("teacher-outcome-title").textContent = lesson.status === "in_progress" ? "Не проведено" : "Скасувати урок";
  field("teacher-outcome-charge").disabled = !lesson.package_id;
  updateReason();
  outcomeDialog.showModal();
  document.body.classList.add("admin-dialog-open");
}

export async function completeTeacherLesson(lesson, button) {
  button.disabled = true;
  button.textContent = "Зберігаємо…";
  try {
    requireData(await supabase.rpc("teacher_resolve_lesson", {
      target_lesson_id: lesson.id, outcome: "completed",
    }));
    await onChanged();
    setStatus("Урок завершено.");
  } catch {
    setStatus("Не вдалося зберегти результат. Оновіть дані й спробуйте ще раз.", true);
    button.disabled = false;
    button.textContent = "Завершити урок";
  }
}

export async function startTeacherLesson(lesson, button) {
  button.disabled = true;
  button.textContent = "Зберігаємо…";
  try {
    requireData(await supabase.rpc("teacher_start_lesson", { target_lesson_id: lesson.id }));
    await onChanged();
    setStatus("Урок розпочато.");
  } catch {
    setStatus("Не вдалося почати урок. Оновіть дані й спробуйте ще раз.", true);
    button.disabled = false;
    button.textContent = "Почати урок";
  }
}

export function initTeacherActions(changed, reportStatus) {
  onChanged = changed;
  setStatus = reportStatus;
  field("teacher-lesson-format").addEventListener("change", updateFormat);
  field("teacher-lesson-package").addEventListener("change", () => {
    field("teacher-lesson-consumes").checked = !!field("teacher-lesson-package").value;
  });
  field("teacher-outcome-reason").addEventListener("change", updateReason);
  for (const [dialog, closeId, cancelId, isBusy] of [
    [scheduleDialog, "teacher-schedule-close", "teacher-schedule-cancel", () => scheduleBusy],
    [outcomeDialog, "teacher-outcome-close", "teacher-outcome-cancel", () => outcomeBusy],
  ]) {
    field(closeId).addEventListener("click", () => { if (!isBusy()) dialog.close(); });
    field(cancelId).addEventListener("click", () => { if (!isBusy()) dialog.close(); });
    dialog.addEventListener("cancel", (event) => { if (isBusy()) event.preventDefault(); });
    dialog.addEventListener("click", (event) => {
      if (event.target === dialog && !isBusy()) dialog.close();
    });
    dialog.addEventListener("close", () => {
      document.body.classList.remove("admin-dialog-open");
      if (dialog === scheduleDialog) {
        selectedStudent = null;
        selectedLesson = null;
        if (scheduleOpener?.isConnected) scheduleOpener.focus();
        scheduleOpener = null;
      } else {
        outcomeLesson = null;
        if (outcomeOpener?.isConnected) outcomeOpener.focus();
        outcomeOpener = null;
      }
    });
  }

  scheduleForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (scheduleBusy || !selectedStudent || !scheduleForm.reportValidity()) return;
    const url = field("teacher-lesson-url").value.trim();
    const location = field("teacher-lesson-location").value.trim();
    const online = field("teacher-lesson-format").value === "online";
    const packageId = field("teacher-lesson-package").value || null;
    const consumes = field("teacher-lesson-consumes").checked;
    if (online && !safeLessonUrl(url)) {
      showError(scheduleError, "Вкажіть коректне HTTPS-посилання на заняття.");
      return;
    }
    if (consumes && !packageId) {
      showError(scheduleError, "Оберіть пакет або зніміть позначку списання.");
      return;
    }
    scheduleBusy = true;
    const button = field("teacher-schedule-save");
    const label = button.textContent;
    button.disabled = true;
    button.textContent = "Зберігаємо…";
    showError(scheduleError, "");
    try {
      const params = {
        lesson_date: field("teacher-lesson-date").value,
        lesson_time: field("teacher-lesson-time").value,
        lesson_duration: Number(field("teacher-lesson-duration").value),
        selected_format: online ? "online" : "offline",
        selected_url: online ? url : null,
        selected_location: online ? null : location,
        target_package_id: packageId,
        takes_package_lesson: consumes,
      };
      const wasReschedule = !!selectedLesson;
      if (wasReschedule) params.target_lesson_id = selectedLesson.id;
      else params.target_student_id = selectedStudent.id;
      requireData(await supabase.rpc(wasReschedule ? "teacher_reschedule_lesson" : "teacher_schedule_lesson", params));
      scheduleDialog.close();
      await onChanged();
      setStatus(wasReschedule ? "Урок перенесено." : "Урок заплановано.");
    } catch (error) {
      showError(scheduleError, error?.code === "42501"
        ? "Немає доступу до цього учня або уроку."
        : error?.code === "22023" || error?.code === "23514"
          ? "Перевірте час, місце, пакет і доступний залишок занять."
          : "Не вдалося зберегти урок. Спробуйте ще раз.");
    } finally {
      scheduleBusy = false;
      button.disabled = false;
      button.textContent = label;
    }
  });

  outcomeForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (outcomeBusy || !outcomeLesson || !outcomeForm.reportValidity()) return;
    outcomeBusy = true;
    const button = field("teacher-outcome-save");
    button.disabled = true;
    button.textContent = "Зберігаємо…";
    showError(outcomeError, "");
    try {
      requireData(await supabase.rpc("teacher_resolve_lesson", {
        target_lesson_id: outcomeLesson.id,
        outcome: "cancelled",
        reason: field("teacher-outcome-reason").value,
        note: field("teacher-outcome-note").value.trim() || null,
        charge_package: field("teacher-outcome-charge").checked,
      }));
      outcomeDialog.close();
      await onChanged();
      setStatus("Результат уроку збережено.");
    } catch (error) {
      showError(outcomeError, error?.code === "42501"
        ? "Немає доступу до цього уроку."
        : error?.code === "22023" || error?.code === "23514"
          ? "Перевірте причину та рішення щодо списання з пакета."
          : "Не вдалося зберегти результат. Спробуйте ще раз.");
    } finally {
      outcomeBusy = false;
      button.disabled = false;
      button.textContent = "Підтвердити результат";
    }
  });
}
