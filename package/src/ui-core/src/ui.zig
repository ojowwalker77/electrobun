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
    paint_hooks: paint.Hooks = .{},
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
        };
        return ui;
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
            ui.doc.destroy(c);
            c = next;
        }
        try html.parseInto(ui.doc, ui.doc.root, src, .{});
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

    /// Run style, layout and paint as needed. Returns true if a new frame is ready.
    pub fn update(ui: *Ui) !bool {
        ui.styles.setEnv(.{ .width = ui.width, .height = ui.height, .dark = ui.dark, .reduced_motion = ui.reduced_motion, .resolution = ui.scale });
        _ = try ui.styles.update(ui.doc);
        _ = try ui.layout.run(ui.width, ui.height);
        if (!ui.doc.needs_paint) return false;
        var painter = paint.Painter{ .doc = ui.doc, .L = &ui.layout, .dl = &ui.dl, .hooks = ui.paint_hooks, .scale = ui.scale };
        try painter.paint();
        ui.doc.needs_paint = false;
        ui.frame_dirty = true;
        return true;
    }
};
