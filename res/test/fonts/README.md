# Test fonts

`DejaVuSans-subset.ttf` is a subset of DejaVu Sans 2.37. boom's device-free
text tests embed it (`src/graphics/text/fixture.mach`). Nothing in the library
imports it, so it never reaches a consumer's build. It is licensed under
`LICENSE-DejaVu`, the DejaVu fonts license. That license permits modified
copies whose names contain none of "Bitstream", "Vera", "Arev" or
"Tavmjong Bah".

## Regenerating

The subset was made with fontTools 4.63.0 from DejaVu Sans 2.37
(Arch `ttf-dejavu 2.37+18+g9b5d1b2f-8`):

```sh
pyftsubset /usr/share/fonts/TTF/DejaVuSans.ttf \
  --unicodes="U+0020-007E,U+00A0-00FF,U+0391-03A9,U+03B1-03C9,U+0410-044F,U+FFFD" \
  --no-hinting --layout-features='' --drop-tables+=MATH,FFTM --glyph-names \
  --output-file=res/test/fonts/DejaVuSans-subset.ttf
```

The codepoints are:
- Basic Latin
- Latin-1 Supplement, which includes the composite U+00E9
- Greek capitals and small letters
- the basic Cyrillic block
- U+FFFD

Everything else resolves to `.notdef`, which the tests rely on, for example
U+4F60. The result is 24056 bytes, 319 glyphs, with SHA-256
`9e6411d8b24d384f493c930f5945b0e321769f69e69dd432d5710d2af4dc2190`.

The tests assert the subset's own metrics:
- units per em 2048, ascent 1901, descent -483
- `A` is glyph 34 with advance 1401 and lsb 16
- `a` 1255, `b` 1300, `c` 1126, space 651
- `é` 1260, `Ж` 2206, U+FFFD 2100, `.notdef` 1229

A regenerated file that changes any of these must update
`src/graphics/text/fixture.mach` to match.
