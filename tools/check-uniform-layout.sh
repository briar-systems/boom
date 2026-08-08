#!/usr/bin/env bash
#
# Assert that each shader's uniform block matches the CPU record that fills it.
#
# A uniform block is a contract between two separately compiled programs, and
# nothing at runtime checks that they agree. A member at the wrong offset is not
# an error at any layer: the shader reads whatever bytes are at the offset it
# expects. The result is geometry in the wrong place or a colour that is part of
# a matrix, with no diagnostic anywhere.
#
# The unit tests in src/graphics/uniform.mach assert the CPU side's sizes. This
# asserts the other side, by reading the Offset decorations out of the emitted
# SPIR-V, so the two are checked against each other rather than each against its
# author's intent.
#
# Run from the repo root, after the shaders have been built.

set -euo pipefail

spv_dir="res/spv"
fail=0

# Total byte size of a block: the last member's offset plus its size. Every
# member in these blocks is a vec4, so 16.
block_size() {
    local file="$1"
    spirv-dis "$file" \
        | grep -oE 'OpMemberDecorate %[A-Za-z0-9_]+ [0-9]+ Offset [0-9]+' \
        | awk '{print $NF}' | sort -n | tail -1 \
        | awk '{print $1 + 16}'
}

member_count() {
    local file="$1"
    spirv-dis "$file" | grep -cE 'OpMemberDecorate %[A-Za-z0-9_]+ [0-9]+ Offset [0-9]+'
}

# Every member must be 16 bytes from the previous one. A gap means std140 padded
# something, which the CPU record would not reproduce.
check_stride() {
    local file="$1"
    spirv-dis "$file" \
        | grep -oE 'OpMemberDecorate %[A-Za-z0-9_]+ [0-9]+ Offset [0-9]+' \
        | awk '{print $NF}' | sort -n \
        | awk 'NR > 1 && $1 != prev + 16 { print "gap at offset " $1; bad = 1 } { prev = $1 } END { exit bad }'
}

expect() {
    local name="$1" file="$2" want_size="$3" want_members="$4"

    if [ ! -f "$file" ]; then
        echo "SKIP $name: $file not built"
        return
    fi

    local size members
    size=$(block_size "$file")
    members=$(member_count "$file")

    if [ "$size" != "$want_size" ]; then
        echo "FAIL $name: shader block is $size bytes, CPU record is $want_size"
        fail=1
    elif [ "$members" != "$want_members" ]; then
        echo "FAIL $name: shader block has $members members, expected $want_members"
        fail=1
    elif ! check_stride "$file"; then
        echo "FAIL $name: members are not 16 bytes apart, so std140 inserted padding"
        fail=1
    else
        echo "ok   $name: $members members, $size bytes, matching the CPU record"
    fi
}

# MeshUniforms: mvp and model, four f32x4 columns each.
expect "mesh_vert / MeshUniforms" "$spv_dir/mesh_vert.spv" 128 8

# SpriteUniforms: projection, model, then the source rect.
expect "sprite_vert / SpriteUniforms" "$spv_dir/sprite_vert.spv" 144 9

exit "$fail"
