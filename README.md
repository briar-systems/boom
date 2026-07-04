# boom

A game engine written in [mach](https://github.com/briar-systems/mach): 2D-first, 3D-capable.

boom composes the briar-systems ecosystem libraries: [mach-glfw](https://github.com/briar-systems/mach-glfw) (windowing/input), [mach-gl](https://github.com/briar-systems/mach-gl) / [mach-vk](https://github.com/briar-systems/mach-vk) (graphics), [mach-audio](https://github.com/briar-systems/mach-audio), [mach-image](https://github.com/briar-systems/mach-image), [mach-font](https://github.com/briar-systems/mach-font), [mach-gltf](https://github.com/briar-systems/mach-gltf), [mach-phys](https://github.com/briar-systems/mach-phys), and [blit](https://github.com/briar-systems/blit) (UI).

## Status

Early development. The engine core is in place: a context-owned lifecycle
(`init` → `run` → `shutdown`), a fixed-timestep loop with render interpolation,
a GLFW window with an OpenGL context, and timing, input-event, and logging
utilities. A first-pass `boom.graphics` render facade adds opaque shader,
texture, mesh, and material handles over the GL backend with an immediate-mode
draw path.

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
shaders and draws 3D assets through opaque boom handles (`Shader`, `Texture`,
`Mesh`, `Material`) and never imports `mach-gl`, `mach-gltf`, or `mach-image`.
The API is immediate-mode and imposes no scene structure; the game owns its
world and calls `draw` each frame against a `Camera` and `Transform` it
controls. The uniform interface is keyed by name so a future Vulkan/SPIR-V
backend can replace the GL one without touching game code.

```mach
use gfx: boom.graphics;
use gm:  boom.graphics.math;

# shader() returns Result[gfx.Shader, str]; the error is the compile/link log
val compiled: Result[gfx.Shader, str] = gfx.shader(vertex_glsl, fragment_glsl);
val sh:       gfx.Shader               = unwrap_ok[gfx.Shader, str](compiled);
val cube:     gfx.Mesh                 = gfx.mesh(?verts[0], 24, ?indices[0], 36);

gfx.clear(gm.vec4(0.08, 0.09, 0.12, 1.0));
gfx.draw(?cube, ?sh, ?transform, ?camera);
```

A vertex shader follows the fixed attribute convention (location 0 = position,
1 = normal, 2 = uv) and declares the `u_model`, `u_view`, `u_projection`
uniforms that `draw` sets each call. `examples/cube` is a complete, runnable
consumer.

The interim scalar math (`boom.graphics.math`: `Vec3`, `Mat4`, `Quat`, ...)
stands in for the shared `mach-math`, which is deferred until the compiler has
SIMD vector types; it is imported on its own so that swap is a one-line change.

Loading a texture from an encoded image file or a mesh from a glTF asset is not
yet available: `mach-image` currently detects formats but does not decode
pixels, and `mach-gltf` validates the `.glb` container but does not yet extract
geometry. Those entry points land once the libraries grow the capability, with
no change to the handles.

## Consuming boom

boom's public surface exposes its GLFW and GL dependencies: `boom.window.Window`
embeds a `glfw.Window` and the engine issues `gl` calls. Because Mach's resolver
does not propagate a dependency's surface module ids through the transitive
graph, **a project that depends on boom must also declare `mach-glfw` and
`mach-gl` in its own `mach.toml`**, even if it never names `glfw` or `gl`
itself. Without them the build fails to resolve boom's modules:

```
error: use path 'glfw.glfw' does not name a module
```

`mach dep pull` materialises both packages transitively, but the flat resolver
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
