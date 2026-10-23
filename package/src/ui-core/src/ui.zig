//! The UI engine facade: one document with its style engine, layout and
//! display list. Hosts (windows, bindings, tests) drive it with mutations and
//! call `update()` once per frame.
const std = @import("std");
const builtin = @import("builtin");
const dom = @import("dom.zig");
const html = @import("html.zig");
const style_mod = @import("style.zig");
const layout = @import("layout.zig");
const paint = @import("paint.zig");
const font = @import("text/font.zig");
const events = @import("events.zig");
const anim = @import("anim.zig");
const images = @import("images.zig");
const geom = @import("geom.zig");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// text backend; null = platform default
    fonts: ?font.Backend = null,
};

pub fn defaultFonts(gpa: Allocator) !font.Backend {
    if (builtin.os.tag == .macos) return @import("text/coretext.zig").CoreTextBackend.create(gpa);
    return font.MockBackend.create(gpa);
}

pub const Ui = struct {
    gpa: Allocator,
    doc: *dom.Document,
    styles: style_mod.Engine,
    fonts: font.Backend,
    owns_fonts: bool,
    layout: layout.Layout,
    dl: paint.DisplayList,
    ix: events.Interaction,
    animator: anim.Animator,
    images: images.Store,
    paint_hooks: paint.Hooks = .{},
    /// seconds, advanced by `tick`
    now: f64 = 0,
    width: f32 = 800,
    height: f32 = 600,
    scale: f32 = 1,
    dark: bool = false,
    reduced_motion: bool = false,
    /// set when the display list changed since the last `takeFrame`
    frame_dirty: bool = true,

    pub fn create(gpa: Allocator, opts: Options) !*Ui {
        const ui = try gpa.create(Ui);
        errdefer gpa.destroy(ui);
        const fonts = opts.fonts orelse try defaultFonts(gpa);
        const doc = try dom.Document.init(gpa);
        doc.node_finalizer = finalizeNode;
        ui.* = .{
            .gpa = gpa,
            .doc = doc,
            .styles = style_mod.Engine.init(gpa),
            .fonts = fonts,
            .owns_fonts = opts.fonts == null,
            .layout = layout.Layout.init(gpa, doc, fonts),
            .dl = paint.DisplayList.init(gpa),
            .ix = undefined,
            .animator = undefined,
            .images = images.Store.init(gpa),
        };
        ui.ix = events.Interaction.init(gpa, doc, &ui.layout, &ui.dl);
        ui.animator = anim.Animator.init(gpa, doc, &ui.styles);
        ui.styles.on_style_change = anim.Animator.onStyleChange;
        ui.styles.on_style_change_ctx = &ui.animator;
        ui.layout.hooks = .{ .ctx = ui, .control_text = controlText, .natural_size = naturalSize };
        ui.paint_hooks = .{ .ctx = ui, .text_state = textState, .image_for = imageFor, .svg_image = svgImage };
        doc.observer = observe;
        doc.observer_ctx = ui;
        return ui;
    }

    fn controlText(ctx: ?*anyopaque, doc: *dom.Document, node: dom.NodeId) ?[]const u8 {
        const ui: *Ui = @ptrCast(@alignCast(ctx.?));
        _ = doc;
        const e = ui.ix.edits.get(node) orelse return null;
        if (ui.doc.node(node).getAttr(ui.doc.atoms.type)) |t| if (std.ascii.eqlIgnoreCase(t, "password")) {
            return passwordMask(ui, e.text.items);
        };
        return e.text.items;
    }

    fn passwordMask(ui: *Ui, text: []const u8) []const u8 {
        const n = std.unicode.utf8CountCodepoints(text) catch text.len;
        const a = ui.layout.scratch.allocator();
        const buf = a.alloc(u8, n * 3) catch return "";
        for (0..n) |i| @memcpy(buf[i * 3 ..][0..3], "\u{2022}");
        return buf;
    }

    fn naturalSize(ctx: ?*anyopaque, doc: *dom.Document, node: dom.NodeId) ?[2]f32 {
        const ui: *Ui = @ptrCast(@alignCast(ctx.?));
        const src = doc.node(node).getAttr(doc.atoms.src) orelse return null;
        const id = ui.images.load(src) orelse return null;
        const img = ui.images.get(id).?;
        return .{ img.css_w, img.css_h };
    }

    fn imageFor(ctx: ?*anyopaque, url: []const u8) ?paint.ImageRef {
        const ui: *Ui = @ptrCast(@alignCast(ctx.?));
        const id = ui.images.load(url) orelse return null;
        const img = ui.images.get(id).?;
        return .{ .id = id, .w = @floatFromInt(img.w), .h = @floatFromInt(img.h) };
    }

    fn svgImage(ctx: ?*anyopaque, node: dom.NodeId, w: f32, h: f32, color: geom.Color) ?paint.ImageRef {
        const ui: *Ui = @ptrCast(@alignCast(ctx.?));
        const id = ui.images.svgImage(ui.doc, node, w, h, ui.scale, color) orelse return null;
        const img = ui.images.get(id).?;
        return .{ .id = id, .w = @floatFromInt(img.w), .h = @floatFromInt(img.h) };
    }

    fn textState(ctx: ?*anyopaque, node: dom.NodeId) ?paint.TextState {
        const ui: *Ui = @ptrCast(@alignCast(ctx.?));
        if (ui.doc.focused != node) return null;
        const e = ui.ix.edits.get(node) orelse return null;
        return .{ .caret = e.caret, .anchor = e.anchor, .scroll_x = e.scroll_x, .scroll_y = e.scroll_y };
    }

    fn observe(doc: *dom.Document, kind: dom.MutationKind, node: dom.NodeId, ctx: ?*anyopaque) void {
        _ = doc;
        _ = kind;
        _ = node;
        _ = ctx;
    }

    /// Destroy a node subtree, dropping its listeners and editing state.
    pub fn destroyNode(ui: *Ui, id: dom.NodeId) void {
        var cur = id;
        while (cur != dom.null_id) : (cur = ui.doc.nextInTree(cur, id)) ui.ix.removeNodeListeners(cur);
        ui.doc.destroy(id);
    }

    fn finalizeNode(doc: *dom.Document, n: *dom.Node) void {
        style_mod.finalizeNode(doc, n);
        layout.finalizeNode(doc, n);
    }

    pub fn destroy(ui: *Ui) void {
        const gpa = ui.gpa;
        ui.doc.deinit();
        ui.styles.deinit();
        ui.layout.deinit();
        ui.ix.deinit();
        ui.animator.deinit();
        ui.images.deinit();
        ui.dl.deinit();
        if (ui.owns_fonts) ui.fonts.deinit();
        gpa.destroy(ui);
    }

    /// Replace the body content with parsed HTML (styles in <style> are added).
    pub fn setHtml(ui: *Ui, src: []const u8) !void {
        const body = try html.ensureBody(ui.doc);
        var c = ui.doc.node(body).first_child;
        while (c != dom.null_id) {
            const next = ui.doc.node(c).next;
            ui.destroyNode(c);
            c = next;
        }
        try html.parseInto(ui.doc, ui.doc.root, src, .{});
    }

    /// The built-in component stylesheet (eb-* classes; see src/components).
    pub const components_css = @embedFile("components/electrobun.css");

    pub fn useComponents(ui: *Ui) !void {
        _ = try ui.doc.addStylesheet(components_css);
    }

    pub fn addCss(ui: *Ui, css: []const u8) !void {
        _ = try ui.doc.addStylesheet(css);
    }

    pub fn resize(ui: *Ui, w: f32, h: f32, scale: f32) void {
        if (w == ui.width and h == ui.height and scale == ui.scale) return;
        ui.width = w;
        ui.height = h;
        ui.scale = scale;
        ui.doc.needs_paint = true;
        const root = ui.doc.documentElement();
        if (root != dom.null_id) ui.doc.markLayoutDirty(root);
    }

    pub fn setColorScheme(ui: *Ui, dark: bool) void {
        ui.dark = dark;
    }

    /// Advance the clock (seconds). Drives caret blinking and animations.
    pub fn tick(ui: *Ui, now: f64) void {
        ui.now = now;
        ui.ix.now = now;
        if (ui.doc.focused != dom.null_id and ui.ix.edits.contains(ui.doc.focused)) {
            const vis = ui.ix.caretVisible();
            if (vis != ui.paint_hooks.caret_visible) {
                ui.paint_hooks.caret_visible = vis;
                ui.doc.needs_paint = true;
            }
        }
    }

    /// Whether the host should keep producing frames (caret blink, animations).
    pub fn wantsFrames(ui: *const Ui) bool {
        if (ui.animator.active()) return true;
        return ui.doc.focused != dom.null_id and ui.ix.edits.contains(ui.doc.focused);
    }

    /// Run style, layout and paint as needed. Returns true if a new frame is ready.
    pub fn update(ui: *Ui) !bool {
        ui.styles.setEnv(.{ .width = ui.width, .height = ui.height, .dark = ui.dark, .reduced_motion = ui.reduced_motion, .resolution = ui.scale });
        ui.animator.now = if (ui.animator.now == 0) ui.now else ui.animator.now;
        ui.animator.reduced_motion = ui.reduced_motion;
        _ = try ui.styles.update(ui.doc);
        ui.animator.apply(ui.now);
        _ = try ui.layout.run(ui.width, ui.height);
        if (!ui.doc.needs_paint) return false;
        var painter = paint.Painter{ .doc = ui.doc, .L = &ui.layout, .dl = &ui.dl, .hooks = ui.paint_hooks, .scale = ui.scale };
        try painter.paint();
        ui.doc.needs_paint = false;
        ui.frame_dirty = true;
        return true;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testUi(markup: []const u8) !*Ui {
    const ui = try Ui.create(std.testing.allocator, .{ .fonts = try font.MockBackend.create(std.testing.allocator) });
    ui.owns_fonts = true;
    try ui.setHtml(markup);
    ui.resize(400, 300, 1);
    _ = try ui.update();
    return ui;
}

const Counter = struct {
    n: u32 = 0,
    last: events.EventType = .click,
    fn cb(ctx: ?*anyopaque, ev: *events.Event) void {
        const c: *Counter = @ptrCast(@alignCast(ctx.?));
        c.n += 1;
        c.last = ev.type;
    }
};

test "hover restyles and click dispatches" {
    const ui = try testUi(
        \\<style>body { margin: 0 } .b { width: 100px; height: 40px; background: #111 } .b:hover { background: #222 }</style>
        \\<div class="b" id="b"><span id="s">x</span></div>
    );
    defer ui.destroy();
    const b = try style_mod.querySelector(ui.doc, ui.doc.root, "#b");
    var counter = Counter{};
    _ = try ui.ix.addListener(b, .click, Counter.cb, &counter);
    ui.ix.pointerMove(10, 10, .{});
    _ = try ui.update();
    try std.testing.expect(style_mod.of(ui.doc, b).background_color.eql(geom.Color.hex(0x222222)));
    ui.ix.pointerDown(10, 10, 0, .{});
    ui.ix.pointerUp(10, 10, 0, .{});
    try std.testing.expectEqual(@as(u32, 1), counter.n);
    ui.ix.pointerMove(300, 200, .{});
    _ = try ui.update();
    try std.testing.expect(style_mod.of(ui.doc, b).background_color.eql(geom.Color.hex(0x111111)));
}

test "paint-only restyles keep cached inline style pointers valid" {
    const ui = try testUi(
        \\<style>body { margin: 0 } .b { color: #111 } .b:hover { color: #222 } .b::after { content: "!" } .b:hover::after { color: #333 }</style>
        \\<div class="b" id="b">hello <span>world</span></div>
    );
    defer ui.destroy();
    const b = try style_mod.querySelector(ui.doc, ui.doc.root, "#b");
    for (0..4) |i| {
        if (i % 2 == 0) ui.ix.pointerMove(5, 5, .{}) else ui.ix.pointerMove(390, 290, .{});
        _ = try ui.update();
        const il = layout.boxOfNode(ui.doc.node(b)).?.inline_layout.?;
        for (il.frags) |f| {
            if (f.kind != .text or f.item.pseudo != .none) continue;
            try std.testing.expect(f.style == style_mod.of(ui.doc, f.item.node));
        }
    }
    try std.testing.expect(style_mod.of(ui.doc, b).color.eql(geom.Color.hex(0x111111)));
}

test "checkbox, label and typing" {
    const ui = try testUi(
        \\<style>body { margin: 0; font-size: 10px }</style>
        \\<label id="l"><input type="checkbox" id="c"> Remember</label><br><input id="t" value="ab">
    );
    defer ui.destroy();
    const c = try style_mod.querySelector(ui.doc, ui.doc.root, "#c");
    const t = try style_mod.querySelector(ui.doc, ui.doc.root, "#t");
    // click the checkbox
    ui.ix.click(c, 0, 0, .{}, 1);
    try std.testing.expect(ui.doc.node(c).state.checked);
    // clicking the label toggles it back
    ui.ix.click(try style_mod.querySelector(ui.doc, ui.doc.root, "#l"), 0, 0, .{}, 1);
    try std.testing.expect(!ui.doc.node(c).state.checked);
    // focus the text input and type
    ui.ix.focus(t, false);
    ui.ix.textInput("cd");
    try std.testing.expectEqualStrings("abcd", ui.ix.value(t));
    ui.ix.keyDown("ArrowLeft", .{});
    ui.ix.keyDown("Backspace", .{});
    try std.testing.expectEqualStrings("abd", ui.ix.value(t));
    ui.ix.keyDown("a", .{ .meta = true, .ctrl = true });
    ui.ix.textInput("z");
    try std.testing.expectEqualStrings("z", ui.ix.value(t));
    ui.ix.keyDown("z", .{ .meta = true, .ctrl = true });
    try std.testing.expectEqualStrings("abd", ui.ix.value(t));
    _ = try ui.update();
    // tab navigation goes checkbox -> text input
    ui.ix.blur();
    ui.ix.keyDown("Tab", .{});
    try std.testing.expectEqual(c, ui.doc.focused);
    ui.ix.keyDown("Tab", .{});
    try std.testing.expectEqual(t, ui.doc.focused);
}

test "wheel scrolls overflow containers" {
    const ui = try testUi(
        \\<style>body { margin: 0 } .s { height: 100px; overflow: auto } .c { height: 500px }</style>
        \\<div class="s" id="s"><div class="c"></div></div>
    );
    defer ui.destroy();
    const s = try style_mod.querySelector(ui.doc, ui.doc.root, "#s");
    ui.ix.wheel(10, 10, 0, 50, .{});
    try std.testing.expectEqual(@as(f32, 50), ui.doc.node(s).scroll_y);
    ui.ix.wheel(10, 10, 0, 1000, .{});
    try std.testing.expectEqual(@as(f32, 400), ui.doc.node(s).scroll_y);
}

test "css transitions and keyframes" {
    const ui = try testUi(
        \\<style>body { margin: 0 } .b { width: 100px; height: 40px; opacity: 1; transition: opacity 1s linear, width 1s linear }
        \\ .b.off { opacity: 0; width: 200px }
        \\ @keyframes pulse { from { opacity: 1 } 50% { opacity: .2 } to { opacity: 1 } }
        \\ .k { animation: pulse 2s linear infinite; width: 10px; height: 10px }</style>
        \\<div class="b" id="b"></div><div class="k" id="k"></div>
    );
    defer ui.destroy();
    const b = try style_mod.querySelector(ui.doc, ui.doc.root, "#b");
    const k = try style_mod.querySelector(ui.doc, ui.doc.root, "#k");
    try ui.doc.setAttribute(b, "class", "b off");
    ui.tick(0.0);
    _ = try ui.update();
    ui.tick(0.5);
    _ = try ui.update();
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), style_mod.of(ui.doc, b).opacity, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 150), layout.boxOfNode(ui.doc.node(b)).?.w, 0.5);
    try std.testing.expect(ui.wantsFrames());
    // keyframes at t=0.5s of 2s: halfway to the 50% keyframe -> 0.6
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), style_mod.of(ui.doc, k).opacity, 0.02);
    // interrupt: go back; starts from the current value 0.5
    try ui.doc.setAttribute(b, "class", "b");
    _ = try ui.update();
    ui.tick(1.0);
    _ = try ui.update();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), style_mod.of(ui.doc, b).opacity, 0.01);
    ui.tick(2.0);
    _ = try ui.update();
    try std.testing.expectApproxEqAbs(@as(f32, 100), layout.boxOfNode(ui.doc.node(b)).?.w, 0.5);
}

test "springs" {
    const ui = try testUi(
        \\<style>body { margin: 0 } .b { width: 10px; height: 10px }</style><div class="b" id="b"></div>
    );
    defer ui.destroy();
    const b = try style_mod.querySelector(ui.doc, ui.doc.root, "#b");
    try ui.animator.springTo(b, .opacity, .{ .num = 0 }, .{});
    var t: f64 = 0;
    while (t < 3) : (t += 1.0 / 60.0) {
        ui.tick(t);
        _ = try ui.update();
    }
    try std.testing.expect(!ui.animator.active());
    try std.testing.expectApproxEqAbs(@as(f32, 0), style_mod.of(ui.doc, b).opacity, 0.001);
    // the resting value survives restyles
    ui.doc.markStyleDirty(b);
    _ = try ui.update();
    try std.testing.expectApproxEqAbs(@as(f32, 0), style_mod.of(ui.doc, b).opacity, 0.001);
}

test "select popup" {
    const ui = try testUi(
        \\<style>body { margin: 0 }</style><select id="s"><option value="a">Alpha</option><option value="b" selected>Beta</option><option value="c">Gamma</option></select>
    );
    defer ui.destroy();
    const sel = try style_mod.querySelector(ui.doc, ui.doc.root, "#s");
    var counter = Counter{};
    _ = try ui.ix.addListener(sel, .change, Counter.cb, &counter);
    try std.testing.expectEqualStrings("b", ui.ix.value(sel));
    ui.ix.click(sel, 0, 0, .{}, 1);
    try std.testing.expect(ui.ix.popup != 0);
    _ = try ui.update();
    ui.ix.keyDown("ArrowDown", .{});
    ui.ix.keyDown("Enter", .{});
    try std.testing.expectEqual(@as(dom.NodeId, 0), ui.ix.popup);
    try std.testing.expectEqualStrings("c", ui.ix.value(sel));
    try std.testing.expectEqual(@as(u32, 1), counter.n);
    // clicking an option in the popup
    ui.ix.click(sel, 0, 0, .{}, 1);
    _ = try ui.update();
    const first = ui.doc.node(ui.ix.popup).first_child;
    const b = layout.boxOfNode(ui.doc.node(first)).?;
    const o = ui.ix.contentOrigin(first).?;
    _ = b;
    ui.ix.pointerDown(o[0] + 2, o[1] + 2, 0, .{});
    ui.ix.pointerUp(o[0] + 2, o[1] + 2, 0, .{});
    try std.testing.expectEqualStrings("a", ui.ix.value(sel));
}

