const ig = @import("gui_backend").ig;

var show_demo: bool = true;
var counter: i32 = 0;
var slider_val: f32 = 0.5;
var checkbox_val: bool = false;
var input_buf: [128]u8 = [_]u8{0} ** 128;
var combo_current: i32 = 0;
var color: [3]f32 = .{ 0.4, 0.7, 1.0 };
var progress: f32 = 0.0;
var radio_choice: i32 = 0;

pub fn drawGui(g: anytype) void {
    _ = g;

    // Animate progress bar
    progress += 0.002;
    if (progress > 1.0) progress = 0.0;

    if (ig.igBegin("GUI Plugin Test", null, 0)) {
        ig.igTextUnformatted("Hello from the ImGui plugin system!");
        ig.igTextUnformatted("Three-layer separation: backend + plugin + bridge");
        ig.igSeparator();

        // --- Buttons ---
        ig.igSpacing();
        ig.igTextUnformatted("Buttons");
        if (ig.igButton("Click me!")) {
            counter += 1;
        }
        ig.igSameLine();
        if (ig.igButton("Reset")) {
            counter = 0;
        }
        ig.igSameLine();
        ig.igText("Counter: %d", counter);

        ig.igSpacing();
        ig.igSeparator();
        ig.igSpacing();

        // --- Slider ---
        ig.igTextUnformatted("Slider");
        _ = ig.igSliderFloat("Value", &slider_val, 0.0, 1.0);

        // --- Progress bar ---
        ig.igSpacing();
        ig.igTextUnformatted("Progress Bar");
        ig.igProgressBar(progress, .{ .x = -1, .y = 0 }, null);

        ig.igSpacing();
        ig.igSeparator();
        ig.igSpacing();

        // --- Checkbox ---
        ig.igTextUnformatted("Checkbox");
        _ = ig.igCheckbox("Enable feature", &checkbox_val);
        if (checkbox_val) {
            ig.igSameLine();
            ig.igTextColored(.{ .x = 0, .y = 1, .z = 0, .w = 1 }, "ON");
        }

        // --- Radio buttons ---
        ig.igSpacing();
        ig.igTextUnformatted("Radio Buttons");
        if (ig.igRadioButtonIntPtr("Raylib", &radio_choice, 0)) {}
        ig.igSameLine();
        if (ig.igRadioButtonIntPtr("Sokol", &radio_choice, 1)) {}
        ig.igSameLine();
        if (ig.igRadioButtonIntPtr("SDL", &radio_choice, 2)) {}

        ig.igSpacing();
        ig.igSeparator();
        ig.igSpacing();

        // --- Text input ---
        ig.igTextUnformatted("Text Input");
        _ = ig.igInputText("Name", &input_buf, input_buf.len, 0);

        // --- Combo box ---
        ig.igSpacing();
        ig.igTextUnformatted("Combo Box");
        _ = ig.igCombo("Backend", &combo_current, "Raylib\x00Sokol\x00SDL\x00bgfx\x00wgpu\x00");

        ig.igSpacing();
        ig.igSeparator();
        ig.igSpacing();

        // --- Color picker ---
        ig.igTextUnformatted("Color Picker");
        _ = ig.igColorEdit3("Color", &color, 0);

        ig.igSpacing();
        ig.igSeparator();
        ig.igSpacing();

        // --- Collapsing header ---
        if (ig.igCollapsingHeader("More Info", 0)) {
            ig.igTextUnformatted("This window demonstrates the GUI plugin system.");
            ig.igBulletText("Backend and GUI version independently");
            ig.igBulletText("Bridge adapter is a thin glue layer");
            ig.igBulletText("No changes to engine or labelle-core");
        }

        ig.igSpacing();
        _ = ig.igCheckbox("Show Demo Window", &show_demo);
    }
    ig.igEnd();

    if (show_demo) {
        ig.igShowDemoWindow(&show_demo);
    }
}
