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

  document.querySelectorAll("[data-package]").forEach((link) => {
    link.addEventListener("click", (event) => {
      event.preventDefault();
      openApplication(link, link.dataset.package);
    });
  });

  document.querySelectorAll("[data-open-application]").forEach((trigger) => {
    trigger.addEventListener("click", (event) => {
      event.preventDefault();
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
        body: JSON.stringify(Object.fromEntries(new FormData(form))),
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
        body: JSON.stringify(Object.fromEntries(new FormData(form))),
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
