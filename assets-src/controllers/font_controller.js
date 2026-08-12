// Per-user override of the UI typeface, on top of the host's configured
// default.
//
// The layout stamps `data-font` on <html> from Flightdeck.config.ui_font, so
// the dashboard is already in the right face before any JavaScript runs; this
// controller only replaces that stamp with a remembered choice and writes new
// ones. Every rule reads --font-ui, and the @font-face rules for all faces are
// in the stylesheet already, so switching is one attribute write — the new
// face renders as soon as its woff2 arrives, and the browser never downloads a
// face nobody picked.
class FontController extends Stimulus.Controller {
  static targets = ["select"]
  static values = { storageKey: { type: String, default: "flightdeck:font" } }

  connect() {
    const stored = this.read()
    // An unknown slug means the choice was made by an older version that
    // offered a face this one dropped; fall back to what the host configured.
    if (stored && this.known(stored)) this.apply(stored)

    this.sync()
  }

  change(event) {
    const slug = event.target.value
    if (!this.known(slug)) return

    this.apply(slug)
    this.write(slug)
  }

  apply(slug) {
    document.documentElement.setAttribute("data-font", slug)
  }

  // Keeps the menu showing what is actually on screen, including after a Turbo
  // visit replaces the topbar with server-rendered markup carrying the host
  // default.
  sync() {
    if (!this.hasSelectTarget) return

    const current = document.documentElement.getAttribute("data-font")
    if (current) this.selectTarget.value = current
  }

  known(slug) {
    if (!this.hasSelectTarget) return false

    return Array.from(this.selectTarget.options).some((option) => option.value === slug)
  }

  read() {
    try {
      return window.localStorage.getItem(this.storageKeyValue)
    } catch (error) {
      return null
    }
  }

  write(value) {
    try {
      window.localStorage.setItem(this.storageKeyValue, value)
    } catch (error) {
      // Private mode / disabled storage: the choice still holds for this page.
    }
  }
}
