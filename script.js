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
