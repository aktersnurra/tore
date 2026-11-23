// Swipe a row left to take it off (Shop: removed; Hemma: Slut). The row's [data-swipe-body]
// follows the finger over its [data-swipe-label]; let go past a third of the row and it slides
// out and pushes data-swipe-event with data-id, otherwise it springs back. A drag that starts
// up or down is the page scrolling, and is left alone.
const DECIDE = 10
const reduced = window.matchMedia("(prefers-reduced-motion: reduce)")

const Swipe = {
  mounted() {
    let x0 = 0, y0 = 0, dx = 0, mode = null
    const body = () => this.el.querySelector("[data-swipe-body]")
    const label = () => this.el.querySelector("[data-swipe-label]")

    const move = (offset, animate) => {
      const el = body()
      if (!el) return
      el.style.transition = animate && !reduced.matches
        ? "transform var(--dur-base) var(--ease-out)"
        : "none"
      el.style.transform = offset ? `translateX(${offset}px)` : ""
      const l = label()
      if (l) l.style.opacity = Math.min(1, -offset / (this.el.offsetWidth / 3))
    }

    this.el.addEventListener("touchstart", (e) => {
      if (e.touches.length !== 1) return
      x0 = e.touches[0].clientX
      y0 = e.touches[0].clientY
      dx = 0
      mode = null
    }, {passive: true})

    this.el.addEventListener("touchmove", (e) => {
      const tx = e.touches[0].clientX - x0, ty = e.touches[0].clientY - y0
      if (!mode && Math.max(Math.abs(tx), Math.abs(ty)) > DECIDE)
        mode = Math.abs(tx) > Math.abs(ty) * 1.5 && tx < 0 ? "swipe" : "scroll"
      if (mode !== "swipe") return
      e.preventDefault()
      dx = Math.min(0, tx)
      move(dx, false)
    }, {passive: false})

    const end = () => {
      if (mode !== "swipe") return
      mode = null
      if (-dx > this.el.offsetWidth / 3) {
        move(-this.el.offsetWidth, true)
        this.pushEvent(this.el.dataset.swipeEvent, {id: this.el.dataset.id})
      } else {
        move(0, true)
      }
    }
    this.el.addEventListener("touchend", end)
    this.el.addEventListener("touchcancel", () => { mode = null; move(0, true) })
  },

  // The row came back (Ångra, or the server kept it): it sits where it belongs.
  updated() {
    const el = this.el.querySelector("[data-swipe-body]")
    if (el) { el.style.transform = ""; el.style.transition = "none" }
    const l = this.el.querySelector("[data-swipe-label]")
    if (l) l.style.opacity = 0
  },
}

export default Swipe
