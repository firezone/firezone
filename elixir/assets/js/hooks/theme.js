function getTheme() {
  return localStorage.theme || "system";
}

function setTheme(theme) {
  if (theme === "system") {
    localStorage.removeItem("theme");
  } else {
    localStorage.theme = theme;
  }
}

function applyTheme(theme, mediaQuery) {
  const isDark = theme === "dark" || (theme === "system" && mediaQuery.matches);
  document.documentElement.classList.toggle("dark", isDark);
  document.documentElement.dataset.theme = theme;
}

export const ThemeToggle = {
  mounted() {
    this._mediaQuery = window.matchMedia("(prefers-color-scheme: dark)");
    this._mediaListener = () => {
      if (getTheme() === "system") {
        applyTheme("system", this._mediaQuery);
      }
    };
    this._mediaQuery.addEventListener("change", this._mediaListener);

    applyTheme(getTheme(), this._mediaQuery);

    this.el.querySelectorAll("[data-theme-option]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const theme = btn.dataset.themeOption;
        setTheme(theme);
        applyTheme(theme, this._mediaQuery);
      });
    });
  },

  destroyed() {
    this._mediaQuery.removeEventListener("change", this._mediaListener);
  },
};
