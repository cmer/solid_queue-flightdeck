# frozen_string_literal: true

require "test_helper"

class Flightdeck::AssetsTest < ActionDispatch::IntegrationTest
  VENDORED_FONTS = Pathname.new(File.expand_path("../../assets-src/fonts/fonts.json", __dir__))

  test "serves a digested stylesheet as an immutable asset" do
    name = Flightdeck::Assets.digested_name("flightdeck.css")
    get "/flightdeck/assets/#{name}"

    assert_response :success
    assert_equal "text/css", response.media_type
    assert_equal %w[immutable max-age=31536000 public], response.headers["Cache-Control"].split(", ").sort
    assert_equal %("#{name[/flightdeck-([0-9a-f]{12})/, 1]}"), response.headers["ETag"]
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert_includes response.body, ".fd-app"
  end

  test "serves a digested script as an immutable asset" do
    name = Flightdeck::Assets.digested_name("flightdeck.js")
    get "/flightdeck/assets/#{name}"

    assert_response :success
    assert_equal "text/javascript", response.media_type
    assert_equal %w[immutable max-age=31536000 public], response.headers["Cache-Control"].split(", ").sort
    assert_includes response.body, "Stimulus"
  end

  test "returns 304 when the client already has the digest" do
    name = Flightdeck::Assets.digested_name("flightdeck.css")
    get "/flightdeck/assets/#{name}"
    etag = response.headers["ETag"]

    get "/flightdeck/assets/#{name}", headers: { "HTTP_IF_NONE_MATCH" => etag }

    assert_response :not_modified
  end

  test "a well-formed but unknown digest is not served" do
    get "/flightdeck/assets/flightdeck-000000000000.css"

    assert_response :not_found
  end

  test "names that are not digested asset names do not route" do
    [
      "flightdeck.css",
      "../../../etc/passwd",
      "flightdeck-6f7ad8f56f16.css/../../secret",
      "flightdeck-zzzzzzzzzzzz.css",
      "flightdeck-6f7ad8f56f16.rb"
    ].each do |name|
      get "/flightdeck/assets/#{name}"
      assert_response :not_found, "expected #{name.inspect} to 404"
    end
  end

  test "the committed manifest matches the committed files" do
    manifest = JSON.parse(Flightdeck::Assets.root.join("manifest.json").read)

    assert_includes manifest.keys, "flightdeck.css"
    assert_includes manifest.keys, "flightdeck.js"

    manifest.each do |logical, entry|
      path = Flightdeck::Assets.root.join(entry["file"])
      assert path.file?, "#{entry["file"]} for #{logical} is missing — run `rake assets:build`"

      contents = path.binread
      sha = Digest::SHA256.hexdigest(contents)

      assert_equal entry["sha256"], sha, "#{logical} contents do not match the manifest digest"
      assert_equal entry["digest"], sha[0, 12], "#{logical} digested filename is stale"
      assert_equal entry["size"], contents.bytesize
      assert_includes entry["file"], sha[0, 12]
    end
  end

  test "the stylesheet serves the vendored fonts itself rather than fetching them" do
    css = Flightdeck::Assets.read(Flightdeck::Assets.digested_name("flightdeck.css"))
    vendored = JSON.parse(VENDORED_FONTS.read)

    assert_equal vendored.size, css.scan("@font-face").size
    refute_includes css, "fonts.gstatic.com"
    refute_includes css, "fontshare.com"
  end

  # Every face inlined as a data: URI would put all of them on the wire on
  # first paint, for the one the reader actually sees.
  test "font files are separate assets, not inlined in the stylesheet" do
    css = Flightdeck::Assets.read(Flightdeck::Assets.digested_name("flightdeck.css"))

    refute_includes css, "data:font/woff2;base64,"
    assert_operator css.bytesize, :<, 60.kilobytes
  end

  test "the @font-face urls are relative, so they resolve under any mount path" do
    css = Flightdeck::Assets.read(Flightdeck::Assets.digested_name("flightdeck.css"))
    urls = css.scan(/src:url\(([^)]+)\)/).flatten

    assert_predicate urls, :any?
    urls.each do |url|
      refute_match %r{\A(?:/|https?:)}, url, "#{url} is absolute and would break under a nested mount"
      assert Flightdeck::Assets.find(url), "#{url} is not a manifest asset"
    end
  end

  test "serves a digested font as an immutable asset" do
    name = Flightdeck::Assets.digested_name("barlow-400.woff2")
    get "/flightdeck/assets/#{name}"

    assert_response :success
    assert_equal "font/woff2", response.headers["Content-Type"]
    assert_equal %w[immutable max-age=31536000 public], response.headers["Cache-Control"].split(", ").sort
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert_equal "wOF2", response.body.byteslice(0, 4)
  end

  test "every vendored font is reachable" do
    JSON.parse(VENDORED_FONTS.read).each_key do |logical|
      name = Flightdeck::Assets.digested_name(logical)
      assert name, "#{logical} is missing from the manifest — run `rake assets:build`"

      get "/flightdeck/assets/#{name}"
      assert_response :success, "#{logical} did not serve"
    end
  end
end
