export const kyivDate = new Intl.DateTimeFormat("uk-UA", {
  dateStyle: "medium", timeZone: "Europe/Kyiv",
});
export const kyivDateTime = new Intl.DateTimeFormat("uk-UA", {
  dateStyle: "medium", timeStyle: "short", timeZone: "Europe/Kyiv",
});
export const kyivTime = new Intl.DateTimeFormat("uk-UA", {
  hour: "2-digit", minute: "2-digit", timeZone: "Europe/Kyiv",
});

export function kyivDay(instant = new Date()) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "Europe/Kyiv", year: "numeric", month: "2-digit", day: "2-digit",
  }).formatToParts(instant);
  const value = Object.fromEntries(parts.map(({ type, value }) => [type, value]));
  return `${value.year}-${value.month}-${value.day}`;
}

export function safeMeetUrl(value) {
  try {
    const url = new URL(value);
    return url.protocol === "https:" && url.hostname === "meet.google.com" ? url.href : null;
  } catch {
    return null;
  }
}

export function meetLink(value) {
  const href = safeMeetUrl(value);
  if (!href) return null;
  const link = document.createElement("a");
  link.className = "button button-light";
  link.href = href;
  link.target = "_blank";
  link.rel = "noopener noreferrer";
  link.textContent = "Приєднатися до Google Meet";
  return link;
}

export function empty(message) {
  const box = document.createElement("div");
  box.className = "empty-state";
  const text = document.createElement("strong");
  text.textContent = message;
  box.append(text);
  return box;
}

export function detail(label, value) {
  const item = document.createElement("p");
  const strong = document.createElement("strong");
  strong.textContent = `${label}: `;
  item.append(strong, value == null || value === "" ? "—" : String(value));
  return item;
}

export function requireData(result) {
  if (result.error) throw result.error;
  return result.data;
}
