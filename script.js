// Native details/summary keeps the mobile menu usable without JavaScript.
(() => {
  const menu = document.querySelector(".mobile-menu");
  if (!menu) return;
  const toggle = menu.querySelector("summary");
  const closeMenu = () => { menu.open = false; };
  menu.addEventListener("click", (event) => {
    if (event.target.closest("a")) closeMenu();
  });
  document.addEventListener("click", (event) => {
    if (menu.open && !menu.contains(event.target)) closeMenu();
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && menu.open) {
      closeMenu();
      toggle.focus();
    }
  });
  const desktop = window.matchMedia("(min-width: 721px)");
  desktop.addEventListener("change", (event) => {
    if (event.matches) closeMenu();
  });
})();

// Track the contact CTA without interrupting navigation or GA4 outbound clicks.
(() => {
  const cta = document.getElementById("trial-lesson-cta");
  if (!cta) return;

  cta.addEventListener("click", () => {
    if (typeof window.gtag !== "function") return;

    window.gtag("event", "facebook_click", {
      cta_location: "contact_section",
      cta_text: cta.textContent.trim(),
      link_url: cta.href,
    });
  });
})();
