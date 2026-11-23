// The chef (ToreWeb.Chef): one of pi's scene drawings (priv/static/images/chef/<scene>.svg), put in
// its own shadow root so its styles and ids stay apart from the page's. The drawing breathes,
// blinks and moves its stage's prop by itself (`.idle`); a tap plays its hop (`.tapped`) and,
// where it has lines, it says one. On Today's row it cheers (`.cheer`) once on this phone when its
// stage has grown since it was last seen here; what was seen is a per-phone convenience in
// localStorage, so a cleared one just skips the moment. Reduced motion is the drawing's own.
//
// `data-sleep` (Today at night, by the household's clock) has him asleep until a tap wakes him with
// a yawn. Awake and on screen, he glances around now and then. `data-mood` asks for one reaction
// when he's put in (`proud` on the cooked card, `pleased` at the desk), and `data-stir` has him
// stirring a pot while Tore answers. The page can ask for a reaction too: the `chef:react` event
// (`drop` into the cart for a tick on Shop).
const SEEN = "tore.chef.stage"
const SAID_MS = 2200
const UP_MS = 5000
const REACTIONS = {tapped: 600, cheer: 1200, look: 1600, wake: 1200, proud: 900, drop: 900, pleased: 900}
// A glance around, every so often while awake: between these, at random.
const GLANCE_MS = [9000, 20000]
// What drops into the cart, in turn, so ticks in a row don't look the same.
const DROPS = ["apple", "carton", "loaf"]

// One fetch of each drawing for the page, however often it's put in.
const drawings = new Map()
const load = (src) => {
  if (!drawings.has(src))
    drawings.set(
      src,
      fetch(src).then((response) =>
        response.ok ? response.text() : Promise.reject(new Error(`chef: ${response.status}`)),
      ),
    )
  return drawings.get(src)
}

export default {
  mounted() {
    this.lines = JSON.parse(this.el.dataset.lines || "[]")
    this.said = null
    this.el.addEventListener("click", () => this.tapped())

    this.root = this.el.querySelector("[data-chef-art]").attachShadow({mode: "open"})
    this.asleep = "sleep" in this.el.dataset
    this.drops = 0
    this.handleEvent("chef:react", ({name}) => {
      if (name === "drop" && this.svg) this.svg.dataset.item = DROPS[this.drops++ % DROPS.length]
      this.react(name)
    })
    this.put().then(() => {
      if (this.el.dataset.mood) this.react(this.el.dataset.mood)
      if (this.el.id === "chef-small") this.moveUp()
      this.glance()
    })
  },

  // Puts in the scene's drawing, as he is now: his stage, and asleep or stirring.
  put() {
    this.src = this.el.dataset.src
    return load(this.src).then((svg) => {
      this.root.innerHTML =
        "<style>:host{display:block;width:100%;height:100%}svg{display:block;width:100%;height:100%}</style>" +
        svg
      this.svg = this.root.querySelector("svg")
      this.svg.setAttribute("aria-hidden", "true")
      this.svg.classList.add("idle")
      const stir = "stir" in this.el.dataset
      this.svg.classList.toggle("stir", stir)
      this.svg.classList.toggle("sleep", this.asleep && !stir)
      this.stage()
    })
  },

  // Starting or stopping a stir can change the drawing (the stove, cart or desk to the pot).
  updated() {
    if (this.el.dataset.src !== this.src) return this.put()
    this.stage()
    const stir = "stir" in this.el.dataset
    this.svg?.classList.toggle("stir", stir)
    this.svg?.classList.toggle("sleep", this.asleep && !stir)
  },

  // Now and then, while awake and on screen, he looks around.
  glance() {
    const [least, most] = GLANCE_MS
    this.glancing = setTimeout(() => {
      if (
        this.svg &&
        !this.asleep &&
        !this.svg.classList.contains("stir") &&
        document.visibilityState === "visible"
      )
        this.react("look", {quiet: true})
      this.glance()
    }, least + Math.random() * (most - least))
  },

  stage() {
    if (this.svg) this.svg.dataset.stage = String(Number(this.el.dataset.stageIndex) + 1)
  },

  tapped() {
    if (this.asleep) {
      this.asleep = false
      this.svg?.classList.remove("sleep")
      this.react("wake")
      return this.say(this.el.dataset.wakeLine)
    }

    this.react("tapped")
    if (this.lines.length === 0) return
    const choices = this.lines.filter((line) => line !== this.said)
    this.said = choices[Math.floor(Math.random() * choices.length)]
    this.say(this.said)
  },

  say(line) {
    if (!line) return
    const bubble = this.el.querySelector("[data-chef-line]")
    bubble.textContent = line
    bubble.classList.add("is-shown")
    clearTimeout(this.saying)
    this.saying = setTimeout(() => bubble.classList.remove("is-shown"), SAID_MS)
  },

  // One reaction at a time: the last one ends, and the new one plays from its start. A quiet one
  // (a glance) doesn't cut into another that's playing.
  react(name, {quiet} = {quiet: false}) {
    if (!this.svg) return
    if (quiet && Object.keys(REACTIONS).some((r) => this.svg.classList.contains(r))) return
    clearTimeout(this.reacting)
    this.svg.classList.remove(...Object.keys(REACTIONS))
    void this.svg.getBoundingClientRect()
    this.svg.classList.add(name)
    this.reacting = setTimeout(() => this.svg.classList.remove(name), REACTIONS[name])
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

    this.react("cheer")
    const said = this.el.closest("section")?.querySelector("[data-chef-up]")
    if (!said) return
    this.js().removeAttribute(said, "hidden")
    setTimeout(() => this.js().setAttribute(said, "hidden", ""), UP_MS)
  },

  destroyed() {
    clearTimeout(this.saying)
    clearTimeout(this.reacting)
    clearTimeout(this.glancing)
  },
}
