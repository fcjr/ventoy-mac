#!/bin/sh
# Insert a release <item> into appcast.xml.
#   usage: update-appcast.sh <version> <enclosure-attrs>
# where <enclosure-attrs> is sign_update's output, e.g.
#   sparkle:edSignature="..." length="..."
set -eu

version="$1"
shift
attrs="$*"
date="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

tmp="$(mktemp)"
cat > "$tmp" <<EOF
    <item>
      <title>${version}</title>
      <sparkle:version>${version}</sparkle:version>
      <sparkle:shortVersionString>${version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <pubDate>${date}</pubDate>
      <enclosure
        url="https://github.com/fcjr/ventoy-mac/releases/download/v${version}/Ventoy2Disk-${version}.zip"
        ${attrs}
        type="application/octet-stream"/>
    </item>
EOF

awk -v itemfile="$tmp" '
    { print }
    /<language>en<\/language>/ {
        while ((getline line < itemfile) > 0) print line
        close(itemfile)
    }
' appcast.xml > appcast.xml.new
mv appcast.xml.new appcast.xml
rm -f "$tmp"
