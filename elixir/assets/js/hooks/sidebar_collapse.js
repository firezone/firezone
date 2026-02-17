export const SidebarCollapse = {
  applyCollapsed(collapsed) {
    const sidebar = document.getElementById("sidebar");
    if (!sidebar) return;

    const labels = sidebar.querySelectorAll("[data-sidebar-label]");
    const groupLabels = sidebar.querySelectorAll("[data-sidebar-group-label]");
    const navItems = sidebar.querySelectorAll("[data-sidebar-nav-item]");
    const wordmark = sidebar.querySelector("[data-sidebar-wordmark]");
    const chevron = this.el.querySelector("[data-sidebar-chevron]");

    if (collapsed) {
      sidebar.classList.replace("w-56", "w-14");
      labels.forEach((el) => {
        el.classList.add("max-w-0", "opacity-0", "overflow-hidden");
        el.classList.remove("max-w-xs", "opacity-100");
      });
      groupLabels.forEach((el) => el.classList.add("hidden"));
      navItems.forEach((el) => {
        el.style.justifyContent = "center";
        el.style.gap = "0";
      });
      if (wordmark) {
        wordmark.style.justifyContent = "center";
        wordmark.style.padding = "0";
        const wordmarkLink = wordmark.querySelector("a");
        if (wordmarkLink) wordmarkLink.style.gap = "0";
        wordmark.querySelectorAll("[data-sidebar-label]").forEach((el) => {
          el.style.display = "none";
        });
      }
      if (chevron) chevron.classList.add("rotate-180");
    } else {
      sidebar.classList.replace("w-14", "w-56");
      labels.forEach((el) => {
        el.classList.remove("max-w-0", "opacity-0", "overflow-hidden");
        el.classList.add("max-w-xs", "opacity-100");
      });
      groupLabels.forEach((el) => el.classList.remove("hidden"));
      navItems.forEach((el) => {
        el.style.justifyContent = "";
        el.style.gap = "";
      });
      if (wordmark) {
        wordmark.style.justifyContent = "";
        wordmark.style.padding = "";
        const wordmarkLink = wordmark.querySelector("a");
        if (wordmarkLink) wordmarkLink.style.gap = "";
        wordmark.querySelectorAll("[data-sidebar-label]").forEach((el) => {
          el.style.display = "";
        });
      }
      if (chevron) chevron.classList.remove("rotate-180");
    }
  },

  mounted() {
    const mq = window.matchMedia("(max-width: 1023px)");
    this._autoCollapse = (e) => {
      if (e.matches) {
        this.applyCollapsed(true);
      } else {
        this.applyCollapsed(localStorage.sidebarCollapsed === "true");
      }
    };
    mq.addEventListener("change", this._autoCollapse);
    this._mq = mq;
    this._autoCollapse({ matches: mq.matches });

    this.el.addEventListener("click", () => {
      const sidebar = document.getElementById("sidebar");
      const collapsed = sidebar.classList.contains("w-14");
      this.applyCollapsed(!collapsed);
      if (!this._mq.matches) {
        localStorage.sidebarCollapsed = !collapsed;
      }
    });
  },

  updated() {
    if (this._mq && this._mq.matches) {
      this.applyCollapsed(true);
    } else {
      this.applyCollapsed(localStorage.sidebarCollapsed === "true");
    }
  },

  destroyed() {
    if (this._mq && this._autoCollapse) {
      this._mq.removeEventListener("change", this._autoCollapse);
    }
  },
};
