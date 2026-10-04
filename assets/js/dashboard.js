import { attachLogout, getAccess, roleUrl, siteUrl, userDisplayName } from "./auth.js";

const expectedRole = document.documentElement.dataset.requiredRole;
const loading = document.getElementById("cabinet-loading");
const problem = document.getElementById("cabinet-problem");
const content = document.getElementById("private-content");

async function enterCabinet() {
  loading.hidden = false;
  problem.hidden = true;
  content.hidden = true;

  const access = await getAccess();
  if (access.status === "signed_out") {
    window.location.replace(siteUrl("login/"));
    return;
  }
  if (access.status === "unassigned" || access.status === "suspended") {
    window.location.replace(siteUrl("auth/callback/"));
    return;
  }
  if (access.status === "authorized" && access.role !== expectedRole) {
    window.location.replace(roleUrl(access.role));
    return;
  }
  if (access.status !== "authorized") {
    loading.hidden = true;
    problem.hidden = false;
    return;
  }

  const name = userDisplayName(access.user);
  for (const element of document.querySelectorAll("[data-user-name]")) element.textContent = name;
  for (const element of document.querySelectorAll("[data-user-initial]")) element.textContent = Array.from(name)[0]?.toLocaleUpperCase("uk") || "Н";
  loading.hidden = true;
  content.hidden = false;
  try {
    if (expectedRole === "admin") {
      const { initAdmin } = await import("./admin.js?v=8");
      initAdmin(access.user.id);
    } else if (expectedRole === "student") {
      const { initStudent } = await import("./student.js?v=6");
      initStudent(access.user.id);
    } else if (expectedRole === "teacher") {
      const { initTeacher } = await import("./teacher.js?v=8");
      initTeacher(access.user.id);
    }
  } catch {
    content.hidden = true;
    problem.querySelector("h1").textContent = "Не вдалося завантажити кабінет";
    problem.hidden = false;
  }
}

document.getElementById("cabinet-retry").addEventListener("click", enterCabinet);
attachLogout(document.getElementById("sign-out"), document.getElementById("cabinet-status"));
enterCabinet();
