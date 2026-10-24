// Render persisted billing truth; allocation and balances are database-owned.
export function lessonBillingLabel(lesson, packageName = "Пакет") {
  if (lesson.billing_status === "pending") return "Очікує оплати";
  if (lesson.billing_status === "free" || !lesson.package_id) return "Безкоштовне заняття";
  if (lesson.consumes_lesson && (lesson.status === "completed"
    || (lesson.status === "cancelled" && lesson.resolved_at))) return `${packageName} · списано 1 заняття`;
  if (lesson.consumes_lesson && ["scheduled", "in_progress"].includes(lesson.status)) {
    return `${packageName} · буде списано після проведення`;
  }
  return `${packageName} · не списано`;
}
