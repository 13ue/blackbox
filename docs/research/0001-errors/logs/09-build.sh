#!/bin/sh
# builds index.html from the 0029 style block + logs/09-* parts
cd "$(dirname "$0")/.."
R=../0029-follow/index.html
{ sed -n 1,5p $R
  printf '%s\n' '<!-- The research page of ADR 0031 (docs/adr/0031-blackbox-every-failure-and-what-came-before.md). In dev it is served at /dev/adr/31/.' \
    '     The style block below is 0029-follow/index.html'"'"'s, verbatim; ADR 0031 additions follow it. -->' \
    '<style>:root{color-scheme:light dark}body{margin:0}img{max-width:100%}[hidden]{display:none!important}</style>' \
    '<title>1charta Blackbox</title>'
  sed -n 10,306p $R
  echo '/* ---- ADR 0031 additions ---- */'
  cat logs/09-extra.css
  echo '</style>'; echo '</head>'; echo '<body>'
  cat logs/09-body-1.html logs/09-body-2.html logs/09-body-3.html
} > index.html
