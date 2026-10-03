import { supabase } from "./supabase-client.js";
import { attachLogout, getAccess, roleUrl, siteUrl } from "./auth.js";

const loading = document.getElementById("callback-loading");
const pending = document.getElementById("callback-pending");
const problem = document.getElementById("callback-problem");
const retryButton = document.getElementById("callback-retry");

const clearCredentialsFromUrl = () => {
  window.history.replaceState(null, "", window.location.pathname);
};

const showPanel = (panel) => {
  loading.hidden = true;
  pending.hidden = panel !== pending;
  problem.hidden = panel !== problem;
};

for (const button of document.querySelectorAll("[data-sign-out]")) {
  attachLogout(button, button.closest("section").querySelector("[data-logout-status]"));
}

async function finishSignIn() {
  loading.hidden = false;
  pending.hidden = true;
  problem.hidden = true;

  const params = new URLSearchParams(window.location.search);
  const fragment = new URLSearchParams(window.location.hash.slice(1));
  if (params.has("error") || fragment.has("error")) {
    clearCredentialsFromUrl();
    showPanel(problem);
    return;
  }

  const code = params.get("code");
  const tokenHash = params.get("token_hash");
  try {
    if (code) {
      const flowId = params.get("sb_flow_id");
      clearCredentialsFromUrl();
      const { error } = await supabase.auth.exchangeCodeForSession(code, flowId ? { flowId } : undefined);
      if (error) throw error;
    } else if (tokenHash && params.get("type") === "email") {
      clearCredentialsFromUrl();
      const { error } = await supabase.auth.verifyOtp({ token_hash: tokenHash, type: "email" });
      if (error) throw error;
    } else if (fragment.has("access_token") || fragment.has("refresh_token")) {
      // Supabase's default magic-link template may return an implicit URL fragment.
      const accessToken = fragment.get("access_token");
      const refreshToken = fragment.get("refresh_token");
      clearCredentialsFromUrl();
      if (!accessToken || !refreshToken) throw new Error("Incomplete sign-in response");
      const { error } = await supabase.auth.setSession({
        access_token: accessToken,
        refresh_token: refreshToken,
      });
      if (error) throw error;
    }

    const access = await getAccess();
    if (access.status === "authorized") {
      window.location.replace(roleUrl(access.role));
    } else if (access.status === "signed_out") {
      window.location.replace(siteUrl("login/"));
    } else {
      showPanel(access.status === "unassigned" ? pending : problem);
    }
  } catch {
    clearCredentialsFromUrl();
    showPanel(problem);
  }
}

retryButton.addEventListener("click", finishSignIn);
finishSignIn();
