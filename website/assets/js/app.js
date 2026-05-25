// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/website"
import topbar from "../vendor/topbar"

import {EditorView, keymap, lineNumbers, highlightActiveLine, drawSelection, dropCursor, rectangularSelection, crosshairCursor, highlightSpecialChars} from "@codemirror/view"
import {EditorState, Compartment} from "@codemirror/state"
import {defaultKeymap, history, historyKeymap, indentWithTab} from "@codemirror/commands"
import {StreamLanguage, syntaxHighlighting, defaultHighlightStyle, indentOnInput, bracketMatching, foldKeymap} from "@codemirror/language"
import {closeBrackets, closeBracketsKeymap} from "@codemirror/autocomplete"
import {highlightSelectionMatches, searchKeymap} from "@codemirror/search"
import {lua} from "@codemirror/legacy-modes/mode/lua"
import {oneDark} from "@codemirror/theme-one-dark"

const themeCompartment = new Compartment()

const editorTheme = EditorView.theme({
  "&": {
    height: "100%",
    fontSize: "13px",
    backgroundColor: "transparent",
  },
  "&.cm-focused": {
    outline: "none",
  },
  ".cm-content": {
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace",
    padding: "12px 0",
    caretColor: "var(--color-primary, #6366f1)",
  },
  ".cm-scroller": {
    fontFamily: "inherit",
    overflow: "auto",
    lineHeight: "1.55",
  },
  ".cm-gutters": {
    backgroundColor: "transparent",
    border: "none",
    color: "color-mix(in oklch, currentColor 35%, transparent)",
  },
  ".cm-activeLineGutter, .cm-activeLine": {
    backgroundColor: "color-mix(in oklch, currentColor 6%, transparent)",
  },
  ".cm-lineNumbers .cm-gutterElement": {
    padding: "0 12px 0 8px",
    minWidth: "2.5em",
  },
})

function darkActive() {
  const t = document.documentElement.dataset.theme
  if (t === "dark") return true
  if (t === "light") return false
  return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches
}

function themeExt() {
  return darkActive() ? oneDark : []
}

// localStorage key used by the playground editor's autosave.
const PLAYGROUND_STORAGE_KEY = "playground:source"

const LuaEditor = {
  mounted() {
    const textarea = this.el.querySelector("textarea")
    if (!textarea) return

    this.textarea = textarea
    // Hide the underlying textarea but keep it in the form.
    textarea.style.display = "none"
    textarea.setAttribute("tabindex", "-1")
    textarea.setAttribute("aria-hidden", "true")

    const storageKey = this.el.dataset.storageKey
    const restoreFromStorage = (() => {
      if (!storageKey) return null
      const url = new URL(window.location.href)
      if (url.pathname !== "/playground") return null
      if (url.searchParams.has("source")) return null
      try {
        const saved = window.localStorage.getItem(storageKey)
        if (!saved || saved === textarea.value) return null
        return saved
      } catch (e) {
        return null
      }
    })()

    const submitForm = () => {
      const form = this.el.closest("form")
      if (form) form.requestSubmit()
      return true
    }

    const syncToTextarea = () => {
      const val = this.view.state.doc.toString()
      if (this.textarea.value !== val) {
        this.textarea.value = val
        // Trigger phx-change on the form
        this.textarea.dispatchEvent(new Event("input", {bubbles: true}))
      }
      if (storageKey) {
        try {
          window.localStorage.setItem(storageKey, val)
        } catch (e) {
          /* quota or private mode — ignore */
        }
      }
    }

    let lastLine = null
    const pushLine = (n) => {
      if (n == null) return
      if (n === lastLine) return
      lastLine = n
      this.pushEvent("hover-line", {line: String(n)})
    }

    const pushCursorLine = () => {
      const state = this.view.state
      const head = state.selection.main.head
      pushLine(state.doc.lineAt(head).number)
    }

    const pushHoverLine = (event) => {
      if (!this.view) return
      const pos = this.view.posAtCoords({x: event.clientX, y: event.clientY})
      if (pos == null) return
      pushLine(this.view.state.doc.lineAt(pos).number)
    }

    this.view = new EditorView({
      doc: textarea.value,
      parent: this.el,
      extensions: [
        lineNumbers(),
        highlightSpecialChars(),
        history(),
        drawSelection(),
        dropCursor(),
        EditorState.allowMultipleSelections.of(true),
        indentOnInput(),
        bracketMatching(),
        closeBrackets(),
        rectangularSelection(),
        crosshairCursor(),
        highlightActiveLine(),
        highlightSelectionMatches(),
        StreamLanguage.define(lua),
        syntaxHighlighting(defaultHighlightStyle, {fallback: true}),
        keymap.of([
          {key: "Mod-Enter", run: submitForm, preventDefault: true},
          ...closeBracketsKeymap,
          ...defaultKeymap,
          ...searchKeymap,
          ...historyKeymap,
          ...foldKeymap,
          indentWithTab,
        ]),
        EditorView.updateListener.of((update) => {
          if (update.docChanged) syncToTextarea()
          if (update.docChanged || update.selectionSet) pushCursorLine()
        }),
        editorTheme,
        themeCompartment.of(themeExt()),
      ],
    })

    // Restore from localStorage if applicable, before sync.
    if (restoreFromStorage) {
      this.view.dispatch({
        changes: {from: 0, to: this.view.state.doc.length, insert: restoreFromStorage},
      })
    }

    // Sync initial value (in case textarea had different value)
    syncToTextarea()

    // Push line on mouse hover so users can scrub the editor and watch
    // the bytecode panel light up without clicking. Throttled by line.
    this.view.scrollDOM.addEventListener("mousemove", pushHoverLine)
    this._hoverHandler = pushHoverLine

    // Listen for server-pushed source updates (e.g. when loading an example)
    this.handleEvent("lua-editor:set-source", ({source, target}) => {
      if (target && target !== this.el.id) return
      const current = this.view.state.doc.toString()
      if (current === source) return
      this.view.dispatch({
        changes: {from: 0, to: this.view.state.doc.length, insert: source},
      })
    })

    // Listen for server-pushed cursor focus (e.g. clicking a bytecode row)
    this.handleEvent("lua-editor:focus-line", ({line, target}) => {
      if (target && target !== this.el.id) return
      const lineNum = parseInt(line, 10)
      if (!Number.isFinite(lineNum)) return
      const doc = this.view.state.doc
      if (lineNum < 1 || lineNum > doc.lines) return
      const info = doc.line(lineNum)
      this.view.dispatch({
        selection: {anchor: info.from},
        effects: EditorView.scrollIntoView(info.from, {y: "center"}),
      })
      this.view.focus()
    })

    // Listen for theme changes on the <html> element so highlight updates live.
    this.themeObserver = new MutationObserver(() => {
      this.view.dispatch({effects: themeCompartment.reconfigure(themeExt())})
    })
    this.themeObserver.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-theme"],
    })
  },

  destroyed() {
    if (this.themeObserver) this.themeObserver.disconnect()
    if (this._hoverHandler && this.view) {
      this.view.scrollDOM.removeEventListener("mousemove", this._hoverHandler)
    }
    if (this.view) this.view.destroy()
  },
}

// Manages a multi-snippet code block rendered by
// `DemoWeb.CoreComponents.code_block/1`. The component renders every
// snippet server-side, stacked in a single grid cell so the container
// reserves the tallest snippet's height. This code picks a random
// initial snippet and wires the dot buttons below the block for
// manual switching — no auto-advance, no page jumps.
//
// Lives outside the LiveView hooks because the marketing pages are
// controller-rendered, not LiveViews.
function startCodeRotator(el) {
  if (el.__codeRotator) return
  const snippets = Array.from(el.querySelectorAll("[data-snippet-index]"))
  if (snippets.length < 2) return

  const filename = document.querySelector(
    `[data-code-filename-for="${el.id}"]`
  )
  const dotsContainer = document.querySelector(
    `[data-code-dots-for="${el.id}"]`
  )
  const dots = dotsContainer
    ? Array.from(dotsContainer.querySelectorAll("[data-snippet-target]"))
    : []

  const show = (idx) => {
    snippets.forEach((node, i) => {
      const active = i === idx
      node.classList.toggle("invisible", !active)
      node.setAttribute("aria-hidden", active ? "false" : "true")
    })
    dots.forEach((dot, i) => {
      if (i === idx) {
        dot.setAttribute("data-active", "")
      } else {
        dot.removeAttribute("data-active")
      }
    })
    if (filename) {
      const label = snippets[idx].dataset.label
      if (label) filename.textContent = label
    }
  }

  const initial = Math.floor(Math.random() * snippets.length)
  show(initial)

  const onClick = (event) => {
    const target = event.target.closest("[data-snippet-target]")
    if (!target || !dotsContainer.contains(target)) return
    const idx = parseInt(target.dataset.snippetTarget, 10)
    if (Number.isFinite(idx)) show(idx)
  }

  if (dotsContainer) dotsContainer.addEventListener("click", onClick)

  el.__codeRotator = {
    stop() {
      if (dotsContainer) dotsContainer.removeEventListener("click", onClick)
      el.__codeRotator = null
    },
  }
}

function initCodeRotators(root = document) {
  root.querySelectorAll("pre.highlight[data-rotate]").forEach(startCodeRotator)
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", () => initCodeRotators())
} else {
  initCodeRotators()
}
window.addEventListener("phx:page-loading-stop", () => initCodeRotators())

// Compresses a string with gzip and returns a URL-safe base64 string
// without padding. Used for `?source=` shareable playground links.
async function gzipBase64Url(text) {
  if (typeof CompressionStream === "undefined") {
    // Fallback for older browsers: raw base64 (no compression).
    return btoa(unescape(encodeURIComponent(text)))
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=+$/, "")
  }
  const bytes = new TextEncoder().encode(text)
  const stream = new Blob([bytes]).stream().pipeThrough(new CompressionStream("gzip"))
  const gzipped = new Uint8Array(await new Response(stream).arrayBuffer())
  let bin = ""
  for (let i = 0; i < gzipped.length; i++) bin += String.fromCharCode(gzipped[i])
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

const ShareSnippet = {
  mounted() {
    this.el.addEventListener("click", async (e) => {
      e.preventDefault()
      const textarea = document.getElementById("lua-source")
      if (!textarea) return
      const label = this.el.querySelector("[data-share-label]")
      const original = label ? label.textContent : null
      try {
        const encoded = await gzipBase64Url(textarea.value || "")
        const url = new URL(window.location.href)
        url.pathname = "/playground"
        url.search = "?source=" + encoded
        const shareUrl = url.toString()
        if (navigator.clipboard && window.isSecureContext) {
          await navigator.clipboard.writeText(shareUrl)
        } else {
          // Fallback: temporary textarea + execCommand
          const t = document.createElement("textarea")
          t.value = shareUrl
          t.style.position = "fixed"
          t.style.opacity = "0"
          document.body.appendChild(t)
          t.select()
          document.execCommand("copy")
          document.body.removeChild(t)
        }
        // Replace current URL silently so the share state survives reloads
        window.history.replaceState({}, "", shareUrl)
        if (label) {
          label.textContent = "Copied!"
          this.el.classList.add("text-success")
          setTimeout(() => {
            label.textContent = original
            this.el.classList.remove("text-success")
          }, 1600)
        }
      } catch (err) {
        console.error("Share failed:", err)
        if (label) label.textContent = "Failed"
      }
    })
  },
}

// Document-level copy handler. Works for both LiveView- and controller-
// rendered pages because it delegates on bubbling click events.
//
// Usage on any element:
//   <button data-copy="literal text">Copy</button>
//   <button data-copy-target="#some-element">Copy</button>
//
// Add a <span data-copy-label> child to get a transient "Copied!" label
// after a successful copy.
async function doCopy(el) {
  let text = el.dataset.copy
  if (!text && el.dataset.copyTarget) {
    const target = document.querySelector(el.dataset.copyTarget)
    if (target) text = target.innerText
  }
  if (!text) return
  const label = el.querySelector("[data-copy-label]")
  const original = label ? label.textContent : null
  try {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text)
    } else {
      const t = document.createElement("textarea")
      t.value = text
      t.style.position = "fixed"
      t.style.opacity = "0"
      document.body.appendChild(t)
      t.select()
      document.execCommand("copy")
      document.body.removeChild(t)
    }
    if (label) {
      label.textContent = "Copied!"
      el.classList.add("text-success")
      setTimeout(() => {
        label.textContent = original
        el.classList.remove("text-success")
      }, 1400)
    }
  } catch (err) {
    console.error("Copy failed:", err)
  }
}

document.addEventListener("click", (e) => {
  const btn = e.target.closest("[data-copy], [data-copy-target]")
  if (!btn) return
  e.preventDefault()
  doCopy(btn)
})

// LiveView hook stub — still useful when a button needs the LiveView
// lifecycle (e.g. to fire pushEvent after a successful copy).
const CopyButton = {
  mounted() {
    // No-op: the document-level handler above already wires clicks.
  },
}

const hooks = {...colocatedHooks, LuaEditor, ShareSnippet, CopyButton}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: hooks,
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
