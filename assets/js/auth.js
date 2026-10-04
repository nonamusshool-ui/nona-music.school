import { supabase } from "./supabase-client.js";

const siteRoot = new URL("../../", import.meta.url);
const rolePaths = Object.freeze({ student: "cabinet/", teacher: "teacher/", admin: "admin/" });
const missingProfileTableCodes = new Set(["42P01", "PGRST205"]);

export function siteUrl(path) {
  return new URL(path.replace(/^\/+/, ""), siteRoot).href;
}

export function roleUrl(role) {
  return Object.prototype.hasOwnProperty.call(rolePaths, role) ? siteUrl(rolePaths[role]) : null;
}

export function landingUrl(access) {
  if (access.role === "admin" && access.canTeach) {
    try { if (sessionStorage.getItem("nona:last-workspace") === "teacher") return siteUrl("teacher/"); } catch { /* Storage is optional. */ }
  }
  return roleUrl(access.role);
}

export async function getAccess() {
  try {
    // A stored session only indicates that sign-in may have happened. getUser verifies it.
    const { data: sessionData, error: sessionError } = await supabase.auth.getSession();
    if (sessionError) return { status: "error" };
    if (!sessionData.session) return { status: "signed_out" };

    const { data: userData, error: userError } = await supabase.auth.getUser();
    if (userError || !userData.user) return { status: "error" };
    const user = userData.user;

    // Only a database profile can grant a cabinet role. Never infer it from metadata or URL.
    const { data: profile, error: profileError } = await supabase
      .from("profiles")
      .select("role, status, can_teach, admin_level")
      .eq("id", user.id)
      .maybeSingle();

    if (profileError) {
      return { status: missingProfileTableCodes.has(profileError.code) ? "unassigned" : "error" };
    }
    if (!profile) return { status: "unassigned" };
    if (profile.status === "suspended") return { status: "suspended" };
    if (profile.status !== "active" || !roleUrl(profile.role)) return { status: "unassigned" };
    return { status: "authorized", user, role: profile.role,
      canTeach: profile.role === "teacher" || (profile.role === "admin" && profile.can_teach === true),
      adminLevel: profile.role === "admin" ? profile.admin_level : null };
  } catch {
    return { status: "error" };
  }
}

export function userDisplayName(user) {
  const metadata = user.user_metadata || {};
  const name = metadata.full_name || metadata.name || metadata.given_name;
  return typeof name === "string" && name.trim() ? name.trim() : "друже";
}

export function attachLogout(button, statusElement) {
  button.addEventListener("click", async () => {
    button.disabled = true;
    if (statusElement) statusElement.textContent = "Виходимо з кабінету…";
    try {
      const { error } = await supabase.auth.signOut();
      if (error) throw error;
      window.location.replace(siteUrl("login/"));
    } catch {
      button.disabled = false;
      if (statusElement) statusElement.textContent = "Не вдалося вийти. Спробуйте ще раз.";
    }
  });
}
