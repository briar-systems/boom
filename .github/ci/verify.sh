#!/usr/bin/env bash
# the checks the unit suite cannot make: the embedded SPIR-V, the public API as
# the examples call it, and one finite example driving Vulkan under xvfb
set -euo pipefail

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

# the examples are the only check on the shape of the public API. each resolves
# boom by path, so its pull copies this branch rather than anything pushed, and
# the shared fmt check covers the root project only.
for e in examples/*/; do
  echo "::group::$e"
  "$MACH_COMPILER" fmt --check "$e"
  (cd "$e" && "$MACH_COMPILER" dep pull . && "$MACH_COMPILER" build .)
  echo "::endgroup::"
  echo "$e: formatted and built"
done

# unit tests cover invalid borrowed bytes without touching Vulkan. this finite
# example exercises the successful upload, releases its encoded source before
# drawing, then samples and deletes the returned atlas.
timeout --signal=TERM --kill-after=5s 30s xvfb-run -a \
  ./examples/text/out/linux-x86_64/debug/bin/text \
  --font /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
echo "text example ran with borrowed font bytes"
