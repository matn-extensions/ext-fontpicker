module matn.ui.shell.fontpicker;

import core.stdc.stdio : printf;
import core.stdc.string : strlen;
import std.algorithm : max, min, clamp, canFind, sort, endsWith;
import std.conv : to;
import std.file : exists;
import std.process : executeShell;
import std.string : strip, toLower, splitLines, indexOf, toStringz;
import std.utf : toUTF8;

import matn.platform.sdl;
import matn.platform.font;
import matn.ui.grid.cell;
import matn.ui.grid.grid;
import matn.ui.grid.renderer;
import matn.extension.base;

/// Discovered font information
struct FontInfo
{
    string family;
    string path;
    string style;
}

/// Rendering and styling context passed to FontPickerExtension
struct FontPickerContext
{
    int gridCols;
    int gridRows;
    Color bg;
    Color barBg;
    Color text;
    Color muted;
    Color accent;
    Color border;
    Color activeLine;
    bool isLight = false;
    bool blink = true;
}

/// Interactive font picker window
class FontPickerExtension : Extension
{
    bool visible = false;
    string query = "";
    int selectedIndex = 0;
    int scrollOffset = 0;
    int hoveredIndex = -1;

    FontInfo[] allFonts;
    FontInfo[] filteredFonts;
    string activeFontPath = "";

    // Callback when user confirms font selection
    void delegate(string fontPath) onFontSelected;

    // Layout geometry for hit testing
    int modalX;
    int modalY;
    int modalW;
    int modalH;
    int contentStartY;
    int visibleRowsCount;

    struct ClickableRow
    {
        int fontIndex;
        int row;
        int leftCol;
        int rightCol;
    }
    private ClickableRow[] clickRows;

    this()
    {
        super(ExtensionManifest(
            "matn.fontpicker",
            "Font Picker",
            "1.0.0",
            "Matn Core",
            "Monospace font selector with search and live typeface selection",
            true
        ));
        // Lazy font discovery: fontconfig fc-list is deferred until open()
    }

    ~this()
    {
    }

    override protected void onActivate()
    {
        if (_context)
        {
            _context.registerCommand(ExtensionCommand(
                "matn.fontpicker.open",
                "Font Family",
                "Appearance",
                "",
                { toggle(); }
            ));
        }
    }

    void ensureDiscovered()
    {
        if (allFonts.length == 0)
        {
            discoverFonts();
            if (activeFontPath.length > 0)
                setActiveFont(activeFontPath);
        }
    }

    void open()
    {
        ensureDiscovered();
        visible = true;
        query = "";
        updateFilter();
        ensureValidSelection();
    }

    void close()
    {
        visible = false;
    }

    void toggle()
    {
        if (visible) close();
        else open();
    }

    void clearTextures()
    {
    }

    string getActiveFamily() const
    {
        if (allFonts.length > 0)
        {
            foreach (ref f; allFonts)
            {
                if (f.path == activeFontPath)
                    return f.family;
            }
        }
        if (activeFontPath.length > 0)
        {
            import std.path : baseName, stripExtension;
            return stripExtension(baseName(activeFontPath));
        }
        return "Default";
    }

    void setActiveFont(string path)
    {
        activeFontPath = path;
        if (filteredFonts.length > 0)
        {
            // Move selection to active font if found
            foreach (i, ref f; filteredFonts)
            {
                if (f.path == path)
                {
                    selectedIndex = cast(int) i;
                    ensureValidSelection();
                    break;
                }
            }
        }
    }

    private void discoverFonts()
    {
        allFonts = [];

        // 1. Query fontconfig if available
        try
        {
            auto res = executeShell("fc-list : file family style spacing");
            if (res.status == 0 && res.output.length > 0)
            {
                parseFcList(res.output);
            }
        }
        catch (Exception e)
        {
            // Ignore failure, proceed to fallbacks
        }

        // 2. Ensure default system candidates are present
        string[2][] candidates = [
            ["MonoLisa", "/home/khozy/.fonts/monalisa-font/MonoLisa-Regular.ttf"],
            ["JetBrains Mono", "/home/khozy/.local/share/fonts/JetBrainsMonoNerdFont-Regular.ttf"],
            ["JetBrains Mono Mono", "/home/khozy/.local/share/fonts/JetBrainsMonoNerdFontMono-Regular.ttf"],
            ["Fira Code", "/usr/share/fonts/truetype/firacode/FiraCode-Medium.ttf"],
            ["Hack", "/home/khozy/.fonts/Hack/HackNerdFont-Regular.ttf"],
            ["Iosevka", "/home/khozy/.local/share/fonts/IosevkaNerdFont-Medium.ttf"],
            ["DejaVu Sans Mono", "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"],
            ["Liberation Mono", "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf"],
            ["Martian Mono", "/home/khozy/.local/share/fonts/MartianMonoNerdFont-Medium.ttf"],
        ];

        foreach (c; candidates)
        {
            string fam = c[0];
            string path = c[1];
            if (exists(path))
            {
                bool alreadyHas = false;
                foreach (ref f; allFonts)
                {
                    if (f.family == fam || f.path == path)
                    {
                        alreadyHas = true;
                        break;
                    }
                }
                if (!alreadyHas)
                {
                    allFonts ~= FontInfo(fam, path, "Regular");
                }
            }
        }

        // Sort alphabetically by family name
        sort!((a, b) => a.family.toLower() < b.family.toLower())(allFonts);
        updateFilter();
    }

    private void parseFcList(string output)
    {
        struct FontEntry
        {
            string path;
            int score;
            string style;
        }
        FontEntry[string] fontMap;

        foreach (line; output.splitLines())
        {
            if (line.length == 0) continue;
            auto colon1 = line.indexOf(':');
            if (colon1 == -1) continue;

            string path = line[0 .. colon1].strip();
            string rest = line[colon1 + 1 .. $];

            auto colon2 = rest.indexOf(':');
            string familyPart = (colon2 != -1) ? rest[0 .. colon2].strip() : rest.strip();
            string metaPart = (colon2 != -1) ? rest[colon2 + 1 .. $] : "";

            // First family in comma-separated list
            auto comma = familyPart.indexOf(',');
            string fam = (comma != -1) ? familyPart[0 .. comma].strip() : familyPart;

            // Remove escaped backslashes from fontconfig, e.g. "MonoLisa\-Regular"
            string cleanFam = "";
            foreach (ch; fam)
            {
                if (ch != '\\') cleanFam ~= ch;
            }
            fam = cleanFam;

            string style = "";
            string spacing = "";

            if (metaPart.length > 0)
            {
                // Parse properties e.g. "style=Regular:spacing=100"
                size_t pStart = 0;
                while (pStart < metaPart.length)
                {
                    size_t pEnd = metaPart.indexOf(':', pStart);
                    if (pEnd == -1) pEnd = metaPart.length;
                    string prop = metaPart[pStart .. pEnd].strip();
                    pStart = pEnd + 1;

                    if (prop.length > 6 && prop[0 .. 6] == "style=")
                        style = prop[6 .. $];
                    else if (prop.length > 8 && prop[0 .. 8] == "spacing=")
                        spacing = prop[8 .. $];
                }
            }

            // Monospace filter
            if (!isMonospace(fam, path, spacing))
                continue;

            // File validity
            if (!path.endsWith(".ttf") && !path.endsWith(".otf") && !path.endsWith(".ttc"))
                continue;
            if (!exists(path))
                continue;

            int score = scoreStyle(style, path);
            if (fam !in fontMap || score > fontMap[fam].score)
            {
                fontMap[fam] = FontEntry(path, score, style);
            }
        }

        foreach (fam, entry; fontMap)
        {
            allFonts ~= FontInfo(fam, entry.path, entry.style);
        }
    }

    private static bool isMonospace(string family, string path, string spacing)
    {
        if (spacing == "100") return true;
        string f = family.toLower();
        string p = path.toLower();
        if (f.canFind("mathjax") || f.canFind("emoji") || f.canFind("signwriting") || f.canFind("music"))
            return false;

        string[] keywords = [
            "mono", "code", "hack", "courier", "consolas", "iosevka", "terminus",
            "typewriter", "fixed", "caskaydia", "fantasque", "hurmit"
        ];
        foreach (kw; keywords)
        {
            if (f.canFind(kw) || p.canFind(kw))
                return true;
        }
        return false;
    }

    private static int scoreStyle(string style, string path)
    {
        int score = 0;
        string s = style.toLower();
        string p = path.toLower();

        if (s.canFind("italic") || s.canFind("oblique") || p.canFind("italic")) score -= 20;
        if (s.canFind("bold") || p.canFind("bold")) score -= 5;
        if (s.canFind("regular") || s.canFind("book")) score += 20;
        else if (s.canFind("roman")) score += 15;
        else if (s.canFind("medium")) score += 10;
        if (s.canFind("light") || s.canFind("thin")) score -= 8;

        return score;
    }

    void updateFilter()
    {
        if (query.strip().length == 0)
        {
            filteredFonts = allFonts.dup;
        }
        else
        {
            string q = query.toLower();
            filteredFonts = [];
            foreach (ref f; allFonts)
            {
                if (f.family.toLower().canFind(q))
                    filteredFonts ~= f;
            }
        }
        ensureValidSelection();
    }

    void ensureValidSelection()
    {
        if (filteredFonts.length == 0)
        {
            selectedIndex = 0;
            return;
        }
        selectedIndex = clamp(selectedIndex, 0, cast(int) filteredFonts.length - 1);
        ensureVisible(selectedIndex);
    }

    void ensureVisible(int itemIdx)
    {
        if (visibleRowsCount <= 0) return;
        if (itemIdx < scrollOffset)
            scrollOffset = itemIdx;
        else if (itemIdx >= scrollOffset + visibleRowsCount)
            scrollOffset = itemIdx - visibleRowsCount + 1;
        scrollOffset = clamp(scrollOffset, 0, max(0, cast(int) filteredFonts.length - visibleRowsCount));
    }

    void moveSelection(int delta)
    {
        if (filteredFonts.length == 0) return;
        selectedIndex = clamp(selectedIndex + delta, 0, cast(int) filteredFonts.length - 1);
        ensureVisible(selectedIndex);
    }

    void applySelected()
    {
        if (selectedIndex >= 0 && selectedIndex < filteredFonts.length)
        {
            auto f = filteredFonts[selectedIndex];
            activeFontPath = f.path;
            if (onFontSelected)
                onFontSelected(f.path);
            close();
        }
    }

    bool handleKeyDown(uint key, ushort mod, FontPickerContext ctx)
    {
        if (!visible) return false;

        bool isCtrl = (mod & SDL_KMOD_CTRL) != 0;
        bool isShift = (mod & SDL_KMOD_SHIFT) != 0;

        if (key == SDLK_ESCAPE || (isCtrl && (key == 'f' || key == 'F')))
        {
            close();
            return true;
        }
        else if (key == SDLK_UP)
        {
            moveSelection(-1);
            return true;
        }
        else if (key == SDLK_DOWN)
        {
            moveSelection(1);
            return true;
        }
        else if (key == SDLK_PAGEUP)
        {
            moveSelection(-5);
            return true;
        }
        else if (key == SDLK_PAGEDOWN)
        {
            moveSelection(5);
            return true;
        }
        else if (key == SDLK_HOME)
        {
            selectedIndex = 0;
            ensureValidSelection();
            return true;
        }
        else if (key == SDLK_END)
        {
            if (filteredFonts.length > 0)
                selectedIndex = cast(int) filteredFonts.length - 1;
            ensureValidSelection();
            return true;
        }
        else if (key == SDLK_RETURN || key == 0x40000058)
        {
            applySelected();
            return true;
        }
        else if (key == SDLK_BACKSPACE)
        {
            if (query.length > 0)
            {
                query = query[0 .. $ - 1];
                updateFilter();
            }
            return true;
        }

        return true;
    }

    bool handleTextInput(string text)
    {
        if (!visible || text.length == 0) return false;
        query ~= text;
        updateFilter();
        return true;
    }

    bool handleMouseMove(int col, int row)
    {
        if (!visible) return false;

        int oldHover = hoveredIndex;
        hoveredIndex = -1;

        foreach (ref cr; clickRows)
        {
            if (row == cr.row && col >= cr.leftCol && col < cr.rightCol)
            {
                hoveredIndex = cr.fontIndex;
                break;
            }
        }

        return (oldHover != hoveredIndex);
    }

    bool handleMouseDown(int col, int row, FontPickerContext ctx)
    {
        if (!visible) return false;

        // Click outside closes modal
        if (col < modalX || col >= modalX + modalW || row < modalY || row >= modalY + modalH)
        {
            close();
            return true;
        }

        // Click on [x] close button at top right
        if (row == modalY && col >= modalX + modalW - 3 && col < modalX + modalW)
        {
            close();
            return true;
        }

        // Click on a font row
        foreach (ref cr; clickRows)
        {
            if (row == cr.row && col >= cr.leftCol && col < cr.rightCol)
            {
                if (selectedIndex == cr.fontIndex)
                {
                    applySelected();
                }
                else
                {
                    selectedIndex = cr.fontIndex;
                }
                return true;
            }
        }

        return true;
    }

    bool handleMouseWheel(int wheelY)
    {
        if (!visible) return false;
        if (wheelY > 0)
            moveSelection(-2);
        else if (wheelY < 0)
            moveSelection(2);
        return true;
    }

    void render(GlyphGrid grid, FontPickerContext ctx)
    {
        if (!visible) return;

        clickRows = [];

        // Dimensions
        modalW = min(76, max(52, ctx.gridCols - 4));
        modalH = min(26, max(18, ctx.gridRows - 2));

        modalX = max(0, (ctx.gridCols - modalW) / 2);
        modalY = max(0, (ctx.gridRows - modalH) / 2);

        bool isLight = ctx.isLight || ctx.bg.isLight;
        Color modalBg = ctx.barBg;
        Color headerBg = isLight ? ctx.barBg.darken(6) : ctx.barBg.lighten(6);
        Color selRowBg = ctx.activeLine;
        Color hoverRowBg = ctx.activeLine.blend(ctx.barBg, 0.45f);

        // Fill modal area
        grid.fillRect(modalX, modalY, modalW, modalH, ' ', CellStyle(ctx.text, modalBg));

        // 1. Title Header (Row 0 - clean sublabel title like ACTIONS)
        grid.fillRect(modalX, modalY, modalW, 1, ' ', CellStyle(ctx.text, modalBg));
        grid.putString(modalX + 2, modalY, "FONT FAMILY"d, CellStyle(ctx.muted, modalBg, CellAttr.bold));

        // Close button [x] at top right without gaps
        int closeCol = modalX + modalW - 3;
        grid.putString(closeCol, modalY, "[x]"d, CellStyle(ctx.muted, modalBg));

        string countStr = to!string(filteredFonts.length) ~ " fonts";
        int countCol = closeCol - 2 - cast(int) countStr.length;
        grid.putString(countCol, modalY, to!dstring(countStr), CellStyle(ctx.muted, modalBg));

        // 2. Filter Search Bar (Row 1)
        int searchRow = modalY + 1;
        grid.fillRect(modalX, searchRow, modalW, 1, ' ', CellStyle(ctx.text, modalBg));
        grid.putString(modalX + 2, searchRow, "   Filter: "d, CellStyle(ctx.accent, modalBg));

        int queryCol = modalX + 13;
        if (query.length > 0)
        {
            grid.putString(queryCol, searchRow, to!dstring(query), CellStyle(ctx.text, modalBg, CellAttr.bold));
            int cursorCol = queryCol + cast(int) query.length;
            if (ctx.blink && cursorCol >= 0 && cursorCol < grid.cols && searchRow >= 0 && searchRow < grid.rows)
            {
                auto cell = &grid.cells[searchRow * grid.cols + cursorCol];
                cell.style.attrs |= CellAttr.negative;
            }
        }
        else
        {
            grid.putString(queryCol, searchRow, "Type to search..."d, CellStyle(ctx.muted, modalBg));
            int cursorCol = queryCol;
            if (ctx.blink && cursorCol >= 0 && cursorCol < grid.cols && searchRow >= 0 && searchRow < grid.rows)
            {
                auto cell = &grid.cells[searchRow * grid.cols + cursorCol];
                cell.style.attrs |= CellAttr.negative;
            }
        }

        // 3. Font List Area
        contentStartY = modalY + 2;
        visibleRowsCount = max(1, modalH - 2);

        foreach (slot; 0 .. visibleRowsCount)
        {
            int fontIdx = scrollOffset + slot;
            int r = contentStartY + slot;

            if (fontIdx >= filteredFonts.length)
            {
                grid.fillRect(modalX + 1, r, modalW - 2, 1, ' ', CellStyle(ctx.text, modalBg));
                continue;
            }

            auto f = filteredFonts[fontIdx];
            bool isSelected = (fontIdx == selectedIndex);
            bool isHovered = (fontIdx == hoveredIndex);
            bool isActive = (f.path == activeFontPath);

            Color rowBg = isSelected ? selRowBg : (isHovered ? hoverRowBg : modalBg);
            Color labelFg = isSelected ? ctx.accent : ctx.text;

            grid.fillRect(modalX + 1, r, modalW - 2, 1, ' ', CellStyle(labelFg, rowBg));

            // Active indicator on right
            if (isActive)
            {
                dstring actTag = " ● Active "d;
                int actCol = modalX + modalW - 2 - cast(int) actTag.length;
                Color actFg = isLight ? Color(30, 140, 70, 255) : Color(80, 250, 123, 255);
                grid.putString(actCol, r, actTag, CellStyle(actFg, rowBg, CellAttr.bold));
            }

            grid.putString(modalX + 2, r, to!dstring(f.family), CellStyle(labelFg, rowBg, isSelected ? CellAttr.bold : CellAttr.none));

            clickRows ~= ClickableRow(fontIdx, r, modalX + 1, modalX + modalW - 1);
        }
    }

    void renderReal(SDL_Renderer* renderer, FontEngine fontEngine, FontPickerContext ctx, float padX, float padY)
    {
        if (!visible) return;

        float rx = padX + modalX * fontEngine.charWidth;
        float ry = padY + modalY * fontEngine.lineHeight;
        float rw = modalW * fontEngine.charWidth;
        float rh = modalH * fontEngine.lineHeight;

        // Real smooth vector scrollbar
        float trackX = rx + rw - 6.0f;
        float trackY = ry + 2 * fontEngine.lineHeight + 2.0f;
        float trackH = (modalH - 2) * fontEngine.lineHeight - 4.0f;
        drawRealScrollbar(renderer, trackX, trackY, 4.0f, trackH,
                          cast(int) filteredFonts.length, visibleRowsCount, scrollOffset,
                          ctx.accent, Color(ctx.border.r, ctx.border.g, ctx.border.b, 60));
    }
}
