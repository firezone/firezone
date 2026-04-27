export const TimePicker = {
  mounted() {
    this.el.querySelectorAll("button[data-target]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const input = this.el.querySelector(
          `input[id$="_${btn.dataset.target}"]`
        );
        if (input && typeof input.showPicker === "function") {
          input.showPicker();
        }
      });
    });
  },
};
