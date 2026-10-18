// Technical lead attribution for Web3Forms. Stores only the entry context of this browser
// session (landing page, referrer, UTM, gclid) — never any form fields.
const leadAttribution = (() => {
  const storageKey = "nona_lead_attribution";
  const paramLimits = {
    utm_source: 200,
    utm_medium: 200,
    utm_campaign: 200,
    utm_content: 200,
    utm_term: 200,
    gclid: 300,
  };
  const urlLimit = 2000;
  const clean = (value, limit) => String(value ?? "").trim().slice(0, limit);

  const readStored = () => {
    try {
      const stored = JSON.parse(window.sessionStorage.getItem(storageKey) || "null");
      return stored && typeof stored === "object" ? stored : null;
    } catch (error) {
      return null;
    }
  };

  const capture = () => {
    let url = null;
    try {
      url = new URL(window.location.href);
    } catch (error) {
      // Without a readable URL there is no attribution to collect.
    }
    const stored = readStored();
    const hasCampaignParams = Boolean(url) && Object.keys(paramLimits).some((key) => url.searchParams.get(key));
    if (stored && !hasCampaignParams) return stored;

    if (url) url.hash = "";
    const context = {
      landing_page: clean(url?.href, urlLimit),
      referrer: clean(document.referrer, urlLimit),
    };
    Object.entries(paramLimits).forEach(([key, limit]) => {
      context[key] = clean(url?.searchParams.get(key), limit);
    });
    try {
      window.sessionStorage.setItem(storageKey, JSON.stringify(context));
    } catch (error) {
      // Storage may be unavailable; the context still lives for this page view.
    }
    return context;
  };

  const context = capture();

  const createLeadId = () => {
    try {
      if (typeof window.crypto?.randomUUID === "function") return `nona_${window.crypto.randomUUID()}`;
    } catch (error) {
      // Fall through to the non-crypto id.
    }
    return `nona_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 12)}`;
  };

  // Always the same set of fields; missing values are sent as empty strings.
  const fields = () => {
    const result = {
      lead_id: createLeadId(),
      submitted_at: new Date().toISOString(),
      landing_page: clean(context.landing_page, urlLimit),
      referrer: clean(context.referrer, urlLimit),
    };
    Object.entries(paramLimits).forEach(([key, limit]) => {
      result[key] = clean(context[key], limit);
    });
    return result;
  };

  return { fields };
})();

(() => {
  const dialog = document.getElementById("application-modal");
  const form = document.getElementById("guitar-application");
  if (!dialog || !form) return;

  const packageInput = form.elements.lesson_package;
  const packageValue = document.getElementById("selected-package");
  const packageSummary = dialog.querySelector(".package-summary");
  const formExtras = form.querySelector(".form-extras");
  const smartphone = window.matchMedia("(max-width: 720px)");
  const success = document.getElementById("modal-success");
  const submitButton = form.querySelector('button[type="submit"]');
  const closeButton = dialog.querySelector(".modal-close");
  const status = document.getElementById("form-status");
  const unspecified = "Ще не визначився";
  let opener = null;
  let pageScrollY = 0;
  let submitting = false;
  let ctaLocation = "other";
  let formStarted = false;

  const openApplication = (trigger, selectedPackage = unspecified) => {
    if (document.querySelector("dialog[open]")) return;
    opener = trigger;
    const hasPackage = selectedPackage !== unspecified;
    packageInput.value = selectedPackage;
    packageValue.textContent = hasPackage ? selectedPackage : "";
    packageSummary.hidden = !hasPackage;
    formExtras.open = false;
    ctaLocation = trigger.closest("[data-cta-location]")?.dataset.ctaLocation ?? "other";
    formStarted = false;
    success.hidden = true;
    form.hidden = false;
    status.className = "form-status";
    status.textContent = "";
    pageScrollY = window.scrollY;
    dialog.showModal();
    document.documentElement.classList.add("application-modal-open");
    document.body.classList.add("application-modal-open");
    (smartphone.matches ? closeButton : form.elements.student_name).focus({ preventScroll: true });
    if (typeof window.gtag === "function") {
      try {
        window.gtag("event", "trial_form_open", {
          form_name: "guitar_application",
          cta_location: ctaLocation,
        });
      } catch (error) {
        // Analytics must not interrupt opening the form.
      }
    }
  };

  const trackTrialCtaClick = (event, trigger, selectedPackage) => {
    if (!event.isTrusted || typeof window.gtag !== "function") return;
    try {
      const params = {
        form_name: "guitar_application",
        cta_location: trigger.closest("[data-cta-location]")?.dataset.ctaLocation ?? "other",
      };
      if (selectedPackage !== undefined) params.lesson_package = selectedPackage;
      window.gtag("event", "trial_cta_click", params);
    } catch (error) {
      // Analytics must not interrupt opening the form.
    }
  };

  document.querySelectorAll("[data-package]").forEach((link) => {
    link.addEventListener("click", (event) => {
      event.preventDefault();
      trackTrialCtaClick(event, link, link.dataset.package);
      openApplication(link, link.dataset.package);
    });
  });

  document.querySelectorAll("[data-open-application]").forEach((trigger) => {
    trigger.addEventListener("click", (event) => {
      event.preventDefault();
      trackTrialCtaClick(event, trigger);
      openApplication(trigger);
    });
  });

  const trackFormStart = (event) => {
    if (!event.isTrusted || !dialog.open || formStarted) return;
    if (!event.target.matches('input[name="student_name"], input[name="student_type"], input[name="phone"]')) return;
    if (event.type === "keydown" && ["Tab", "Escape", "Shift", "Control", "Alt", "Meta"].includes(event.key)) return;
    formStarted = true;
    if (typeof window.gtag !== "function") return;
    try {
      window.gtag("event", "trial_form_start", {
        form_name: "guitar_application",
        cta_location: ctaLocation,
      });
    } catch (error) {
      // Analytics must not interrupt filling in the form.
    }
  };
  ["pointerdown", "keydown", "input", "change"].forEach((type) => {
    form.addEventListener(type, trackFormStart);
  });

  closeButton.addEventListener("click", () => dialog.close());
  dialog.addEventListener("click", (event) => {
    if (event.target !== dialog) return;
    const bounds = dialog.getBoundingClientRect();
    if (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom) {
      dialog.close();
    }
  });
  dialog.addEventListener("close", () => {
    document.documentElement.classList.remove("application-modal-open");
    document.body.classList.remove("application-modal-open");
    opener?.focus({ preventScroll: true });
    window.scrollTo(0, pageScrollY);
  });

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (submitting || !form.reportValidity()) return;

    submitting = true;
    submitButton.disabled = true;
    submitButton.textContent = "Надсилаємо...";
    status.className = "form-status";
    status.textContent = "";
    const selectedPackage = packageInput.value;

    try {
      const response = await fetch(form.action, {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json" },
        // Form fields go last so attribution can never overwrite an existing field.
        body: JSON.stringify({ ...leadAttribution.fields(), ...Object.fromEntries(new FormData(form)) }),
      });
      const result = await response.json();
      if (!response.ok || result.success !== true) throw new Error("Web3Forms rejected the submission");

      form.reset();
      form.hidden = true;
      packageSummary.hidden = true;
      success.hidden = false;
      success.focus({ preventScroll: true });
      if (typeof window.gtag === "function") {
        try {
          window.gtag("event", "generate_lead", {
            form_name: "guitar_application",
            lead_type: "free_trial",
            lesson_package: selectedPackage,
          });
        } catch (error) {
          // Analytics must not replace a confirmed submission with an error message.
        }
      }
    } catch (error) {
      status.classList.add("is-error");
      status.textContent = "Не вдалося надіслати заявку. Спробуйте ще раз або зв’яжіться зі школою телефоном.";
    } finally {
      submitting = false;
      submitButton.disabled = false;
      submitButton.textContent = "Записатися на безкоштовний урок";
    }
  });
})();

document.querySelectorAll("[data-phone-click-location]").forEach((link) => {
  link.addEventListener("click", () => {
    if (typeof window.gtag !== "function") return;
    try {
      window.gtag("event", "phone_click", {
        cta_location: link.dataset.phoneClickLocation,
        link_url: link.getAttribute("href"),
      });
    } catch (error) {
      // Analytics must not interrupt the phone link.
    }
  });
});

(() => {
  const dialog = document.getElementById("family-application-modal");
  const form = document.getElementById("guitar-family-application");
  if (!dialog || !form) return;

  const success = document.getElementById("family-modal-success");
  const submitButton = form.querySelector('button[type="submit"]');
  const closeButton = dialog.querySelector(".modal-close");
  const status = document.getElementById("family-form-status");
  let opener = null;
  let pageScrollY = 0;
  let submitting = false;

  document.querySelectorAll("[data-open-family-application]").forEach((trigger) => {
    trigger.addEventListener("click", (event) => {
      event.preventDefault();
      if (document.querySelector("dialog[open]")) return;
      opener = trigger;
      success.hidden = true;
      form.hidden = false;
      status.className = "form-status";
      status.textContent = "";
      pageScrollY = window.scrollY;
      dialog.showModal();
      document.documentElement.classList.add("application-modal-open");
      document.body.classList.add("application-modal-open");
      (window.matchMedia("(max-width: 720px)").matches ? closeButton : form.elements.student_name).focus({ preventScroll: true });
    });
  });

  closeButton.addEventListener("click", () => dialog.close());
  dialog.addEventListener("click", (event) => {
    if (event.target !== dialog) return;
    const bounds = dialog.getBoundingClientRect();
    if (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom) {
      dialog.close();
    }
  });
  dialog.addEventListener("close", () => {
    document.documentElement.classList.remove("application-modal-open");
    document.body.classList.remove("application-modal-open");
    opener?.focus({ preventScroll: true });
    window.scrollTo(0, pageScrollY);
  });

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (submitting || !form.reportValidity()) return;

    submitting = true;
    submitButton.disabled = true;
    submitButton.textContent = "Надсилаємо...";
    status.className = "form-status";
    status.textContent = "";
    const selectedPackage = form.elements.lesson_package.value;

    try {
      const response = await fetch(form.action, {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json" },
        // Form fields go last so attribution can never overwrite an existing field.
        body: JSON.stringify({ ...leadAttribution.fields(), ...Object.fromEntries(new FormData(form)) }),
      });
      const result = await response.json();
      if (!response.ok || result.success !== true) throw new Error("Web3Forms rejected the submission");

      form.reset();
      form.hidden = true;
      success.hidden = false;
      success.focus({ preventScroll: true });
      if (typeof window.gtag === "function") {
        try {
          window.gtag("event", "generate_lead", {
            form_name: "guitar_family_application",
            lead_type: "family_price",
            lesson_package: selectedPackage,
          });
        } catch (error) {
          // Analytics must not replace a confirmed submission with an error message.
        }
      }
    } catch (error) {
      status.classList.add("is-error");
      status.textContent = "Не вдалося надіслати заявку. Спробуйте ще раз або зв’яжіться зі школою телефоном.";
    } finally {
      submitting = false;
      submitButton.disabled = false;
      submitButton.textContent = "Надіслати заявку";
    }
  });
})();

(() => {
  const openTeachersFromHash = () => {
    if (window.location.hash !== "#teachers") return;
    const teachers = document.getElementById("teachers");
    if (teachers?.tagName !== "DETAILS") return;
    teachers.open = true;
    teachers.scrollIntoView();
  };

  openTeachersFromHash();
  window.addEventListener("hashchange", openTeachersFromHash);
})();
