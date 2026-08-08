#!/usr/bin/env python3
"""Assert that each shader's interface blocks match the CPU records that fill them.

A uniform block is a contract between two separately compiled programs, and
nothing at runtime checks that they agree. A member at the wrong offset is not an
error at any layer: the shader reads whatever bytes are at the offset it expects.
The result is geometry in the wrong place or a colour that is part of a matrix,
with no diagnostic anywhere.

The unit tests in src/graphics/uniform.mach assert the CPU side's sizes. This
asserts the other side, by reading the decorations out of the emitted SPIR-V, so
the two are checked against each other rather than each against its author's
intent.

BLOCKS ARE SCOPED BY THEIR BINDING, not counted across the module. A shader that
declares two blocks, as skinned_vert does with its matrices and its joint
palette, has offsets from both interleaved in the disassembly. Counting all of
them reports a member total that belongs to no block and passes or fails for the
wrong reason.

Run from the repo root, after the shaders have been built.
"""

import re
import subprocess
import sys

SPV_DIR = "res/spv"

fail = False
skipped = 0


def disassemble(path):
    """The SPIR-V disassembly, or None when the module was not built."""
    try:
        return subprocess.run(
            ["spirv-dis", path], capture_output=True, text=True, check=True
        ).stdout
    except (FileNotFoundError, subprocess.CalledProcessError):
        return None


def parse(text):
    """Bindings, storage classes, and per-struct member offsets.

    Returns (bindings, classes, offsets, strides) where bindings maps a binding
    number to the struct it names, classes maps it to the SPIR-V storage class,
    offsets maps a struct id to its member offsets in declaration order, and
    strides is the set of array strides declared anywhere in the module.
    """
    var_binding = {}
    var_pointer = {}
    var_class = {}
    pointer_struct = {}
    offsets = {}
    strides = set()

    for line in text.splitlines():
        m = re.search(r"OpDecorate (%\S+) Binding (\d+)", line)
        if m:
            var_binding[m.group(1)] = int(m.group(2))
            continue
        m = re.search(r"(%\S+) = OpVariable (%\S+) (\w+)", line)
        if m:
            var_pointer[m.group(1)] = m.group(2)
            var_class[m.group(1)] = m.group(3)
            continue
        m = re.search(r"(%\S+) = OpTypePointer \w+ (%\S+)", line)
        if m:
            pointer_struct[m.group(1)] = m.group(2)
            continue
        m = re.search(r"OpMemberDecorate (%\S+) (\d+) Offset (\d+)", line)
        if m:
            offsets.setdefault(m.group(1), {})[int(m.group(2))] = int(m.group(3))
            continue
        m = re.search(r"OpDecorate %\S+ ArrayStride (\d+)", line)
        if m:
            strides.add(int(m.group(1)))

    bindings = {}
    classes = {}
    for var, binding in var_binding.items():
        classes[binding] = var_class.get(var, "?")
        ptr = var_pointer.get(var)
        if ptr in pointer_struct:
            bindings[binding] = pointer_struct[ptr]
    return bindings, classes, offsets, strides


# Capabilities the modules are allowed to declare, and why.
#
# A SPIR-V capability is a hardware requirement. Declaring one that no device
# feature was enabled for is invalid usage at vkCreateShaderModule, and a driver
# may honour it anyway, so the shader works on the machine it was written on and
# is rejected on someone else's. Two of these shipped in 0.3.0 undetected, and
# neither was asked for by any shader: both came out of codegen.
#
# Anything not listed is a hardware requirement that arrived without being
# chosen. Adding an entry is the moment to also enable the matching feature in
# boom.graphics.vk, and to say here what forced it.
ALLOWED_CAPABILITIES = {
    # Core to every SPIR-V shader module.
    "Shader": "the baseline capability every module declares",
    # From codegen, not from the shaders. An optional VkPhysicalDeviceFeatures
    # bit that boom must therefore request, narrowing the devices it runs on.
    "Int64": "mach#2878: 32-bit array indices lower to 64-bit locals",
}

# Capabilities that must be matched by a feature request at device creation.
REQUIRES_FEATURE = {
    "Int64": "shaderInt64",
}


def check_capabilities(module):
    """No module may declare a capability that was not chosen deliberately."""
    text = disassemble(f"{SPV_DIR}/{module}.spv")
    if text is None:
        skip(f"{module}: not built, so its capabilities were not checked")
        return

    declared = set(re.findall(r"OpCapability (\w+)", text))
    unexpected = sorted(declared - set(ALLOWED_CAPABILITIES))
    if unexpected:
        report(False, f"{module}: declares {unexpected}, which nothing enables a device feature for")
        return

    needed = sorted(c for c in declared if c in REQUIRES_FEATURE)
    if needed:
        features = ", ".join(REQUIRES_FEATURE[c] for c in needed)
        report(True, f"{module}: declares {sorted(declared)}; {features} must be enabled")
        return
    report(True, f"{module}: declares {sorted(declared)}")


def report(ok, message):
    global fail
    if ok:
        print("ok   " + message)
    else:
        print("FAIL " + message)
        fail = True


def skip(message):
    global skipped
    skipped += 1
    print("SKIP " + message)


def check_block(name, module, binding, want_size, want_members):
    """A block at a binding must have the member count and size of its record."""
    text = disassemble(f"{SPV_DIR}/{module}.spv")
    if text is None:
        skip(f"{name}: {module}.spv not built")
        return

    bindings, _, offsets, _ = parse(text)
    struct = bindings.get(binding)
    if struct is None:
        report(False, f"{name}: no block at binding {binding}")
        return

    members = offsets.get(struct, {})
    count = len(members)
    if count != want_members:
        report(False, f"{name}: shader block has {count} members, CPU record has {want_members}")
        return

    # Every member in these blocks is 16 bytes wide on purpose, so the size is
    # the last offset plus 16 and consecutive offsets must differ by exactly 16.
    # A gap means std140 padded something the CPU record does not reproduce.
    ordered = [members[i] for i in sorted(members)]
    for prev, cur in zip(ordered, ordered[1:]):
        if cur - prev != 16:
            report(False, f"{name}: a gap at offset {cur}, so std140 inserted padding")
            return

    size = ordered[-1] + 16
    if size != want_size:
        report(False, f"{name}: shader block is {size} bytes, CPU record is {want_size}")
        return

    report(True, f"{name}: {count} members, {size} bytes, matching the CPU record")


def check_bindings(name, module, want):
    """The set of bindings a stage declares must be the subset the CPU expects.

    A missing binding in the CPU's set layout does not fail loudly: the shader
    reads a descriptor that was never written. This is the check that catches it,
    and it is the one that caught the set layout stopping at binding 1 while
    sprite_frag declared a tint at binding 2.
    """
    text = disassemble(f"{SPV_DIR}/{module}.spv")
    if text is None:
        skip(f"{name}: {module}.spv not built")
        return

    _, classes, _, _ = parse(text)
    got = sorted(classes)
    report(got == want, f"{name}: declares bindings {got}, CPU layout declares {want}")


def check_class(name, module, binding, want):
    """A binding's storage class decides its layout rules.

    A uniform block follows std140, under which an array of anything narrower
    than 16 bytes is refused rather than repacked; a storage buffer follows
    std430 and uses the natural stride. Moving the palette between the two would
    change how it must be uploaded, with no change to its member offsets, so the
    class is asserted rather than inferred from them.
    """
    text = disassemble(f"{SPV_DIR}/{module}.spv")
    if text is None:
        skip(f"{name}: {module}.spv not built")
        return

    _, classes, _, _ = parse(text)
    got = classes.get(binding, "absent")
    report(got == want, f"{name}: binding {binding} is in the {got} class, expected {want}")


def check_stride(name, module, want):
    text = disassemble(f"{SPV_DIR}/{module}.spv")
    if text is None:
        skip(f"{name}: {module}.spv not built")
        return

    _, _, _, strides = parse(text)
    report(want in strides, f"{name}: array strides {sorted(strides)} include {want}")


# MeshUniforms: mvp and model, four f32x4 columns each.
check_block("mesh_vert / MeshUniforms", "mesh_vert", 0, 128, 8)

# SkinnedUniforms: view_proj and model. Deliberately the same size as
# MeshUniforms, because boom.graphics.renderer writes the base colour into the
# slot at one fixed offset for both programs.
check_block("skinned_vert / SkinnedUniforms", "skinned_vert", 0, 128, 8)

# SpriteUniforms: projection, model, then the source rect.
check_block("sprite_vert / SpriteUniforms", "sprite_vert", 0, 144, 9)

# TintUniforms, read by both fragment stages at binding 2.
check_block("sprite_frag / TintUniforms", "sprite_frag", 2, 16, 1)
check_block("lit_frag / base colour", "lit_frag", 2, 16, 1)

# set_layout_full is what every pipeline is built against: uniform 0, sampler 1,
# uniform 2, storage 3. No single stage declares all four; each declares the
# subset it reads, and the union is what the descriptor pool allocates.
check_bindings("mesh_vert / set_layout_full", "mesh_vert", [0])
check_bindings("skinned_vert / set_layout_full", "skinned_vert", [0, 3])
check_bindings("sprite_vert / set_layout_full", "sprite_vert", [0])
check_bindings("sprite_frag / set_layout_full", "sprite_frag", [1, 2])
check_bindings("lit_frag / set_layout_full", "lit_frag", [1, 2])

# The joint palette must stay a storage buffer. As a uniform block its array of
# columns would fall under std140, and boom uploads a boom.math.Mat4 palette as a
# straight copy on the strength of std430's natural stride.
check_class("skinned_vert / palette", "skinned_vert", 3, "StorageBuffer")
check_stride("skinned_vert / palette", "skinned_vert", 16)

# Every module's capabilities. This is the check that would have caught the two
# device features 0.3.0 required without enabling, and it needs no GPU.
for module in ("mesh_vert", "skinned_vert", "sprite_vert", "sprite_frag", "lit_frag"):
    check_capabilities(module)

# A skip is not a pass. Say so rather than letting a green line count stand in
# for coverage that did not happen.
if skipped:
    print()
    print(f"NOTE {skipped} check(s) skipped because their module was not built.")
    print("     These are NOT passes: a module that failed to build reports")
    print("     nothing here, which is exactly when the check matters most.")

sys.exit(1 if fail else 0)
