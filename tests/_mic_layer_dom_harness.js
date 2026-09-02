// Dinleme Modu viewer'ının <script> gövdesini gerçek bir tarayıcı olmadan
// çalıştırmak için minimal bir DOM/BOM sahtesi. Yalnızca script'in kayıtsız
// biçimde yüklenip mikrofon API'sini çağırabilmesi için yeterli davranışı
// taklit eder; gerçek düzen/görsel doğruluk hedeflenmez.
//
// ÖNEMLİ: Aşağıdaki isimlerin hiçbiri viewer script'inin üst düzey
// const/let/function isimleriyle (media, canvas, ctx, duration, tick, ...)
// çakışmamalı; bu yüzden her şey bir IIFE içinde tutulur ve dışarıya yalnızca
// globalThis üzerinden (document, window, localStorage, ...) sızdırılır.
(function () {
  class ClassList {
    constructor() {
      this._set = new Set();
    }
    add() {
      for (const c of arguments) if (c) this._set.add(c);
    }
    remove() {
      for (const c of arguments) this._set.delete(c);
    }
    toggle(c, force) {
      if (force === undefined) {
        if (this._set.has(c)) {
          this._set.delete(c);
          return false;
        }
        this._set.add(c);
        return true;
      }
      if (force) this._set.add(c);
      else this._set.delete(c);
      return force;
    }
    contains(c) {
      return this._set.has(c);
    }
    get value() {
      return Array.from(this._set).join(" ");
    }
  }

  function makeStyle() {
    const store = {};
    return new Proxy(
      {
        setProperty(k, v) {
          store[k] = v;
        },
        getPropertyValue(k) {
          return store[k] || "";
        },
        removeProperty(k) {
          delete store[k];
        },
      },
      {
        get(target, prop) {
          if (prop in target) return target[prop];
          return store[prop];
        },
        set(target, prop, value) {
          store[prop] = value;
          return true;
        },
      }
    );
  }

  class RawEl {
    constructor(tag) {
      this.tagName = String(tag || "div").toUpperCase();
      this.children = [];
      this.parentNode = null;
      this.attrs = {};
      this.dataset = {};
      this._id = "";
      this.classList = new ClassList();
      this.style = makeStyle();
      this._listeners = {};
      this._value = "";
      this.selected = false;
      this.checked = false;
      this.disabled = false;
      this.hidden = false;
      this.textContent = "";
    }
    get parentElement() {
      return this.parentNode;
    }
    get id() {
      return this._id;
    }
    set id(v) {
      this._id = v;
    }
    get className() {
      return this.classList.value;
    }
    set className(v) {
      this.classList = new ClassList();
      String(v || "")
        .split(/\s+/)
        .filter(Boolean)
        .forEach((c) => this.classList.add(c));
    }
    get options() {
      return this.tagName === "SELECT" ? this.children.filter((c) => c.tagName === "OPTION") : [];
    }
    get selectedOptions() {
      return this.options.filter((o) => o.selected);
    }
    get value() {
      if (this.tagName === "SELECT") {
        const sel = this.children.find((o) => o.tagName === "OPTION" && o.selected);
        return sel ? sel.value : "";
      }
      return this._value;
    }
    set value(v) {
      if (this.tagName === "SELECT") {
        this.children.forEach((o) => {
          if (o.tagName === "OPTION") o.selected = String(o.value) === String(v);
        });
        return;
      }
      this._value = v;
    }
    setAttribute(k, v) {
      this.attrs[k] = String(v);
      if (k === "id") this._id = v;
    }
    getAttribute(k) {
      return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null;
    }
    removeAttribute(k) {
      delete this.attrs[k];
    }
    addEventListener(type, fn) {
      (this._listeners[type] = this._listeners[type] || []).push(fn);
    }
    removeEventListener(type, fn) {
      if (this._listeners[type]) this._listeners[type] = this._listeners[type].filter((f) => f !== fn);
    }
    dispatchEvent(evt) {
      (this._listeners[evt.type] || []).forEach((fn) => fn(evt));
      if (typeof this["on" + evt.type] === "function") this["on" + evt.type](evt);
      return true;
    }
    click() {
      this.dispatchEvent(new Event("click"));
    }
    append() {
      for (const n of arguments)
        if (n && typeof n === "object") {
          n.parentNode = this;
          this.children.push(n);
        }
    }
    appendChild(n) {
      n.parentNode = this;
      this.children.push(n);
      return n;
    }
    prepend() {
      for (const n of arguments)
        if (n && typeof n === "object") {
          n.parentNode = this;
          this.children.unshift(n);
        }
    }
    insertBefore(n, ref) {
      const i = this.children.indexOf(ref);
      n.parentNode = this;
      if (i < 0) this.children.push(n);
      else this.children.splice(i, 0, n);
      return n;
    }
    before() {
      if (!this.parentNode) return;
      const i = this.parentNode.children.indexOf(this);
      let k = 0;
      for (const n of arguments) {
        n.parentNode = this.parentNode;
        this.parentNode.children.splice(i + k, 0, n);
        k++;
      }
    }
    after() {
      if (!this.parentNode) return;
      const i = this.parentNode.children.indexOf(this);
      let k = 0;
      for (const n of arguments) {
        n.parentNode = this.parentNode;
        this.parentNode.children.splice(i + 1 + k, 0, n);
        k++;
      }
    }
    remove() {
      if (!this.parentNode) return;
      const i = this.parentNode.children.indexOf(this);
      if (i >= 0) this.parentNode.children.splice(i, 1);
      this.parentNode = null;
    }
    replaceChildren() {
      this.children.forEach((c) => (c.parentNode = null));
      this.children = [];
      for (const n of arguments) {
        n.parentNode = this;
        this.children.push(n);
      }
    }
    querySelectorAll(sel) {
      return queryAll(this, sel);
    }
    querySelector(sel) {
      return queryAll(this, sel)[0] || null;
    }
    closest(sel) {
      let node = this;
      while (node) {
        if (matchesSimple(node, sel)) return node;
        node = node.parentNode;
      }
      return null;
    }
    matches(sel) {
      return matchesSimple(this, sel);
    }
    setPointerCapture() {}
    releasePointerCapture() {}
    showModal() {}
    close() {}
    focus() {}
    blur() {}
    getBoundingClientRect() {
      return { left: 0, top: 0, right: 960, bottom: 540, width: 960, height: 540 };
    }
  }

  function parseSimpleSelector(sel) {
    sel = sel.trim();
    let attr = null;
    const attrMatch = sel.match(/\[([\w-]+)\]/);
    if (attrMatch) {
      attr = attrMatch[1];
      sel = sel.replace(attrMatch[0], "");
    }
    let id = null;
    const idMatch = sel.match(/#([\w-]+)/);
    if (idMatch) {
      id = idMatch[1];
      sel = sel.replace(idMatch[0], "");
    }
    let classes = [];
    const classMatches = sel.match(/\.[\w-]+/g);
    if (classMatches) {
      classes = classMatches.map((c) => c.slice(1));
      sel = sel.replace(/\.[\w-]+/g, "");
    }
    sel = sel.trim();
    const tag = sel ? sel.toUpperCase() : null;
    return { tag: tag, id: id, classes: classes, attr: attr };
  }

  function elementMatchesSimple(node, simple) {
    if (simple.tag && node.tagName !== simple.tag) return false;
    if (simple.id && node.id !== simple.id) return false;
    if (simple.classes.length && !simple.classes.every((c) => node.classList.contains(c))) return false;
    if (simple.attr) {
      const hasAttr = node.getAttribute(simple.attr) !== null;
      if (!hasAttr) return false;
    }
    return true;
  }

  // 'main > p' gibi tek seviyeli çocuk birleştiricisini destekler; script bunun
  // dışında yalnızca basit seçiciler kullanıyor.
  function matchesSimple(node, sel) {
    if (sel.indexOf(">") >= 0) {
      const parts = sel.split(">").map((s) => s.trim());
      const childSimple = parseSimpleSelector(parts[parts.length - 1]);
      const parentSimple = parseSimpleSelector(parts[parts.length - 2]);
      if (!elementMatchesSimple(node, childSimple)) return false;
      return !!(node.parentNode && elementMatchesSimple(node.parentNode, parentSimple));
    }
    return elementMatchesSimple(node, parseSimpleSelector(sel));
  }

  function queryAll(root, sel) {
    const out = [];
    (function walk(node) {
      for (const child of node.children) {
        if (matchesSimple(child, sel)) out.push(child);
        walk(child);
      }
    })(root);
    return out;
  }

  function mk(tag, id, className) {
    const el = new RawEl(tag);
    if (id) el.id = id;
    if (className) el.className = className;
    return el;
  }

  function opt(value, selected) {
    const o = new RawEl("option");
    o._value = value;
    o.selected = !!selected;
    return o;
  }

  function labelWrap() {
    const l = new RawEl("label");
    l.append.apply(l, arguments);
    return l;
  }

  globalThis.Event = class Event {
    constructor(type, opts) {
      this.type = type;
      Object.assign(this, opts || {});
    }
  };
  globalThis.ResizeObserver = class ResizeObserver {
    constructor(cb) {
      this._cb = cb;
    }
    observe() {}
    unobserve() {}
    disconnect() {}
  };
  globalThis.devicePixelRatio = 1;
  globalThis.location = { protocol: "http:" };
  globalThis.requestAnimationFrame = function () {};
  globalThis.addEventListener = function () {};

  globalThis.localStorage = (function () {
    const store = {};
    return {
      getItem(k) {
        return Object.prototype.hasOwnProperty.call(store, k) ? store[k] : null;
      },
      setItem(k, v) {
        store[k] = String(v);
      },
      removeItem(k) {
        delete store[k];
      },
    };
  })();

  // canvas 2D bağlamı: yalnızca moveTo/lineTo kaydedilir, gerisi no-op'tur.
  globalThis.__ctxOps = [];
  globalThis.__resetCtxOps = function () {
    globalThis.__ctxOps.length = 0;
  };
  const noop = function () {};
  const ctx2d = new Proxy(
    {},
    {
      get(target, prop) {
        if (prop === "moveTo") return (x, y) => globalThis.__ctxOps.push(["M", x, y]);
        if (prop === "lineTo") return (x, y) => globalThis.__ctxOps.push(["L", x, y]);
        if (
          [
            "clearRect",
            "fillRect",
            "strokeRect",
            "beginPath",
            "stroke",
            "fill",
            "save",
            "restore",
            "clip",
            "rect",
            "fillText",
            "closePath",
            "arc",
            "setTransform",
          ].indexOf(prop) >= 0
        )
          return noop;
        return target[prop];
      },
      set(target, prop, value) {
        target[prop] = value;
        return true;
      },
    }
  );

  const canvasEl = new RawEl("canvas");
  canvasEl.id = "chart";
  canvasEl._clientWidth = 960;
  canvasEl._clientHeight = 540;
  Object.defineProperty(canvasEl, "clientWidth", {
    get() {
      return this._clientWidth;
    },
    set(v) {
      this._clientWidth = v;
    },
  });
  Object.defineProperty(canvasEl, "clientHeight", {
    get() {
      return this._clientHeight;
    },
    set(v) {
      this._clientHeight = v;
    },
  });
  canvasEl.width = 960;
  canvasEl.height = 540;
  canvasEl.getContext = function () {
    return ctx2d;
  };

  const mediaEl = new RawEl("audio");
  mediaEl.id = "media";
  mediaEl.currentTime = 0;
  mediaEl.duration = NaN;
  mediaEl.paused = true;
  mediaEl.muted = false;
  mediaEl.playbackRate = 1;
  mediaEl.defaultPlaybackRate = 1;
  mediaEl.readyState = 4;
  mediaEl.play = function () {
    this.paused = false;
    this.dispatchEvent(new Event("play"));
    return {
      then(cb) {
        if (cb) cb();
        return this;
      },
      catch() {
        return this;
      },
    };
  };
  mediaEl.pause = function () {
    this.paused = true;
    this.dispatchEvent(new Event("pause"));
  };

  // --- Gerçek şablonun DOM ağacının minyatür kopyası ---
  const bodyEl = mk("body");
  const headEl = mk("head");

  const h1 = mk("h1");
  const newRecording = mk("a", "new-recording");
  const descriptionP = mk("p");
  const layoutToolsDiv = mk("div", null, "layout-tools");
  const layoutModeSelect = mk("select", "layout-mode");
  layoutModeSelect.append(opt("stacked", true), opt("side", false), opt("side-right", false));
  layoutToolsDiv.append(labelWrap(layoutModeSelect));

  const mediaPanel = mk("div", "media-panel", "media");
  mediaPanel.append(mediaEl);

  const minusBtn = mk("button", "minus");
  const plusBtn = mk("button", "plus");
  const windowInput = mk("input", "window");
  windowInput._value = "12";
  const verticalOutBtn = mk("button", "vertical-out");
  const verticalInBtn = mk("button", "vertical-in");
  const scaleModeSelect = mk("select", "scale-mode");
  [
    "major",
    "minor",
    "nihavent",
    "kurdi",
    "ussak",
    "hicaz",
    "kurdilihicazkar",
    "hicazkar",
    "turkish",
  ].forEach((value, index) => scaleModeSelect.append(opt(value, index === 0)));
  const makamSettingsOpenBtn = mk("button", "makam-settings-open");
  const makamStatusSpan = mk("span", "makam-status");
  const tonicSelect = mk("select", "tonic");
  ["0", "2", "4", "5", "7", "9", "11"].forEach((value, index) => tonicSelect.append(opt(value, index === 0)));
  const countdownInputEl = mk("input", "countdown");
  countdownInputEl._value = "0";
  const playToggleBtn = mk("button", "play-toggle");
  const countdownStatusSpan = mk("span", "countdown-status");
  const setAButton = mk("button", "set-a");
  setAButton.disabled = true;
  const setBButton = mk("button", "set-b");
  setBButton.disabled = true;
  const loopButtonEl = mk("button", "loop");
  loopButtonEl.disabled = true;
  loopButtonEl.setAttribute("aria-pressed", "false");
  const resetBtn = mk("button", "reset");
  const legendSpan = mk("span", null, "legend");

  const toolsDiv = mk("div", null, "tools");
  toolsDiv.append(
    minusBtn,
    plusBtn,
    labelWrap(windowInput),
    verticalOutBtn,
    verticalInBtn,
    labelWrap(scaleModeSelect),
    makamSettingsOpenBtn,
    makamStatusSpan,
    labelWrap(tonicSelect),
    labelWrap(countdownInputEl),
    playToggleBtn,
    countdownStatusSpan,
    setAButton,
    setBButton,
    loopButtonEl,
    resetBtn,
    legendSpan
  );

  const verticalScrollEl = mk("input", "vertical-scroll");
  const timeScrollEl = mk("input", "time-scroll");
  const chartPanelDiv = mk("div", "chart-panel", "chart-scroll");
  chartPanelDiv.append(canvasEl, verticalScrollEl, timeScrollEl, mk("span"));
  const noteP = mk("p", null, "note");

  const panelSection = mk("section", null, "panel");
  panelSection.append(toolsDiv, chartPanelDiv, noteP);

  const workspaceDiv = mk("div", "workspace", "workspace");
  workspaceDiv.append(mediaPanel, panelSection);

  const verticalFollowInput = mk("input", "vertical-follow");
  verticalFollowInput.checked = false;
  const playbackRateSelect = mk("select", "playback-rate");
  [
    "0.10", "0.15", "0.20", "0.25", "0.30", "0.35", "0.40", "0.45", "0.50",
    "0.55", "0.60", "0.65", "0.70", "0.75", "0.80", "0.85", "0.90", "0.95", "1.00",
  ].forEach((value) => playbackRateSelect.append(opt(value, value === "1.00")));
  const firstSettingsActions = mk("div", null, "settings-actions");
  firstSettingsActions.append(labelWrap(verticalFollowInput), labelWrap(playbackRateSelect));

  const makamSettingsModeSelect = mk("select", "makam-settings-mode");
  ["nihavent", "kurdi", "ussak", "hicaz", "kurdilihicazkar", "hicazkar"].forEach((value, index) =>
    makamSettingsModeSelect.append(opt(value, index === 0))
  );
  const makamSettingsGridDiv = mk("div", "makam-settings-grid", "settings-grid");
  const makamSettingsTotalDiv = mk("div", "makam-settings-total", "settings-total");
  const makamSettingsResetBtn = mk("button", "makam-settings-reset");
  const cancelBtn = mk("button");
  cancelBtn._value = "cancel";
  const makamSettingsApplyBtn = mk("button", "makam-settings-apply");
  const secondSettingsActions = mk("div", null, "settings-actions");
  secondSettingsActions.append(makamSettingsResetBtn, cancelBtn, makamSettingsApplyBtn);

  const settingsForm = mk("form", null, "settings-form");
  settingsForm.append(
    mk("h2"),
    mk("p"),
    firstSettingsActions,
    labelWrap(makamSettingsModeSelect),
    makamSettingsGridDiv,
    makamSettingsTotalDiv,
    secondSettingsActions
  );
  const makamSettingsDialogEl = mk("dialog", "makam-settings");
  makamSettingsDialogEl.append(settingsForm);

  const mainEl = mk("main");
  mainEl.append(h1, newRecording, descriptionP, layoutToolsDiv, workspaceDiv, makamSettingsDialogEl);
  bodyEl.append(mainEl);

  globalThis.window = globalThis;
  globalThis.document = {
    head: headEl,
    body: bodyEl,
    documentElement: mk("html"),
    createElement(tag) {
      return new RawEl(tag);
    },
    getElementById(id) {
      return queryAll(bodyEl, "#" + id)[0] || null;
    },
    querySelector(sel) {
      return queryAll(bodyEl, sel)[0] || null;
    },
    querySelectorAll(sel) {
      return queryAll(bodyEl, sel);
    },
    addEventListener() {},
    removeEventListener() {},
  };
})();
