import { supabase } from "./supabase-client.js";
import { kyivDay, requireData, safeLessonUrl } from "./learning-ui.js?v=3";

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
let scheduleOpenToken = 0;
let packagesReady = false;
let packageBalances = [];
let onChanged;
let setStatus;

const kyivClock = new Intl.DateTimeFormat("en-GB", {
  timeZone: "Europe/Kyiv", year: "numeric", month: "2-digit", day: "2-digit",
  hour: "2-digit", minute: "2-digit", hourCycle: "h23",
});

function clockParts(instant) {
  return Object.fromEntries(kyivClock.formatToParts(instant).map(({ type, value }) => [type, value]));
}

function kyivInputTime(instant) {
  const { hour, minute } = clockParts(instant);
  return `${hour}:${minute}`;
}

// Resolve a Kyiv wall-clock input without assuming a fixed UTC offset. A DST gap
// has no valid instant; an ambiguous autumn minute follows Postgres's later one.
function kyivInputInstant(day, time) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(day) || !/^\d{2}:\d{2}$/.test(time)) return null;
  const [year, month, date] = day.split("-").map(Number);
  const [hour, minute] = time.split(":").map(Number);
  const wall = Date.UTC(year, month - 1, date, hour, minute);
  const parsed = new Date(wall);
  if (parsed.getUTCFullYear() !== year || parsed.getUTCMonth() + 1 !== month
    || parsed.getUTCDate() !== date || parsed.getUTCHours() !== hour || parsed.getUTCMinutes() !== minute) return null;
  const offsets = new Set([-36, 0, 36].map((hours) => {
    const sample = new Date(wall + hours * 3600000);
    const parts = clockParts(sample);
    return Date.UTC(Number(parts.year), Number(parts.month) - 1, Number(parts.day),
      Number(parts.hour), Number(parts.minute)) - sample.getTime();
  }));
  const matches = [...offsets].map((offset) => new Date(wall - offset)).filter((instant) => {
    const parts = clockParts(instant);
    return `${parts.year}-${parts.month}-${parts.day}` === day && `${parts.hour}:${parts.minute}` === time;
  });
  return matches.sort((a, b) => b - a)[0] || null;
}

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

async function loadPackages(studentId) {
  return requireData(await supabase.from("package_balances")
    .select("package_id,student_id,lessons_purchased,lessons_remaining,status,valid_from,valid_until")
    .eq("student_id", studentId));
}

function populatePackages(balances, lesson) {
  const select = field("teacher-lesson-package");
  select.replaceChildren();
  const blank = document.createElement("option");
  blank.value = "";
  blank.textContent = "Без пакета";
  select.append(blank);
  for (const balance of balances.filter((item) => item.status === "active" || item.package_id === lesson?.package_id)) {
    const option = document.createElement("option");
    option.value = balance.package_id;
    option.textContent = `${balance.lessons_remaining} з ${balance.lessons_purchased} залишилось${balance.valid_until ? ` · до ${balance.valid_until}` : ""}${balance.status !== "active" ? " · неактивний" : ""}`;
    select.append(option);
  }
  if (lesson?.package_id && !balances.some((item) => item.package_id === lesson.package_id)) {
    select.add(new Option("Пакет початкового уроку · недоступний", lesson.package_id));
  }
  if (lesson) select.value = lesson.package_id || "";
  else if (select.options.length === 2) select.selectedIndex = 1;
  field("teacher-lesson-consumes").checked = lesson ? !!lesson.consumes_lesson : !!select.value;
  select.disabled = false;
  showPackageWarning();
}

function packageWarning() {
  const packageId = field("teacher-lesson-package").value;
  if (!packageId) return "";
  const balance = packageBalances.find((item) => item.package_id === packageId);
  if (!balance) return "Пакет початкового уроку більше недоступний. Оберіть інший пакет або свідомо змініть вибір на «Без пакета».";
  if (balance.status !== "active") return "Цей пакет більше не активний. Оберіть інший пакет.";
  const day = field("teacher-lesson-date").value;
  if (day && balance.valid_from && day < balance.valid_from) return `Цей пакет діє лише з ${balance.valid_from}. Оберіть іншу дату або пакет.`;
  if (day && balance.valid_until && day > balance.valid_until) return `Термін цього пакета закінчився ${balance.valid_until}. Оберіть іншу дату або пакет.`;
  if (field("teacher-lesson-consumes").checked && Number(balance.lessons_remaining) <= 0)
    return "У пакеті немає доступних занять. Оберіть інший пакет.";
  return "";
}

function showPackageWarning() {
  const warning = field("teacher-package-warning");
  warning.textContent = packageWarning();
  warning.hidden = !warning.textContent;
}

function scheduleErrorMessage(error) {
  if (error?.code === "42501") return "Немає доступу до цього учня або уроку.";
  const message = error?.message || "";
  if (/valid future Kyiv time|Date and time required/i.test(message)) return "Оберіть майбутній час.";
  if (/already has a lesson at this time/i.test(message)) return "У цей час у викладача або учня вже є інший урок.";
  if (/active student package valid on lesson day/i.test(message)) return "Цей пакет недоступний для вибраної дати.";
  if (/Package has no unreserved lessons/i.test(message)) return "У пакеті немає доступних занять.";
  if (/online lesson needs an HTTPS link|Invalid Google Meet URL/i.test(message)) return "Вкажіть коректне HTTPS-посилання.";
  if (/offline lesson needs a location/i.test(message)) return "Вкажіть місце заняття.";
  if (/consuming lesson requires a package/i.test(message)) return "Оберіть пакет або зніміть позначку списання.";
  if (/Invalid duration/i.test(message)) return "Оберіть тривалість від 15 до 180 хвилин.";
  return "Не вдалося зберегти урок. Перевірте дані й спробуйте ще раз.";
}

export async function openTeacherSchedule(student, lesson, opener) {
  if (scheduleDialog.open) return;
  const token = ++scheduleOpenToken;
  selectedStudent = student;
  selectedLesson = lesson || null;
  scheduleOpener = opener;
  packagesReady = false;
  packageBalances = [];
  scheduleForm.reset();
  showError(scheduleError, "");
  field("teacher-package-warning").hidden = true;
  field("teacher-schedule-title").textContent = lesson ? "Перенести урок" : "Запланувати урок";
  field("teacher-schedule-save").textContent = lesson ? "Перенести урок" : "Запланувати урок";
  field("teacher-schedule-save").disabled = true;
  field("teacher-lesson-package").replaceChildren(new Option("Завантажуємо пакети…", ""));
  field("teacher-lesson-package").disabled = true;
  field("teacher-schedule-student").textContent = student.name;
  field("teacher-lesson-date").value = lesson ? kyivDay(new Date(lesson.scheduled_at)) : nextKyivDay();
  field("teacher-lesson-date").min = kyivDay();
  field("teacher-lesson-time").value = lesson ? kyivInputTime(new Date(lesson.scheduled_at)) : "16:00";
  field("teacher-lesson-duration").value = lesson?.duration_minutes || 60;
  field("teacher-lesson-format").value = lesson?.lesson_format ||
    (lesson?.lesson_url || lesson?.meet_url ? "online" : lesson?.location_text ? "offline" : "online");
  field("teacher-lesson-url").value = lesson?.lesson_url || lesson?.meet_url || "";
  field("teacher-lesson-location").value = lesson?.location_text || "";
  field("teacher-lesson-consumes").checked = lesson ? !!lesson.consumes_lesson : false;
  updateFormat();
  scheduleDialog.showModal();
  document.body.classList.add("admin-dialog-open");
  try {
    const balances = await loadPackages(student.id);
    if (token !== scheduleOpenToken || !scheduleDialog.open) return;
    packageBalances = balances;
    populatePackages(balances, lesson);
    packagesReady = true;
    field("teacher-schedule-save").disabled = false;
  } catch {
    if (token !== scheduleOpenToken || !scheduleDialog.open) return;
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
  field("teacher-lesson-date").addEventListener("change", showPackageWarning);
  field("teacher-lesson-package").addEventListener("change", () => {
    field("teacher-lesson-consumes").checked = !!field("teacher-lesson-package").value;
    showPackageWarning();
  });
  field("teacher-lesson-consumes").addEventListener("change", showPackageWarning);
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
        ++scheduleOpenToken;
        packagesReady = false;
        packageBalances = [];
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
    if (scheduleBusy || !selectedStudent || !packagesReady || !scheduleForm.reportValidity()) return;
    const url = field("teacher-lesson-url").value.trim();
    const location = field("teacher-lesson-location").value.trim();
    const online = field("teacher-lesson-format").value === "online";
    const packageId = field("teacher-lesson-package").value || null;
    const consumes = field("teacher-lesson-consumes").checked;
    const selectedInstant = kyivInputInstant(field("teacher-lesson-date").value, field("teacher-lesson-time").value);
    if (!selectedInstant) {
      showError(scheduleError, "Оберіть коректний час за Києвом.");
      return;
    }
    if (selectedInstant <= new Date()) {
      showError(scheduleError, "Оберіть час пізніше поточного.");
      return;
    }
    if (online && !safeLessonUrl(url)) {
      showError(scheduleError, "Вкажіть коректне HTTPS-посилання.");
      return;
    }
    const warning = packageWarning();
    if (warning) {
      showError(scheduleError, warning);
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
      showError(scheduleError, scheduleErrorMessage(error));
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
