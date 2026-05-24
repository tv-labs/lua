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

const LuaEditor = {
  mounted() {
    const ta = this.el.querySelector("textarea")
    if (!ta) return

    ta.addEventListener("keydown", (e) => {
      // Cmd/Ctrl + Enter -> submit form
      if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
        e.preventDefault()
        const form = ta.closest("form")
        if (form) form.requestSubmit()
        return
      }

      // Tab / Shift+Tab indentation
      if (e.key === "Tab") {
        e.preventDefault()
        const start = ta.selectionStart
        const end = ta.selectionEnd
        const before = ta.value.slice(0, start)
        const sel = ta.value.slice(start, end)
        const after = ta.value.slice(end)

        if (e.shiftKey) {
          // De-indent each line in selection by removing up to 2 leading spaces
          const lineStart = before.lastIndexOf("\n") + 1
          const block = ta.value.slice(lineStart, end)
          const dedented = block.replace(/^(  ?)/gm, "")
          const newVal = ta.value.slice(0, lineStart) + dedented + after
          ta.value = newVal
          const delta = block.length - dedented.length
          ta.selectionStart = Math.max(lineStart, start - 2)
          ta.selectionEnd = Math.max(lineStart, end - delta)
        } else if (sel.includes("\n")) {
          // Indent each line of multi-line selection
          const lineStart = before.lastIndexOf("\n") + 1
          const block = ta.value.slice(lineStart, end)
          const indented = block.replace(/^/gm, "  ")
          ta.value = ta.value.slice(0, lineStart) + indented + after
          const delta = indented.length - block.length
          ta.selectionStart = start + 2
          ta.selectionEnd = end + delta
        } else {
          // Single position: insert two spaces
          ta.value = before + "  " + after
          ta.selectionStart = ta.selectionEnd = start + 2
        }
        ta.dispatchEvent(new Event("input", {bubbles: true}))
        return
      }
    })
  }
}

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

