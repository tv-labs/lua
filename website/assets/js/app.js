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

const LuaEditor = {
  mounted() {
    const textarea = this.el.querySelector("textarea")
    if (!textarea) return

    this.textarea = textarea
    // Hide the underlying textarea but keep it in the form.
    textarea.style.display = "none"
    textarea.setAttribute("tabindex", "-1")
    textarea.setAttribute("aria-hidden", "true")

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
        }),
        editorTheme,
        themeCompartment.of(themeExt()),
      ],
    })

    // Sync initial value (in case textarea had different value)
    syncToTextarea()

    // Listen for server-pushed source updates (e.g. when loading an example)
    this.handleEvent("lua-editor:set-source", ({source, target}) => {
      if (target && target !== this.el.id) return
      const current = this.view.state.doc.toString()
      if (current === source) return
      this.view.dispatch({
        changes: {from: 0, to: this.view.state.doc.length, insert: source},
      })
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

const hooks = {...colocatedHooks, LuaEditor}

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
