// A standalone popover/tooltip controller.
//
// Resolves a target element by id, attaches hover or click triggers, computes
// viewport-aware positioning (with placement flip and shift to keep on-screen),
// and exposes show/hide/toggle/reposition/destroy methods.
//
// Usage:
//   const popover = new Popover(triggerEl, {
//     target: "popover-content-id",   // element id or Element
//     placement: "top",                 // "top" | "bottom" | "left" | "right"
//     triggerType: "hover",             // "hover" | "click" | "manual"
//   });
//   popover.show(); popover.hide(); popover.toggle();
//   popover.destroy();                  // remove all listeners
//
// The target element is expected to:
//   - have `position: fixed` (so coords are viewport-relative)
//   - start with classes `invisible opacity-0` (the controller toggles these)
//   - optionally contain `[data-popper-arrow]` for an auto-styled arrow
//
// "Manual" trigger type skips event wiring — only show/hide/toggle calls and
// the dispatched `popover:show|hide|toggle` events on the trigger control it.

const DEFAULT_OFFSET = 5;
const DEFAULT_VIEWPORT_MARGIN = 8;
const DEFAULT_HOVER_HIDE_DELAY = 150;
const ARROW_SIZE = 8;
const VALID_PLACEMENTS = ["top", "bottom", "left", "right"];
const DEFAULT_PLACEMENT = "top";
const OPPOSITE_PLACEMENT = {
  top: "bottom",
  bottom: "top",
  left: "right",
  right: "left",
};

export class Popover {
  constructor(triggerEl, options = {}) {
    this.trigger = triggerEl;
    this.targetRef = options.target;
    this.placement = VALID_PLACEMENTS.includes(options.placement)
      ? options.placement
      : DEFAULT_PLACEMENT;
    this.triggerType = options.triggerType || "hover";
    this.offset = options.offset ?? DEFAULT_OFFSET;
    this.viewportMargin = options.viewportMargin ?? DEFAULT_VIEWPORT_MARGIN;
    this.hoverHideDelay = options.hoverHideDelay ?? DEFAULT_HOVER_HIDE_DELAY;

    this._visible = false;
    this._arrow = null;
    this._menuButton = null;
    this._teardownFns = [];
    this._visibleTeardownFns = null;

    if (this.triggerType === "hover") {
      this._attachHoverTrigger();
    } else if (this.triggerType === "click") {
      this._attachClickTrigger();
      this._setupMenuButtonAria();
    }

    this._attachDispatchHandlers();
  }

  get visible() {
    return this._visible;
  }

  show() {
    const target = this._resolveTarget();
    if (!target) return;
    this._styleArrow(target);
    this._position(target);
    if (this.triggerType === "click") this._applyMenuItemRoles(target);
    target.classList.remove("invisible", "opacity-0");
    this._visible = true;
    this._ensureTargetHoverListeners?.();
    if (this._menuButton) {
      this._menuButton.setAttribute("aria-expanded", "true");
    }
    this._attachVisibleListeners();
  }

  hide() {
    const target = this._resolveTarget();
    const wasVisible = this._visible;
    this._visible = false;
    if (target) target.classList.add("invisible", "opacity-0");
    if (this._menuButton) {
      this._menuButton.setAttribute("aria-expanded", "false");
      // Return focus to the trigger button if focus was inside the menu —
      // keeps keyboard users at a sensible spot after Escape / outside-click.
      if (wasVisible && target && target.contains(document.activeElement)) {
        this._menuButton.focus();
      }
    }
    this._detachVisibleListeners();
  }

  toggle() {
    this._visible ? this.hide() : this.show();
  }

  reposition() {
    if (!this._visible) return;
    const target = this._resolveTarget();
    if (target) this._position(target);
  }

  destroy() {
    this._detachVisibleListeners();
    for (const fn of this._teardownFns) fn();
    this._teardownFns = [];
  }

  _resolveTarget() {
    if (this.targetRef instanceof Element) return this.targetRef;
    if (typeof this.targetRef === "string") {
      return document.getElementById(this.targetRef);
    }
    return null;
  }

  _resolveTargetId() {
    if (typeof this.targetRef === "string") return this.targetRef;
    if (this.targetRef instanceof Element) return this.targetRef.id;
    return "";
  }

  // For click-trigger popovers (which render as menus in the template), wire
  // the standard menu-button ARIA on the inner button so screen readers know
  // the button controls a popup. aria-expanded is kept in sync by show/hide.
  _setupMenuButtonAria() {
    const button = this.trigger.querySelector("button") || this.trigger;
    const id = this._resolveTargetId();
    if (!button.hasAttribute("aria-haspopup")) {
      button.setAttribute("aria-haspopup", "menu");
    }
    if (id && !button.hasAttribute("aria-controls")) {
      button.setAttribute("aria-controls", id);
    }
    button.setAttribute("aria-expanded", "false");
    this._menuButton = button;
  }

  // Auto-label interactive items inside a menu so screen readers announce
  // them as menu items. Applied lazily on show because the content can be
  // re-rendered by LiveView. Skips items the caller has already roled.
  _applyMenuItemRoles(target) {
    target.querySelectorAll("a, button").forEach((item) => {
      if (!item.hasAttribute("role")) item.setAttribute("role", "menuitem");
    });
  }

  _attachHoverTrigger() {
    let hideTimer = null;
    const cancelHide = () => {
      if (hideTimer) {
        clearTimeout(hideTimer);
        hideTimer = null;
      }
    };
    const onShow = () => {
      cancelHide();
      this.show();
    };
    const onScheduleHide = () => {
      cancelHide();
      hideTimer = setTimeout(() => this.hide(), this.hoverHideDelay);
    };

    this.trigger.addEventListener("mouseenter", onShow);
    this.trigger.addEventListener("mouseleave", onScheduleHide);
    this.trigger.addEventListener("focusin", onShow);
    this.trigger.addEventListener("focusout", onScheduleHide);

    let target = null;
    const ensureTargetListeners = () => {
      const current = this._resolveTarget();
      if (current === target) return;
      if (target) {
        target.removeEventListener("mouseenter", onShow);
        target.removeEventListener("mouseleave", onScheduleHide);
      }
      target = current;
      if (target) {
        target.addEventListener("mouseenter", onShow);
        target.addEventListener("mouseleave", onScheduleHide);
      }
    };
    ensureTargetListeners();
    this._ensureTargetHoverListeners = ensureTargetListeners;

    this._teardownFns.push(() => {
      cancelHide();
      this.trigger.removeEventListener("mouseenter", onShow);
      this.trigger.removeEventListener("mouseleave", onScheduleHide);
      this.trigger.removeEventListener("focusin", onShow);
      this.trigger.removeEventListener("focusout", onScheduleHide);
      if (target) {
        target.removeEventListener("mouseenter", onShow);
        target.removeEventListener("mouseleave", onScheduleHide);
      }
    });
  }

  _attachClickTrigger() {
    const button = this.trigger.querySelector("button") || this.trigger;
    const onClick = (e) => {
      e.preventDefault();
      e.stopPropagation();
      this.toggle();
    };
    button.addEventListener("click", onClick);
    this._teardownFns.push(() => {
      button.removeEventListener("click", onClick);
    });
  }

  _attachDispatchHandlers() {
    const handlers = {
      "popover:show": () => this.show(),
      "popover:hide": () => this.hide(),
      "popover:toggle": () => this.toggle(),
    };
    for (const [event, handler] of Object.entries(handlers)) {
      this.trigger.addEventListener(event, handler);
    }
    this._teardownFns.push(() => {
      for (const [event, handler] of Object.entries(handlers)) {
        this.trigger.removeEventListener(event, handler);
      }
    });
  }

  // Listeners that only matter while the popover is visible: window
  // scroll/resize for repositioning, and (for click triggers) document
  // pointerdown/keydown for outside-click and Escape dismissal. Attaching
  // these on show() instead of mount() keeps the page from accumulating
  // global listeners proportional to the number of (mostly idle) popovers.
  _attachVisibleListeners() {
    if (this._visibleTeardownFns) return;

    const onReposition = () => this.reposition();
    window.addEventListener("scroll", onReposition, {
      passive: true,
      capture: true,
    });
    window.addEventListener("resize", onReposition);

    const fns = [
      () =>
        window.removeEventListener("scroll", onReposition, { capture: true }),
      () => window.removeEventListener("resize", onReposition),
    ];

    if (this.triggerType === "click") {
      const onDocumentPointerDown = (e) => {
        const target = this._resolveTarget();
        if (this.trigger.contains(e.target)) return;
        if (target && target.contains(e.target)) return;
        this.hide();
      };
      const onKeydown = (e) => {
        if (e.key === "Escape") this.hide();
      };
      document.addEventListener("pointerdown", onDocumentPointerDown, true);
      document.addEventListener("keydown", onKeydown);
      fns.push(
        () =>
          document.removeEventListener(
            "pointerdown",
            onDocumentPointerDown,
            true
          ),
        () => document.removeEventListener("keydown", onKeydown)
      );
    }

    this._visibleTeardownFns = fns;
  }

  _detachVisibleListeners() {
    if (!this._visibleTeardownFns) return;
    for (const fn of this._visibleTeardownFns) fn();
    this._visibleTeardownFns = null;
  }

  _styleArrow(target) {
    const arrow = target.querySelector("[data-popper-arrow]");
    if (!arrow) {
      this._arrow = null;
      return;
    }
    const styles = getComputedStyle(target);
    Object.assign(arrow.style, {
      position: "absolute",
      width: `${ARROW_SIZE}px`,
      height: `${ARROW_SIZE}px`,
      backgroundColor: styles.backgroundColor,
      transform: "rotate(45deg)",
      borderStyle: "solid",
      borderWidth: "0",
      borderColor: styles.borderTopColor,
      pointerEvents: "none",
    });
    this._arrow = arrow;
  }

  _position(target) {
    const triggerRect = this.trigger.getBoundingClientRect();
    const targetRect = target.getBoundingClientRect();
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    const margin = this.viewportMargin;

    const compute = (placement) => {
      switch (placement) {
        case "top":
          return {
            top: triggerRect.top - targetRect.height - this.offset,
            left:
              triggerRect.left + triggerRect.width / 2 - targetRect.width / 2,
          };
        case "bottom":
          return {
            top: triggerRect.bottom + this.offset,
            left:
              triggerRect.left + triggerRect.width / 2 - targetRect.width / 2,
          };
        case "left":
          return {
            top:
              triggerRect.top + triggerRect.height / 2 - targetRect.height / 2,
            left: triggerRect.left - targetRect.width - this.offset,
          };
        case "right":
          return {
            top:
              triggerRect.top + triggerRect.height / 2 - targetRect.height / 2,
            left: triggerRect.right + this.offset,
          };
      }
    };

    const fits = (placement, pos) => {
      switch (placement) {
        case "top":
          return pos.top >= margin;
        case "bottom":
          return pos.top + targetRect.height <= vh - margin;
        case "left":
          return pos.left >= margin;
        case "right":
          return pos.left + targetRect.width <= vw - margin;
      }
    };

    let placement = this.placement;
    let pos = compute(placement);

    if (!fits(placement, pos)) {
      const flipped = OPPOSITE_PLACEMENT[placement];
      const flippedPos = compute(flipped);
      if (fits(flipped, flippedPos)) {
        placement = flipped;
        pos = flippedPos;
      }
    }

    if (placement === "top" || placement === "bottom") {
      pos.left = Math.max(
        margin,
        Math.min(pos.left, vw - targetRect.width - margin)
      );
    } else {
      pos.top = Math.max(
        margin,
        Math.min(pos.top, vh - targetRect.height - margin)
      );
    }

    // Arrow math uses viewport-relative pos to align with the trigger.
    this._positionArrow(placement, triggerRect, targetRect, pos);

    // If the popover lives inside a transformed/contained ancestor, that
    // ancestor becomes the containing block for `position: fixed`, so
    // top/left are interpreted relative to it. Subtract its viewport offset.
    const containingBlock = getFixedContainingBlock(target);
    if (containingBlock) {
      const cbRect = containingBlock.getBoundingClientRect();
      pos.top -= cbRect.top;
      pos.left -= cbRect.left;
    }

    target.style.top = `${pos.top}px`;
    target.style.left = `${pos.left}px`;
  }

  _positionArrow(placement, triggerRect, targetRect, pos) {
    if (!this._arrow) return;
    const arrow = this._arrow;
    const half = ARROW_SIZE / 2;

    arrow.style.borderWidth = "0";

    if (placement === "top" || placement === "bottom") {
      const triggerCenterX = triggerRect.left + triggerRect.width / 2;
      const arrowLeft = triggerCenterX - pos.left - half;
      arrow.style.left = `${Math.max(
        half,
        Math.min(arrowLeft, targetRect.width - ARROW_SIZE - half)
      )}px`;
      arrow.style.right = "";
      if (placement === "top") {
        arrow.style.top = `${targetRect.height - half}px`;
        arrow.style.bottom = "";
        arrow.style.borderRightWidth = "1px";
        arrow.style.borderBottomWidth = "1px";
      } else {
        arrow.style.top = `${-half}px`;
        arrow.style.bottom = "";
        arrow.style.borderLeftWidth = "1px";
        arrow.style.borderTopWidth = "1px";
      }
    } else {
      const triggerCenterY = triggerRect.top + triggerRect.height / 2;
      const arrowTop = triggerCenterY - pos.top - half;
      arrow.style.top = `${Math.max(
        half,
        Math.min(arrowTop, targetRect.height - ARROW_SIZE - half)
      )}px`;
      arrow.style.bottom = "";
      if (placement === "left") {
        arrow.style.left = `${targetRect.width - half}px`;
        arrow.style.right = "";
        arrow.style.borderTopWidth = "1px";
        arrow.style.borderRightWidth = "1px";
      } else {
        arrow.style.left = `${-half}px`;
        arrow.style.right = "";
        arrow.style.borderBottomWidth = "1px";
        arrow.style.borderLeftWidth = "1px";
      }
    }
  }
}

// A `position: fixed` element is positioned relative to the viewport — UNLESS
// an ancestor establishes a containing block via any of: `transform`, the
// individual `translate`/`rotate`/`scale` properties (Tailwind v4 emits these
// instead of `transform`), `perspective`, `filter`, `backdrop-filter`,
// `will-change: transform/filter`, or `contain: paint/layout/strict/content`.
// In that case, top/left are relative to that ancestor — so we walk the chain
// to find it and subtract its viewport offset.
function getFixedContainingBlock(el) {
  let ancestor = el.parentElement;
  while (ancestor && ancestor !== document.documentElement) {
    const styles = getComputedStyle(ancestor);
    if (
      styles.transform !== "none" ||
      styles.translate !== "none" ||
      styles.rotate !== "none" ||
      styles.scale !== "none" ||
      styles.perspective !== "none" ||
      styles.filter !== "none" ||
      styles.backdropFilter !== "none" ||
      styles.willChange.includes("transform") ||
      styles.willChange.includes("filter") ||
      styles.contain.includes("paint") ||
      styles.contain.includes("layout") ||
      styles.contain.includes("strict") ||
      styles.contain.includes("content")
    ) {
      return ancestor;
    }
    ancestor = ancestor.parentElement;
  }
  return null;
}
