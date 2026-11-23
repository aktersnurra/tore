// The barcode scanner on Shop: the back camera, read a few times a second, and opened again when
// it stops giving pictures (an iPhone's goes black when Safari is left and come back to). Safari has no
// BarcodeDetector, so the ZXing ponyfill reads the frames, with its wasm served by Tore itself.
// A code is sent once while it stays in view; take it away and show it again to scan another pack.
import {BarcodeDetector, prepareZXingModule} from "barcode-detector/ponyfill"
import readerWasm from "zxing-wasm/reader/zxing_reader.wasm"

const FORMATS = ["ean_13", "ean_8", "upc_a"]
const EVERY_MS = 200
const GONE_MS = 1500
// A camera that gives no new picture for this long is opened again, this many times in a row.
const STALLED_MS = 2500
const RESTARTS = 3
// Still starting after this long (Safari never answered, or the video never began): said to
// Tore once, with what the camera and video are doing, so the log shows where it stuck.
const STUCK_MS = 10000

prepareZXingModule({
  overrides: {locateFile: (path, prefix) => (path.endsWith(".wasm") ? readerWasm : prefix + path)},
})

export default {
  mounted() {
    this.video = this.el.querySelector("video")
    this.last = {code: null, at: 0}
    this.restarts = 0
    // iOS shows a camera only in a video that is muted and inline, and goes by the properties:
    // the attributes of a video LiveView put in the page don't always set them.
    this.video.muted = true
    this.video.playsInline = true
    this.video.autoplay = true
    // Where a video may only start from a tap, a tap on the view starts it.
    this.el.addEventListener("click", () => this.video.play().catch(() => {}))
    this.detector = new BarcodeDetector({formats: FORMATS})
    this.timer = setInterval(() => this.tick(), EVERY_MS)
    this.start()
  },

  // Opens the camera, again if it was open: iOS ends or blanks a camera when Safari is left, the
  // phone locks or another app takes it, and gives a working one only when asked anew.
  async start() {
    if (this.starting || this.gone) return
    this.starting = true
    this.step = "asking"
    this.startedAt = Date.now()
    this.el.dataset.state = "starting"
    this.release()

    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        video: {facingMode: {ideal: "environment"}, width: {ideal: 1280}, height: {ideal: 720}},
        audio: false,
      })
      if (this.gone) return stream.getTracks().forEach((track) => track.stop())
      this.stream = stream
      this.video.srcObject = stream
      this.seen = Date.now()
      this.frame = -1
      this.step = "playing"
      // Not waited on: on an iPhone play() can stay pending for good, and then nothing would
      // ever watch for pictures. tick() does. Refused where a video needs a tap first: the view
      // says so, and the tap starts it.
      this.video.play().catch(() => { this.el.dataset.state = "paused" })
    } catch (error) {
      this.fail(error.name || "unavailable")
    } finally {
      this.starting = false
    }
  },

  // Every tick: is the camera still giving pictures? Then read one. A camera that has given
  // none for a while is opened again, a few times before giving up.
  tick() {
    const now = Date.now()
    if (this.starting) return this.stuck(now)
    if (!this.stream) return
    if (document.visibilityState !== "visible") return (this.seen = now)

    const [track] = this.stream.getVideoTracks()
    const live = track && track.readyState === "live" && !track.muted
    if (live && this.video.videoWidth > 0 && this.video.currentTime !== this.frame) {
      this.frame = this.video.currentTime
      this.seen = now
      this.restarts = 0
      this.el.dataset.state = "live"
      return this.read()
    }

    if (now - this.seen < STALLED_MS) return
    // Waiting for a tap, with a camera that's fine.
    if (live && this.video.paused) return (this.el.dataset.state = "paused")
    if (this.restarts >= RESTARTS) return this.fail("stalled", this.detail())
    this.restarts += 1
    this.start()
  },

  async read() {
    if (this.reading || this.video.readyState < 2) return
    this.reading = true

    try {
      const [found] = await this.detector.detect(this.video)
      const now = Date.now()

      if (found) {
        const again = found.rawValue === this.last.code && now - this.last.at < GONE_MS
        this.last = {code: found.rawValue, at: now}

        if (!again) {
          this.pushEvent("scanned", {code: found.rawValue})
          this.el.classList.remove("caught")
          void this.el.offsetWidth
          this.el.classList.add("caught")
        }
      }
    } catch (_error) {
      // A frame that can't be read is skipped; the next one is tried.
    } finally {
      this.reading = false
    }
  },

  stuck(now) {
    if (this.toldStuck || now - this.startedAt < STUCK_MS) return
    this.toldStuck = true
    this.pushEvent("scanner_stuck", {detail: this.detail()})
  },

  // What the camera and the video are doing, for the log.
  detail() {
    const [track] = this.stream?.getVideoTracks() || []
    const v = this.video
    return `${this.step}; track ${track ? `${track.readyState}${track.muted ? " muted" : ""}` : "none"}; ` +
      `video ${v.videoWidth}x${v.videoHeight} ready ${v.readyState}${v.paused ? " paused" : ""} t ${v.currentTime.toFixed(1)}; ` +
      `${document.visibilityState}; ${navigator.userAgent}`
  },

  fail(reason, detail = this.detail()) {
    clearInterval(this.timer)
    this.release()
    if (!this.gone) this.pushEvent("scanner_failed", {reason, detail})
  },

  release() {
    this.stream?.getTracks().forEach((track) => track.stop())
    this.stream = null
    this.video.srcObject = null
  },

  destroyed() {
    this.gone = true
    clearInterval(this.timer)
    this.release()
  },
}
