# frozen_string_literal: true

require "rake/testtask"
require "digest"
require "json"
require "base64"
require "fileutils"
require "tmpdir"

ROOT = File.expand_path(__dir__)
SRC = File.join(ROOT, "assets-src")
OUT = File.join(ROOT, "app", "assets", "flightdeck")
MANIFEST = File.join(OUT, "manifest.json")

LOGICAL = {
  "flightdeck.css" => "text/css; charset=utf-8",
  "flightdeck.js" => "text/javascript; charset=utf-8"
}.freeze

Dir[File.join(__dir__, "tasks", "*.rake")].sort.each { |task| load task }

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  # System tests are a separate task: they need a browser and are far slower.
  t.test_files = FileList["test/**/*_test.rb"].exclude("test/system/**/*")
  t.warning = false
  t.verbose = false
end

namespace :test do
  desc "Set up the environment system tests need, before the app boots"
  task :system_env do
    # A browser cannot dismiss an HTTP Basic dialog, so system tests run against
    # a host that supplies its own base controller. This must be in the
    # environment before Zeitwerk loads the engine's controllers.
    ENV["FLIGHTDECK_TEST_BASE_CONTROLLER"] ||= "OpenBaseController"
  end

  desc "Run browser system tests (headless Chrome; skipped when none is installed)"
  Rake::TestTask.new(system: :system_env) do |t|
    t.libs << "test"
    t.libs << "lib"
    t.test_files = FileList["test/system/**/*_test.rb"]
    t.warning = false
    t.verbose = false
  end
end

task default: %i[test]

namespace :assets do
  desc "Build flightdeck.css + flightdeck.js + the fonts, and the digested manifest"
  task :build do
    FileUtils.mkdir_p(OUT)

    # Fonts first: the stylesheet's @font-face rules point at their digested
    # filenames, so those have to exist before the CSS is hashed.
    fonts = build_fonts

    css = build_css(fonts)
    js = build_js

    manifest = {}
    { "flightdeck.css" => css, "flightdeck.js" => js }.each do |logical, content|
      digest = Digest::SHA256.hexdigest(content)
      short = digest[0, 12]
      file = logical.sub(/\Aflightdeck/, "flightdeck-#{short}")

      File.binwrite(File.join(OUT, file), content)
      manifest[logical] = {
        "file" => file,
        "digest" => short,
        "sha256" => digest,
        "content_type" => LOGICAL.fetch(logical),
        "size" => content.bytesize
      }
    end

    manifest.merge!(fonts)

    File.write(MANIFEST, JSON.pretty_generate(manifest) + "\n")
    prune_stale(manifest)

    manifest.each { |logical, entry| puts "#{logical} -> #{entry["file"]} (#{entry["size"]} bytes)" }
  end

  desc "Fail if the committed assets do not match assets-src (run before release)"
  task :check do
    unless File.file?(MANIFEST)
      abort "app/assets/flightdeck/manifest.json is missing. Run `rake assets:build`."
    end

    manifest = JSON.parse(File.read(MANIFEST))
    problems = []

    manifest.each do |logical, entry|
      path = File.join(OUT, entry["file"])
      if !File.file?(path)
        problems << "#{logical}: #{entry["file"]} is missing"
        next
      end

      actual = Digest::SHA256.hexdigest(File.binread(path))
      if actual != entry["sha256"]
        problems << "#{logical}: #{entry["file"]} contents do not match the manifest digest"
      end
      if entry["digest"] != actual[0, 12]
        problems << "#{logical}: digested filename does not match its contents"
      end
    end

    LOGICAL.each_key do |logical|
      problems << "#{logical}: not present in the manifest" unless manifest.key?(logical)
    end

    # A face vendored but never built would silently fall back to system-ui in
    # the browser, which is easy to miss by eye.
    vendored = JSON.parse(File.read(File.join(SRC, "fonts", "fonts.json"))).keys
    (vendored - manifest.keys).each do |logical|
      problems << "#{logical}: vendored in assets-src/fonts but not in the manifest"
    end

    abort "Stale assets:\n  " + problems.join("\n  ") if problems.any?

    puts "assets are fresh (#{manifest.keys.size} entries: #{LOGICAL.keys.join(", ")} + #{vendored.size} fonts)"
  end
end

desc "Alias for assets:build"
task assets: "assets:build"

def build_css(fonts)
  require "tailwindcss/ruby"

  input = File.join(SRC, "input.css")
  tmp = File.join(Dir.tmpdir, "flightdeck-#{Process.pid}.css")

  command = [ Tailwindcss::Ruby.executable, "--input", input, "--output", tmp, "--minify" ]
  Dir.chdir(ROOT) do
    system(*command, exception: true)
  end

  css = File.read(tmp)
  FileUtils.rm_f(tmp)

  font_face_css(fonts) + css
end

# Copies every vendored woff2 into the output directory under a digested name
# and returns its manifest fragment. Fonts are served as ordinary assets rather
# than inlined as data: URIs: a browser then downloads only the family the user
# actually reads the dashboard in, instead of all of them on first paint.
def build_fonts
  index_path = File.join(SRC, "fonts", "fonts.json")
  return {} unless File.file?(index_path)

  JSON.parse(File.read(index_path)).each_with_object({}) do |(logical, _meta), manifest|
    content = File.binread(File.join(SRC, "fonts", logical))
    digest = Digest::SHA256.hexdigest(content)
    short = digest[0, 12]
    file = "flightdeck-#{File.basename(logical, ".woff2")}-#{short}.woff2"

    File.binwrite(File.join(OUT, file), content)
    manifest[logical] = {
      "file" => file,
      "digest" => short,
      "sha256" => digest,
      "content_type" => "font/woff2",
      "size" => content.bytesize
    }
  end
end

# The url() is relative, so it resolves against the stylesheet's own URL and
# stays correct wherever the engine is mounted.
def font_face_css(fonts)
  index_path = File.join(SRC, "fonts", "fonts.json")
  return "" unless File.file?(index_path)

  JSON.parse(File.read(index_path)).map do |logical, meta|
    file = fonts.fetch(logical).fetch("file")

    "@font-face{font-family:'#{meta["family"]}';font-style:normal;" \
      "font-weight:#{meta["weight"]};font-display:swap;" \
      "src:url(#{file}) format('woff2')}"
  end.join + "\n"
end

def build_js
  parts = []
  parts << File.read(File.join(SRC, "vendor", "turbo.min.js"))
  parts << File.read(File.join(SRC, "vendor", "stimulus.umd.min.js"))

  Dir[File.join(SRC, "controllers", "*.js")].sort.each { |path| parts << File.read(path) }

  boot = File.read(File.join(SRC, "boot.js"))
  boot = boot.sub("__FLIGHTDECK_VERSION__", flightdeck_version)
  parts << boot

  banner = "/* Flightdeck #{flightdeck_version} — bundled @hotwired/turbo + @hotwired/stimulus. " \
           "Generated by `rake assets:build`; do not edit. */\n"

  banner + "(function(){\n" + parts.join("\n;\n") + "\n})();\n"
end

def flightdeck_version
  @flightdeck_version ||= begin
    require File.join(ROOT, "lib", "flightdeck", "version")
    Flightdeck::VERSION
  end
end

def prune_stale(manifest)
  keep = manifest.values.map { |entry| entry["file"] } + [ "manifest.json" ]
  Dir[File.join(OUT, "flightdeck-*.{css,js,woff2}")].each do |path|
    FileUtils.rm_f(path) unless keep.include?(File.basename(path))
  end
end
