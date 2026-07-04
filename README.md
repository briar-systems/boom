# boom

A game engine written in [mach](https://github.com/briar-systems/mach): 2D-first, 3D-capable.

boom composes the briar-systems ecosystem libraries: [mach-glfw](https://github.com/briar-systems/mach-glfw) (windowing/input), [mach-gl](https://github.com/briar-systems/mach-gl) / [mach-vk](https://github.com/briar-systems/mach-vk) (graphics), [mach-audio](https://github.com/briar-systems/mach-audio), [mach-image](https://github.com/briar-systems/mach-image), [mach-font](https://github.com/briar-systems/mach-font), [mach-gltf](https://github.com/briar-systems/mach-gltf), [mach-phys](https://github.com/briar-systems/mach-phys), and [blit](https://github.com/briar-systems/blit) (UI).

## Status

Early development. The engine core is in place: a context-owned lifecycle
(`init` → `run` → `shutdown`), a fixed-timestep loop with render interpolation,
a GLFW window with an OpenGL context, and timing, input-event, and logging
utilities. `boom.graphics` is a v2 render architecture built around a
`Renderer` and render passes: opaque shader, texture, mesh, material, and
render-target handles over the GL backend, with 2D and 3D driven through the
same pass machinery and an extensible vertex format underpinning meshes. A
skeletal animation runtime loads and plays animated glTF models with
mach-gltf fully hidden (see [Animation](#animation)).

## Overview

A game implements the `boom.app.App` hooks and hands them to the run loop. The
`boom.context.Context` owns the window, the frame clock, the fixed-timestep
accumulator, and the input queue; `boom.engine.run` drives the hooks around a
poll → update → render frame, running updates at a fixed rate independent of
the frame rate and exposing the leftover interpolation factor as `ctx.alpha`.

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
    boom.engine.run(?ctx, ?app);

    boom.context.context_shutdown(?ctx);
    ret 0;
}
```

Every `App` hook is optional; leave one `nil` (cast to the hook type) and the
loop skips it.

## Graphics

`boom.graphics` is a render facade over the ecosystem libraries: a game authors
shaders and draws through opaque boom handles (`Shader`, `Texture`, `Mesh`,
`Material`, `RenderTarget`) and never imports `mach-gl`, `mach-gltf`, or
`mach-image`. The uniform interface is keyed by name so a future Vulkan/SPIR-V
backend can replace the GL one without touching game code.

### Renderer and passes

The `Renderer` is the core abstraction. A game creates one (or several), then
each frame calls `renderer_begin_frame`, runs one or more **passes**, and
`renderer_end_frame` to finalize. A **pass** has a target (the window or an
offscreen `RenderTarget`), a projection (a perspective `Camera` for 3D or a
pixel-space orthographic projection for 2D), clear and render state, and an
optional per-pass shader. 2D and 3D go through the same machinery: `pass_scene`
builds a 3D pass and takes mesh draws (`pass_draw`, `pass_draw_material`);
`pass_overlay` builds a 2D pass and takes sprite draws (`pass_draw_sprite`).
Set `PassDesc.target` to render into a texture and `PassDesc.shader` to drive
the pass with a custom program, which is how offscreen and post-process effects
are expressed.

A Renderer holds no module-global state, so instances are independent and
compose: a scene renderer can draw into an offscreen target that a UI renderer
then samples as a texture, both feeding the same window. Presentation is not the
Renderer's job. The engine loop swaps the window once per frame after `f_draw`,
so any number of renderers finalize into one frame before a single present.

Operations that can fail return `Result[T, Error]`, where `Error`
(`boom.graphics.error`) carries its message inline in a fixed buffer, so a
failure needs neither a heap allocation nor a global.

```mach
use gfx: boom.graphics;
use gm:  boom.math;

# a mesh and texture from files (glTF / QOI / TGA), a shader, a material
val cube: gfx.Mesh    = unwrap_ok[gfx.Mesh, gfx.Error](gfx.mesh_load("cube.glb"));
val skin: gfx.Texture = unwrap_ok[gfx.Texture, gfx.Error](gfx.texture_load("skin.qoi"));
var mat:  gfx.Material = gfx.material(?sh);
gfx.material_add_texture(?mat, "u_texture0", ?skin);

# in f_draw: a 3D scene pass, then a 2D overlay pass; the loop presents
gfx.renderer_begin_frame(?renderer);

var scene: gfx.PassDesc = gfx.pass_scene(?camera);
var p3:    gfx.Pass = gfx.pass_begin(?renderer, ?scene);
gfx.pass_draw_material(?p3, ?cube, ?mat, ?transform);
gfx.pass_end(?p3);

var hud: gfx.PassDesc = gfx.pass_overlay();
var p2:  gfx.Pass = gfx.pass_begin(?renderer, ?hud);
gfx.pass_draw_sprite(?p2, ?skin, gfx.rect(16.0, 16.0, 96.0, 96.0), gm.vec4(1.0, 1.0, 1.0, 1.0));
gfx.pass_end(?p2);

gfx.renderer_end_frame(?renderer);   # finalize only; the engine loop presents
```

A 3D mesh shader follows the attribute convention (location 0 = position,
1 = normal, 2 = uv) and declares the `u_model`, `u_view`, `u_projection`
uniforms that pass draws set each call. `examples/cube` is a complete, runnable
consumer that proves renderers compose: a scene renderer draws a glTF cube into
an offscreen target, and a UI renderer blits it to the window through a custom
vignette shader and draws a 2D HUD sprite, all before one present.

### Vertex format

A mesh is described by a `VertexFormat` (`boom.graphics.vertex`): a declared
list of attributes (semantic, component type, count, location) rather than a
fixed vertex struct. `texture_load` / `texture_from_bytes` decode QOI and TGA
images; `mesh_load` / `mesh_from_glb` extract the first primitive of a glTF 2.0
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
gfx.pass_draw_skinned(?scene_pass, ?model.mesh, ?player.pose, ?shader, ?transform);
```

The shader follows the skinning convention: attribute locations 0 = position,
1 = normal, 2 = uv, 5 = joints (`uvec4`), 6 = weights (`vec4`), and a
`u_joints` mat4 palette alongside the usual `u_model`, `u_view`, `u_projection`.
`gfx.SKINNED_VERTEX_SRC` is a ready-to-use skinning vertex shader following it,
so a game only needs to pair it with a fragment shader.

Under the hood the runtime samples the active clip at the current time (linear
for translation and scale, slerp for rotation), composes the local joint
transforms up the hierarchy into joint-world matrices, and multiplies by the
inverse bind matrices to form the skinning palette
(`boom.graphics.skeleton`, `boom.graphics.animation`); `boom.graphics.model`
is the loader. The interim scalar math (`boom.math`: `Vec3`, `Mat4`, `Quat`,
`Transform`, ...) stands in for the shared `mach-math`, which is deferred until
the compiler has SIMD vector types, so that swap stays a localized change.

`examples/animation` is a runnable consumer: it loads a two-bone bar
(`assets/bar.glb`) and plays its bend clip, turning the model so the bend reads
in 3D, all through boom handles.

First pass, documented rather than gold-plated: one active clip at a time (no
blend tree), a bounded joint count for the uniform palette (`MAX_JOINTS`, 128),
and linear or step interpolation. The loader uses the first skin, requires
joint nodes in TRS form, and rejects cubic-spline samplers. Blending, IK,
retargeting, a larger or configurable palette, matrix-form joints, and
morph-target channels are future work.

## Consuming boom

boom builds on several ecosystem libraries whose module ids surface through its
modules: the window layer uses `glfw` and `gl`, and `boom.graphics` uses `gl`,
`image` (texture decoding), and `gltf` (mesh loading). Because Mach's resolver
does not propagate a dependency's module ids through the transitive graph, **a
project that depends on boom must also declare `mach-glfw`, `mach-gl`,
`mach-image`, and `mach-gltf` in its own `mach.toml`**, even though its source
names none of them. Without them the build fails to resolve boom's modules:

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

[deps.mach-gl]
git = "https://github.com/briar-systems/mach-gl"
ref = "branch/dev"

[deps.mach-image]
git = "https://github.com/briar-systems/mach-image"
ref = "branch/dev"

[deps.mach-gltf]
git = "https://github.com/briar-systems/mach-gltf"
ref = "branch/dev"
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
