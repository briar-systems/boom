#!/usr/bin/env bash
# the checks the unit suite cannot make: the embedded SPIR-V, finite demos
# driving Vulkan under xvfb, and a fresh root project that depends on boom
set -euo pipefail

# a game is a fresh root that depends on boom, and that root's std wins over
# every pin beneath it. boom's own demos pin std themselves, so they never
# see the std a fresh `mach init` selects; boom#184 was exactly that shape
# failing. the root takes whatever std mach init picks today, on purpose.
root=$(mktemp -d)/game
mkdir "$root"
"$MACH_COMPILER" init "$root"
cp demo/cube/src/bin/main.mach "$root/src/root.mach"
"$MACH_COMPILER" dep add "$root" boom --path "$PWD"
grep -A2 '^\[dep\.std\]' "$root/mach.toml"
"$MACH_COMPILER" build "$root"
echo "a fresh root builds against boom with the std mach init selected"

# a uniform block is a contract between two separately compiled programs and
# nothing at runtime checks it. boom.graphics.spirv reads the modules it embeds
# and checks them against the CPU records; what a validator adds is that they
# are well formed for the environment they declare. the set is derived from the
# shader-* artifacts the manifest declares, so it cannot go stale.
"$MACH_COMPILER" build . --target spirv --profile release
expected=$(grep -oP '^\[artifact\.shader-\K[^\]]+' mach.toml | sort)
built=$(ls out/spirv/release/spv | sed 's/\.spv$//' | sort)
if [ "$expected" != "$built" ]; then
  echo "::error::the built modules do not match the shader artifacts mach.toml declares"
  diff <(echo "$expected") <(echo "$built") || true
  exit 1
fi
for m in $expected; do
  spirv-val --target-env vulkan1.0 "out/spirv/release/spv/$m.spv"
  echo "$m.spv: valid"
done

# mach 5.12 tests one artifact's closure, so a module neither the library nor
# the tests artifact reaches would drop its tests without a word. the guard
# runs on this leg's target alone: listing darwin or windows builds glfw's C
# step, and this leg has no cross toolchain for it (all-targets is off too)
bash test/selections/verify.sh "$MACH_COMPILER" linux-x86_64

# unit tests cover the UTF-8 walk and the atlas arithmetic without touching
# Vulkan. this finite example releases the encoded font before any glyph is
# rasterized, draws Han text and a line break into a target it reads back, and
# fills a whole atlas page. it runs against a face without Han glyphs, which
# draws .notdef boxes, and against a TrueType Han face, which draws the glyphs.
for font in /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf \
            /usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf; do
  timeout --signal=TERM --kill-after=5s 30s xvfb-run -a \
    ./demo/text/out/linux-x86_64/debug/bin/text --font "$font"
  echo "text example passed with $font"
done

# the renderer example reads the window itself back and checks it against the
# frame's geometry. lavapipe offers TRANSFER_SRC on its swapchain images, so a
# skip here means the surface decision went wrong and the flag makes it fail.
timeout --signal=TERM --kill-after=5s 60s xvfb-run -a \
  ./demo/vulkan/out/linux-x86_64/debug/bin/vulkan --require-readback
echo "vulkan example passed with the window read back"
