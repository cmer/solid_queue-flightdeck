# frozen_string_literal: true

# One-off vendoring script. Downloads the woff2 files for every typeface
# Flightdeck can render in and writes them next to this file, so that
# `rake assets:build` never needs network access.
#
#   ruby assets-src/fonts/fetch_fonts.rb
#
# Two sources, because General Sans is not on Google Fonts:
#
#   Google Fonts  — latin-subset files, picked out of the css2 API response.
#                   Some families are served as static instances (one file per
#                   weight), others as a single variable file covering a range;
#                   both are handled, and a variable file is written once.
#   Fontshare     — the whole face, no subsetting API. Larger files, but they
#                   are only downloaded by a browser when the user picks that
#                   font, so they cost nothing by default.
#
# The @font-face rules themselves are generated at build time (see the
# Rakefile) and point at the digested copies the manifest serves.

require "net/http"
require "uri"
require "json"
require "fileutils"

CHROME_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " \
            "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

GOOGLE_FAMILIES = {
  "Barlow" => [ 400, 500, 600 ],
  "IBM Plex Mono" => [ 400, 500 ],
  "Inter" => [ 400, 500, 600 ],
  "Public Sans" => [ 400, 500, 600 ],
  "Manrope" => [ 400, 500, 600 ]
}.freeze

FONTSHARE_FAMILIES = {
  "General Sans" => [ 400, 500, 600 ]
}.freeze

# The Google Fonts latin subset is always the block whose unicode-range starts
# at U+0000-00FF.
LATIN_MARKER = "U+0000-00FF"

def get(url)
  url = "https:#{url}" if url.start_with?("//")
  response = Net::HTTP.get_response(URI(url), "User-Agent" => CHROME_UA)
  raise "GET #{url} -> #{response.code}" unless response.is_a?(Net::HTTPSuccess)

  response.body
end

def slug(family, weight)
  "#{family.downcase.tr(" ", "-")}-#{weight.to_s.tr(" ", "-")}.woff2"
end

def write(dir, name, url, index, entry)
  bytes = get(url)
  File.binwrite(File.join(dir, name), bytes)
  index[name] = entry.merge("source" => url)
  puts "wrote #{name} (#{bytes.bytesize} bytes)"
end

dir = __dir__
index = {}

GOOGLE_FAMILIES.each do |family, weights|
  url = "https://fonts.googleapis.com/css2?family=#{family.tr(" ", "+")}:wght@#{weights.join(";")}&display=swap"
  faces = {}

  get(url).scan(/@font-face\s*\{(.*?)\}/m).each do |(block)|
    next unless block.include?(LATIN_MARKER)

    weight = block[/font-weight:\s*(\d+)/, 1].to_i
    woff2 = block[/src:\s*url\((https:[^)]+\.woff2)\)/, 1]
    next unless woff2 && weights.include?(weight)

    (faces[woff2] ||= []) << weight
  end

  # A variable font answers every requested weight with the same file. Write it
  # once and declare the range it covers, so the browser interpolates instances
  # instead of synthesising a fake bold.
  faces.each do |woff2, covered|
    variable = covered.size > 1
    weight = variable ? "#{covered.min} #{covered.max}" : covered.first.to_s
    name = variable ? "#{family.downcase.tr(" ", "-")}-variable.woff2" : slug(family, weight)

    write(dir, name, woff2, index,
          { "family" => family, "weight" => weight, "subset" => "latin" })
  end
end

FONTSHARE_FAMILIES.each do |family, weights|
  api = "https://api.fontshare.com/v2/css?f%5B%5D=#{family.downcase.tr(" ", "-")}@#{weights.join(",")}"

  get(api).scan(/@font-face\s*\{(.*?)\}/m).each do |(block)|
    weight = block[/font-weight:\s*(\d+)/, 1]
    woff2 = block[%r{url\('(//[^']+\.woff2)'\)}, 1]
    next unless weight && woff2 && weights.include?(weight.to_i)

    write(dir, slug(family, weight), woff2, index,
          { "family" => family, "weight" => weight, "subset" => "full" })
  end
end

File.write(File.join(dir, "fonts.json"), JSON.pretty_generate(index.sort.to_h) + "\n")
puts "wrote fonts.json (#{index.size} faces)"
