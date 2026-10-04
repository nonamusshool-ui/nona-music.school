import { callbackUrl, supabase } from "./supabase-client.js";
import { getAccess, landingUrl, siteUrl } from "./auth.js?v=2";

const googleButton = document.getElementById("google-sign-in");
const emailForm = document.getElementById("email-sign-in");
const emailButton = emailForm.querySelector('button[type="submit"]');
const status = document.getElementById("login-status");

const showStatus = (message, isError = false) => {
  status.textContent = message;
  status.classList.toggle("is-error", isError);
};

googleButton.addEventListener("click", async () => {
  googleButton.disabled = true;
  showStatus("Переходимо до Google…");
  try {
    const { error } = await supabase.auth.signInWithOAuth({
      provider: "google",
      options: { redirectTo: callbackUrl },
    });
    if (error) throw error;
  } catch {
    googleButton.disabled = false;
    showStatus("Не вдалося відкрити вхід через Google. Спробуйте ще раз.", true);
  }
});

emailForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  if (!emailForm.reportValidity() || emailButton.disabled) return;
  emailButton.disabled = true;
  showStatus("Надсилаємо посилання…");
  try {
    const { error } = await supabase.auth.signInWithOtp({
      email: emailForm.elements.email.value.trim(),
      options: { emailRedirectTo: callbackUrl, shouldCreateUser: false },
    });
    if (error) throw error;
    showStatus("Якщо для цієї адреси є обліковий запис, перевірте пошту.");
  } catch {
    showStatus("Не вдалося надіслати посилання. Спробуйте пізніше або зверніться до школи.", true);
  } finally {
    emailButton.disabled = false;
  }
});

const access = await getAccess();
if (access.status === "authorized") window.location.replace(landingUrl(access));
if (access.status === "unassigned" || access.status === "suspended") window.location.replace(siteUrl("auth/callback/"));
