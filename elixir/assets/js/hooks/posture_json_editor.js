// A textarea cannot underline a range of its own text, so the posture JSON is
// painted by a backdrop <pre> behind a transparent textarea. The backdrop follows
// keystrokes locally; the server only says which characters to mark.
export const PostureJsonEditor = {
  mounted() {
    this.textarea = this.el.querySelector("textarea");
    this.backdrop = this.el.querySelector("[data-backdrop]");
    this.onInput = () => this.render();
    this.onScroll = () => this.syncScroll();
    this.textarea.addEventListener("input", this.onInput);
    this.textarea.addEventListener("scroll", this.onScroll);
    this.render();
  },

  updated() {
    this.render();
  },

  destroyed() {
    this.textarea.removeEventListener("input", this.onInput);
    this.textarea.removeEventListener("scroll", this.onScroll);
  },

  render() {
    const text = this.textarea.value;
    const start = Number.parseInt(this.el.dataset.errorStart, 10);
    const length = Number.parseInt(this.el.dataset.errorLength, 10);
    const validated = Number.parseInt(this.el.dataset.validatedLength, 10);

    this.backdrop.replaceChildren();

    // The mark only makes sense for the text the server validated; while the
    // user keeps typing, paint plain text until the next validation lands.
    if (Number.isNaN(start) || validated !== text.length) {
      this.backdrop.append(text + "\n");
    } else {
      const mark = document.createElement("span");
      mark.className = this.el.dataset.markClass;
      mark.textContent = text.slice(start, start + length);
      this.backdrop.append(
        text.slice(0, start),
        mark,
        text.slice(start + length) + "\n"
      );
    }

    this.syncScroll();
  },

  syncScroll() {
    this.backdrop.scrollTop = this.textarea.scrollTop;
    this.backdrop.scrollLeft = this.textarea.scrollLeft;
  },
};
