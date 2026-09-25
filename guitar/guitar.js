(() => {
  const form = document.getElementById("guitar-application");
  if (!form) return;

  const packageSelect = form.elements.lesson_package;
  const submitButton = form.querySelector('button[type="submit"]');
  const status = document.getElementById("form-status");
  let submitting = false;

  document.querySelectorAll("[data-package]").forEach((link) => {
    link.addEventListener("click", () => {
      packageSelect.value = link.dataset.package;
    });
  });

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (submitting || !form.reportValidity()) return;

    submitting = true;
    submitButton.disabled = true;
    submitButton.textContent = "Надсилаємо...";
    status.className = "form-status";
    status.textContent = "";
    const selectedPackage = packageSelect.value;

    try {
      const response = await fetch(form.action, {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json" },
        body: JSON.stringify(Object.fromEntries(new FormData(form))),
      });
      const result = await response.json();
      if (!response.ok || result.success !== true) throw new Error("Web3Forms rejected the submission");

      form.reset();
      status.classList.add("is-success");
      const heading = document.createElement("strong");
      heading.textContent = "Заявку надіслано ✓";
      const message = document.createElement("span");
      message.textContent = "Дякуємо! НОНА зв’яжеться з вами, щоб домовитися про заняття.";
      status.replaceChildren(heading, message);
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
