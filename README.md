# boom

A game engine written in [mach](https://github.com/briar-systems/mach): 2D-first, 3D-capable.

boom composes the briar-systems ecosystem libraries: [mach-glfw](https://github.com/briar-systems/mach-glfw) (windowing/input), [mach-vk](https://github.com/briar-systems/mach-vk) (graphics), [mach-audio](https://github.com/briar-systems/mach-audio), [mach-image](https://github.com/briar-systems/mach-image), [mach-font](https://github.com/briar-systems/mach-font), [mach-gltf](https://github.com/briar-systems/mach-gltf), [mach-phys](https://github.com/briar-systems/mach-phys), and [blit](https://github.com/briar-systems/blit) (UI).

## Status

Early development. The engine core is in place: a context-owned lifecycle
(`init` → `run` → `shutdown`), a fixed-timestep loop with render interpolation,
a GLFW window with no client API, and timing and input-event utilities.
Applications use `std.log` directly. `boom.graphics` is a Vulkan renderer built
around a `Renderer` and render passes: opaque texture, mesh, material, and
render-target handles over mach-vk, with 2D and 3D driven through the same pass
machinery and an extensible vertex format underpinning meshes. Shaders are written in Mach,
compiled to SPIR-V at build time and embedded, so a shipped binary carries
them. A skeletal animation runtime loads and plays animated glTF models with
mach-gltf fully hidden (see [Animation](#animation)).

## Overview

A game implements the `boom.app.App` hooks and hands them to the run loop. The
`boom.context.Context` owns the window, the frame clock, the fixed-timestep
accumulator, and the input queue; `boom.engine.run` drives the hooks around a
poll → update → render frame, running updates at a fixed rate independent of
the frame rate, exposing the leftover interpolation factor as `ctx.alpha`, and
returning the context's final process status.

```mach
use std.runtime;
use std.chrono.duration.SECOND;
use boom;

fun tick(ctx: *boom.context.Context) { }              # fixed-rate update
fun draw(ctx: *boom.context.Context) { }              # render, uses ctx.alpha

#[symbol("main")]
fun main(argc: i64, argv: **u8) i64 {
    var ctx: boom.context.Context;
    val cfg: boom.context.Config = boom.context.Config{
        width:     1280,
        height:    720,
        title:     "example",
        fixed_dt:  SECOND / 60,      # 60 Hz update
        max_frame: SECOND / 4,       # spiral-of-death clamp
        frame_dt:  0,                # wall clock; pin for deterministic probes
    };
    if (!boom.context.context_init(?ctx, cfg)) {
        ret 1;
    }

    var app: boom.app.App = boom.app.App{
        f_init:     nil::fun(*boom.context.Context),
        f_tick:     tick,
        f_draw:     draw,
        f_dnit: nil::fun(*boom.context.Context),
    };
    val status: i64 = boom.engine.run(?ctx, ?app);

    boom.context.context_shutdown(?ctx);
    ret status;
}
```

Every `App` hook is optional; leave one `nil` (cast to the hook type) and the
loop skips it.

Window-manager close requests stop the loop. Escape is otherwise an ordinary
`KEY_ESCAPE` input owned by the application, so it can open a pause menu, act as
Back, or call `context_stop` when the application chooses to quit.
`context_fail` stops immediately and records a non-zero status for `run` to
return. Physics worlds are application-owned and advanced explicitly from a
fixed tick, so pausing one simulation never requires changing the core loop.

## Physics

`boom.physics.Physics` wraps mach-phys without placing a world in the engine
context. Create the worlds the application needs, call `physics_step` from a
fixed tick with `timestep_dt_seconds(?ctx.step)`, and inspect the resulting
contacts with `physics_contact_count` and `physics_contact`. Contacts retain
boom body ids and math types; they are not mixed into the window input queue.

## Graphics

`boom.graphics` is a render facade over the ecosystem libraries: a game draws
through opaque boom handles (`Texture`, `Mesh`, `Material`, `RenderTarget`) and
never imports `mach-vk`, `mach-glfw`, `mach-gltf`, or `mach-image`.

**Resources are created against a `Device`.** Vulkan has no implicit current
context the way GL did, so `texture_load`, `mesh_load`, `model_load`, and
`render_target` take the `Device` that `renderer_device` returns.

**Decoded textures name their colour space.** `texture_load` and
`texture_from_bytes` retain their sRGB default for display colour. Their
`texture_load_as` and `texture_from_bytes_as` forms take `COLOR_SRGB` or
`COLOR_LINEAR`; the latter stores normal, roughness, metallic, occlusion and
mask maps in RGBA8 UNORM so sampling preserves their authored channel values.

**Embedded resources do not need a filesystem round trip.**
`texture_from_bytes_as`, `boom.audio.sound_from_bytes`, and
`font_from_bytes` decode image, WAV, and TrueType byte spans respectively. Each
borrows the encoded bytes only for the call and returns a handle that owns its
decoded GPU or sample storage, so callers may pass compile-time embedded data
and release any temporary buffer immediately afterwards.
The `font_from_bytes_oversampled` and `font_load_oversampled` variants keep
logical text dimensions unchanged while rasterizing extra coverage for scaled
or high-density interfaces.

**Shaders are pipelines, not programs.** A Vulkan pipeline bakes both stages and
the whole fixed-function state into one immutable object, so there is no
per-pass or per-material shader to set. A pipeline is chosen by what a draw is:
a mesh, a skinned mesh, or a sprite. The renderer builds them on demand and
keeps them, keyed by that choice, the mesh's vertex layout, and the target's
attachment formats, because Vulkan bakes both vertex input and render-pass
compatibility into the pipeline. The shaders themselves live in
`src/shaders/` as Mach source, are compiled by artifacts in the root project,
and are embedded from `res/spv/`.

**Every draw takes a uniform slot.** A Vulkan draw reads a buffer range that
must already hold its values when the command buffer executes, so each draw
writes its own slot of a per-frame ring. A frame therefore has a bounded number
of draws, and `renderer_dropped` reports any it refused rather than letting them
silently not appear.

### Renderer and passes

The `Renderer` is the core abstraction. A game creates one (or several), then
each frame calls `renderer_begin_frame`, runs one or more **passes**, and
`renderer_end_frame` to finalize. A **pass** has a target (the window or an
offscreen `RenderTarget`), a projection (a perspective `Camera` for 3D or a
pixel-space orthographic projection for 2D), and clear and render state. 2D and
3D go through the same machinery: `pass_scene` builds a
3D pass and takes mesh draws (`pass_draw`, `pass_draw_material`,
`pass_draw_skinned`); `pass_overlay` builds a 2D pass and takes sprite draws
(`pass_draw_sprite`). Set `PassDesc.target` to render into a texture, which is
how offscreen and post-process effects are expressed.

**There is one Renderer per window.** A Renderer owns the device, the swapchain,
and the frame loop, and it presents: a Vulkan frame is bracketed by an acquire
and a present around one command buffer, and that bracket is the Renderer's.
Compositing several sources into a frame is what passes and render targets are
for. A pass targeting an offscreen `RenderTarget` suspends the window's render
pass and resumes it afterwards without erasing what the frame has drawn, so a
later pass can sample that target as a texture.

The default target constructors use the window's format. A
`RenderTargetDesc` can instead choose sRGB RGBA8, linear RGBA8, or floating-point
RGBA16 independently for each attachment. Materials sample nearest by default;
`material_add_texture_filtered` selects linear filtering for bindings such as a
scaled scene, continuous data field, or bloom buffer. Before a custom `Shader`'s
first draw, pass its `PipelineDesc` to `shader_set_state`; `blend` can replace the
attachment (`BLEND_OPAQUE`), compose with source alpha (`BLEND_SOURCE_ALPHA`),
or sum overlapping contributions (`BLEND_ADDITIVE`). Additive mode sums alpha
as well as RGB, and the selected mode applies to every attachment in the pass.

**Reading a target back is a stall, and that is the point.** `render_target_read`
copies the first colour attachment into host memory as packed RGBA8 and
`render_target_read_raw_at` copies any attachment in its native format, which is
the operation behind a screenshot, a rendering test, or a probe that checks a
pass drew what it claimed. Both drain the device before copying, so the image is
whole rather than one a pass was still writing, and that drain is a full
pipeline stall: a debugging and tooling facility, not something a shipping frame
does. A read reports the last frame that was *submitted*. Passes record into the
frame's command buffer and `renderer_end_frame` is what submits it, so a read
taken between `renderer_begin_frame` and `renderer_end_frame` hands back the
previous frame complete rather than the one being recorded; end the frame first
when the current one's draws are the point. `renderer_wait_idle` performs the
same drain on its own, for tooling that reads several targets in a row or times
work that would otherwise still be in flight.

`renderer_begin_frame` reports through an out parameter whether a frame was
actually opened. A `false` there is a swapchain that went out of date and was
rebuilt, which every window resize causes; the correct response is to skip the
frame, not to treat it as an error.

**The present mode is the game's, and it can change while the game runs.**
`renderer_init` presents with `PRESENT_VSYNC`. `renderer_init_with_present`
asks instead for `PRESENT_MAILBOX` (uncapped, no tearing, frames overtaken
before they are shown are discarded) or `PRESENT_IMMEDIATE` (uncapped, tears,
and the mode to profile under, since vsync reports every frame as the display
interval regardless of what it cost). `renderer_set_present_mode` is what a
settings screen calls: it rebuilds the swapchain, and every texture, mesh,
font and pipeline the game has loaded survives. Vsync is the only mode a Vulkan
implementation is required to support, so the other two are requests.
`renderer_present_mode_supported` answers ahead of the attempt,
`renderer_present_mode` reports the mode actually in use after a fallback, and
`renderer_present_mode_requested` reports the one asked for, which is the one to
save: writing back the mode in use would replace a player's `PRESENT_MAILBOX`
with the vsync one machine fell back to.

Operations that can fail return `Result[T, Error]`, where `Error`
(`boom.graphics.error`) carries its message inline in a fixed buffer, so a
failure needs neither a heap allocation nor a global.

```mach
use gfx: boom.graphics;
use gm:  boom.math;

# resources are created against the renderer's device
val d: *gfx.Device = gfx.renderer_device(?renderer);

# a mesh, display colour and data map from files, and a material
val cube: gfx.Mesh    = unwrap_ok[gfx.Mesh, gfx.Error](gfx.mesh_load(d, "cube.glb"));
val skin: gfx.Texture = unwrap_ok[gfx.Texture, gfx.Error](gfx.texture_load(d, "skin.qoi"));
val norm: gfx.Texture = unwrap_ok[gfx.Texture, gfx.Error](
    gfx.texture_load_as(d, "normal.qoi", gfx.COLOR_LINEAR));
var mat:  gfx.Material = gfx.material();
gfx.material_add_texture(?mat, "u_texture0", ?skin);
gfx.material_add_texture(?mat, "u_normal", ?norm);

# in f_draw: a 3D scene pass, then a 2D overlay pass
var opened: bool = false;
gfx.renderer_begin_frame(?renderer, ?opened);
if (!opened) { ret; }   # the swapchain was rebuilt; skip this frame

var scene: gfx.PassDesc = gfx.pass_scene(?camera);
var p3:    gfx.Pass = gfx.pass_begin(?renderer, ?scene);
gfx.pass_draw_material(?p3, ?cube, ?mat, ?transform);
gfx.pass_end(?p3);

var hud: gfx.PassDesc = gfx.pass_overlay();
var p2:  gfx.Pass = gfx.pass_begin(?renderer, ?hud);
gfx.pass_draw_sprite(?p2, ?skin, gfx.rect(16.0, 16.0, 96.0, 96.0), gm.vec4(1.0, 1.0, 1.0, 1.0));
gfx.pass_end(?p2);

gfx.renderer_end_frame(?renderer);   # submits and presents
```

`examples/cube` is a complete, runnable consumer that proves passes compose: a
scene pass draws a glTF cube into an offscreen target, a second pass blits that
target across the window, and a third draws a 2D HUD sprite, all in one frame.
`examples/vulkan` is a smoke test of the same surface with no assets on disk,
for checking the driver path on a machine with a GPU.

### Vertex format

A mesh is described by a `VertexFormat` (`boom.graphics.vertex`): a declared
list of attributes (semantic, component type, count, location) rather than a
fixed vertex struct. The texture loaders decode PNG, QOI and TGA images;
`mesh_load` / `mesh_from_glb` extract the first primitive of a glTF 2.0
`.glb`, building the format from whatever attributes the primitive provides
(POSITION plus any NORMAL, TEXCOORD_0, COLOR_0, TANGENT). Both hide the backing
libraries entirely and return an `Error` on anything they cannot handle.

The format also carries the `JOINTS_0` (integer-bound) and `WEIGHTS_0`
attributes that skinning needs; `mesh_load` reads them from a skinned
primitive and the skinning runtime consumes them (see
[Animation](#animation)).

### Animation

Skeletal animation loads and plays animated glTF models with mach-gltf fully
hidden. `model_load` returns a `Model`: a skinned `Mesh`, a `Skeleton` (joints,
parent hierarchy, and inverse bind matrices), and the named `Animation` clips,
all boom types. `model_player(name)` binds an `AnimationPlayer` to a named clip;
each frame you advance the player by the elapsed time and draw it, and
`pass_draw_skinned` uploads the joint palette and draws the skinned mesh.

```mach
use gfx: boom.graphics;

# load once: mesh, skeleton, and named clips, mach-gltf hidden
val model:  gfx.Model = unwrap_ok[gfx.Model, gfx.Error](gfx.model_load("char.glb"));
var player: gfx.AnimationPlayer = unwrap_ok[gfx.AnimationPlayer, gfx.Error](gfx.model_player(?model, "walk"));

# in f_tick: advance the clock by the elapsed seconds
gfx.animation_player_advance(?player, dt);

# in f_draw: draw the current pose in a 3D pass
gfx.pass_draw_skinned(?scene_pass, ?model.mesh, ?player.pose, ?transform);
```

Passing a `Pose` is what selects the skinned pipeline. The renderer uploads the
pose's joint matrices into a per-frame storage buffer that
`src/shaders/skinned_vert.mach` reads, and that shader places each vertex by its
four weighted joints before applying the model, view, and projection. A mesh
whose vertex layout carries no joints or weights is drawn unskinned rather than
through a program whose vertex inputs it cannot satisfy.

Under the hood the runtime samples the active clip at the current time (linear
for translation and scale, slerp for rotation), composes the local joint
transforms up the hierarchy into joint-world matrices, and multiplies by the
inverse bind matrices to form the skinning palette
(`boom.graphics.skeleton`, `boom.graphics.animation`); `boom.graphics.model`
is the loader. The shared math layer (`boom.math`: `Vec3`, `Mat4`, `Quat`,
`Transform`, ...) uses native SIMD vectors throughout, including four
column-major `f32x4` values for a matrix.

`examples/animation` is a runnable consumer: it loads a two-bone bar
(`assets/bar.glb`) and plays its bend clip, turning the model so the bend reads
in 3D, all through boom handles.

First pass, documented rather than gold-plated: one active clip at a time (no
blend tree), a bounded joint count for the palette (`MAX_JOINTS`, 128) and a bounded number
of skinned draws per frame (`MAX_PALETTES`, 32),
and linear or step interpolation. The loader uses the first skin, requires
joint nodes in TRS form, and rejects cubic-spline samplers. Blending, IK,
retargeting, a larger or configurable palette, matrix-form joints, and
morph-target channels are future work.

## Consuming boom

boom builds on several ecosystem libraries whose module ids surface through its
modules: the window layer uses `glfw`, and `boom.graphics` uses `vk`, `image`
(texture decoding), and `gltf` (mesh loading). Because Mach's resolver does not
propagate a dependency's module ids through the transitive graph, **a project
that depends on boom must also declare `mach-glfw`, `mach-vk`, `mach-image`,
and `mach-gltf` in its own `mach.toml`**, even though its source names none of
them. Without them the build fails to resolve boom's modules:

```
error: use path 'glfw.glfw' does not name a module
```

`mach dep pull` materialises the packages transitively, but the flat resolver
only registers dep ids that the consuming project declares directly, so the
stanzas are required. Pin them to the **same refs boom uses**; the resolver has
no version override, so a mismatched ref is a hard conflict:

```toml
[deps.boom]
git = "https://github.com/briar-systems/boom"
ref = "branch/dev"

[deps.mach-glfw]
git = "https://github.com/briar-systems/mach-glfw"
ref = "branch/main"

[deps.mach-vk]
git = "https://github.com/briar-systems/mach-vk"
ref = "branch/main"

[deps.mach-image]
git = "https://github.com/briar-systems/mach-image"
ref = "branch/main"

[deps.mach-gltf]
git = "https://github.com/briar-systems/mach-gltf"
ref = "branch/main"
```

This is a manifest requirement only; your source still imports just `use boom;`.

## Building

```sh
mach dep pull
mach build .
mach test .
```

Building a game that links against boom's window layer needs GLFW available to
the linker; the library build and the test suite do not.

## macOS

Apple ships Metal and no Vulkan driver, so a macOS build runs against
[MoltenVK](https://github.com/KhronosGroup/MoltenVK), which translates Vulkan to
Metal underneath. boom enables the portability extensions that arrangement
requires, so nothing about the build differs.

Older Intel machines need one environment variable set before the binary runs.
MoltenVK builds its descriptor sets out of Metal argument buffers by default,
and the Metal driver for the Intel HD 5000 generation mishandles them, so a
binary that builds and links cleanly crashes inside the driver instead of
drawing. Turning that path off avoids it:

```sh
export MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0
```
