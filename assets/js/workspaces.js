const sections = {
  admin: ["overview", "users", "schedule", "chat", "journal"],
  teacher: ["today", "students", "upcoming", "schedule"],
};

export function setupWorkspace(role, access) {
  const switcher = document.querySelector("[data-workspace-switch]");
  if (switcher && access.role === "admin" && access.canTeach) switcher.hidden = false;
  try { sessionStorage.setItem("nona:last-workspace", role); } catch { /* Optional preference. */ }

  const stateKey = `nona:sections:${role}`;
  let saved = {};
  try { saved = JSON.parse(sessionStorage.getItem(stateKey) || "{}") || {}; } catch { saved = {}; }
  const toggles = new Map();
  for (const id of sections[role] || []) {
    const section = document.getElementById(id);
    if (!section) continue;
    if (document.getElementById(`${id}-content`)) continue;
    section.classList.add("workspace-collapsible");
    const header = section.querySelector(":scope > .section-heading, :scope > .card-title-row");
    if (!header) continue;
    const body = document.createElement("div");
    body.className = "workspace-section-body";
    body.id = `${id}-content`;
    while (header.nextSibling) body.append(header.nextSibling);
    section.append(body);
    const button = document.createElement("button");
    button.type = "button";
    button.className = "section-toggle";
    button.setAttribute("aria-controls", body.id);
    const isOpen = Object.hasOwn(saved, id) ? saved[id] : id === (role === "admin" ? "overview" : "today");
    const setOpen = (open) => {
      body.hidden = !open;
      button.setAttribute("aria-expanded", String(open));
      button.textContent = open ? "Згорнути" : "Розгорнути";
      saved[id] = open;
      try { sessionStorage.setItem(stateKey, JSON.stringify(saved)); } catch { /* Optional preference. */ }
      if (open) document.dispatchEvent(new CustomEvent("workspace:open", { detail: { role, id } }));
    };
    setOpen(isOpen);
    button.addEventListener("click", () => setOpen(body.hidden));
    header.append(button);
    toggles.set(id, { body, setOpen });
  }
  document.querySelectorAll(".admin-nav a[href^='#']").forEach((link) => {
    link.addEventListener("click", () => {
      const target = toggles.get(link.hash.slice(1));
      if (target?.body.hidden) target.setOpen(true);
    });
  });
  if (location.hash && toggles.get(location.hash.slice(1))?.body.hidden) {
    toggles.get(location.hash.slice(1)).setOpen(true);
  }
}
