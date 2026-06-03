(function () {
  var btn = document.querySelector("[data-theme-toggle]");
  if (!btn) return;

  function current() {
    return (
      document.documentElement.dataset.theme ||
      (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light")
    );
  }

  function reflect() {
    btn.setAttribute("aria-pressed", current() === "dark" ? "true" : "false");
  }

  btn.addEventListener("click", function () {
    var next = current() === "dark" ? "light" : "dark";
    document.documentElement.dataset.theme = next;
    localStorage.setItem("theme", next);
    reflect();
  });

  reflect();
})();
