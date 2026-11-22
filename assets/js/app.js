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
import {hooks as colocatedHooks} from "phoenix-colocated/tore"
import LongPress from "./long_press"
import Scanner from "./scanner"

import topbar from "../vendor/topbar"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
// A confirmation says its piece and leaves; an error stays until it's dismissed.
const AutoDismiss = {
  mounted() { this.timer = setTimeout(() => this.el.click(), 3500) },
  destroyed() { clearTimeout(this.timer) },
}

// A page change (navigate or patch), or a `tore:transition` event, patches the page inside a view
// transition: a short cross-fade, and a dish's photograph travels to where it lands (its
// `view-transition-name` is the same on both sides). Other patches apply as they come.
let transitionNext = false
const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)")
window.addEventListener("phx:page-loading-start", e => {
  if (e.detail.kind === "redirect" || e.detail.kind === "patch") transitionNext = true
})
window.addEventListener("tore:transition", () => { transitionNext = true })
// Only the dish you tap travels; naming every photo would lift them all above the page.
document.addEventListener("click", e => {
  const card = e.target.closest("[data-dish]")
  card?.querySelector("img")?.style.setProperty("view-transition-name", `dish-${card.dataset.dish}`)
}, true)

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {LongPress, AutoDismiss, Scanner, ...colocatedHooks},
  dom: {
    onDocumentPatch(start) {
      if (!transitionNext || !document.startViewTransition || reducedMotion.matches) return start()
      transitionNext = false
      document.startViewTransition(start)
    },
  },
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#75726D"}, shadowColor: "rgba(0, 0, 0, 0)", barThickness: 2})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

window.addEventListener("phx:reset_form", ({detail: {id}}) => {
  document.getElementById(id)?.reset()
})

// connect if there are any LiveViews on the page
// Tore is an app, not a page: no pinch zoom, which iOS Safari allows despite user-scalable=no.
document.addEventListener("gesturestart", e => e.preventDefault())

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

