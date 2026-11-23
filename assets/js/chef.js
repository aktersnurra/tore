// The chef (ToreWeb.Chef): a tap makes it hop and, where it has lines, say one. On Today's row it
// moves up once on this phone when its stage has grown since it was last seen here; what it saw
// last is a per-phone convenience in localStorage, so a cleared one just skips the moment.
// A drawn (Lottie) chef takes over the figure and keeps these: data-stage, the taps, the move up.
const SEEN = "tore.chef.stage"
const SAID_MS = 2200
const UP_MS = 5000

export default {
  mounted() {
    this.lines = JSON.parse(this.el.dataset.lines || "[]")
    this.said = null
    this.el.addEventListener("click", () => this.hop())
    if (this.el.id === "chef-small") this.moveUp()
  },

  hop() {
    this.replay("chef-hop")
    if (this.lines.length === 0) return
    const choices = this.lines.filter((line) => line !== this.said)
    this.said = choices[Math.floor(Math.random() * choices.length)]
    const bubble = this.el.querySelector("[data-chef-line]")
    bubble.textContent = this.said
    bubble.classList.add("is-shown")
    clearTimeout(this.saying)
    this.saying = setTimeout(() => bubble.classList.remove("is-shown"), SAID_MS)
  },

  moveUp() {
    const stage = Number(this.el.dataset.stageIndex)
    let seen = null
    try {
      seen = localStorage.getItem(SEEN)
      localStorage.setItem(SEEN, String(stage))
    } catch (_error) {
      return
    }
    if (seen === null || Number(seen) >= stage) return

    this.replay("chef-up")
    const said = this.el.closest("section")?.querySelector("[data-chef-up]")
    if (!said) return
    this.js().removeAttribute(said, "hidden")
    setTimeout(() => this.js().setAttribute(said, "hidden", ""), UP_MS)
  },

  // Restarts a one-off animation class, even when it's already on.
  replay(name) {
    this.el.classList.remove(name)
    void this.el.offsetWidth
    this.el.classList.add(name)
  },

  destroyed() {
    clearTimeout(this.saying)
  },
}
