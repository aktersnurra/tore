// The barcode scanner on Shop: the back camera, read a few times a second. Safari has no
// BarcodeDetector, so the ZXing ponyfill reads the frames, with its wasm served by Tore itself.
// A code is sent once while it stays in view; take it away and show it again to scan another pack.
import {BarcodeDetector, prepareZXingModule} from "barcode-detector/ponyfill"
import readerWasm from "zxing-wasm/reader/zxing_reader.wasm"

const FORMATS = ["ean_13", "ean_8", "upc_a"]
const EVERY_MS = 200
const GONE_MS = 1500

prepareZXingModule({
  overrides: {locateFile: (path, prefix) => (path.endsWith(".wasm") ? readerWasm : prefix + path)},
})

export default {
  async mounted() {
    this.video = this.el.querySelector("video")
    this.last = {code: null, at: 0}

    try {
      this.stream = await navigator.mediaDevices.getUserMedia({
        video: {facingMode: "environment"},
        audio: false,
      })
    } catch (error) {
      this.pushEvent("scanner_failed", {reason: error.name || "unavailable"})
      return
    }

    if (this.gone) return this.stop()
    this.video.srcObject = this.stream
    await this.video.play().catch(() => {})
    this.detector = new BarcodeDetector({formats: FORMATS})
    this.el.dataset.state = "live"
    this.timer = setInterval(() => this.read(), EVERY_MS)
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

  stop() {
    clearInterval(this.timer)
    this.stream?.getTracks().forEach((track) => track.stop())
  },

  destroyed() {
    this.gone = true
    this.stop()
  },
}
