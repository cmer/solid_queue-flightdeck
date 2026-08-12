// Boot: appended last in the concatenated bundle, so Turbo and Stimulus (and
// our controller classes) are already defined in this IIFE's scope.
;(function () {
  if (window.__flightdeckBooted) return
  window.__flightdeckBooted = true

  var application = Stimulus.Application.start()
  application.register("clock", ClockController)
  application.register("font", FontController)
  application.register("live", LiveController)
  application.register("refresh", RefreshController)
  application.register("selection", SelectionController)
  application.register("theme", ThemeController)
  application.register("toast", ToastController)

  window.Flightdeck = { application: application, version: "__FLIGHTDECK_VERSION__" }
})()
