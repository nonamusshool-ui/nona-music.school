(() => {
  const dialog = document.getElementById("application-modal");
  const form = document.getElementById("guitar-application");
  if (!dialog || !form) return;

  const packageInput = form.elements.lesson_package;
  const packageSelect = document.getElementById("lesson-package-select");
  const packagePicker = form.querySelector(".package-picker");
  const packageValue = document.getElementById("selected-package");
  const packageSummary = dialog.querySelector(".package-summary");
  const success = document.getElementById("modal-success");
  const submitButton = form.querySelector('button[type="submit"]');
  const closeButton = dialog.querySelector(".modal-close");
  const status = document.getElementById("form-status");
  const unspecified = "Ще не визначився";
  let opener = null;
  let pageScrollY = 0;
  let submitting = false;

  const openApplication = (trigger, selectedPackage = unspecified) => {
    if (dialog.open) return;
    opener = trigger;
    const hasPackage = selectedPackage !== unspecified;
    packageSelect.value = unspecified;
    packageInput.value = selectedPackage;
    packageValue.textContent = hasPackage ? selectedPackage : "";
    packageSummary.hidden = !hasPackage;
    packagePicker.hidden = hasPackage;
    success.hidden = true;
    form.hidden = false;
    status.className = "form-status";
    status.textContent = "";
    pageScrollY = window.scrollY;
    dialog.showModal();
    document.documentElement.classList.add("application-modal-open");
    document.body.classList.add("application-modal-open");
    form.elements.student_name.focus({ preventScroll: true });
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

  packageSelect.addEventListener("change", () => {
    packageInput.value = packageSelect.value;
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
