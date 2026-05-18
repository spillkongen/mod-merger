using System;
using System.Collections.Generic;
using System.Drawing;
using System.Reflection;
using System.Windows.Forms;

public class GlassLogView : Panel
{
    Panel _content;
    Panel _tail;
    bool _ready;
    readonly List<KeyValuePair<string, Color>> _lines = new List<KeyValuePair<string, Color>>();
    readonly Font _font;
    const int Pad = 8;
    const int LineGap = 3;
    const int BottomSlack = 56;
    const int MeasureFudge = 6;
    readonly int _tintAlpha = 70;
    static readonly Color TextBack = Color.Transparent;

    static TextFormatFlags LineFlags
    {
        get
        {
            return TextFormatFlags.Left | TextFormatFlags.Top | TextFormatFlags.WordBreak |
                   TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding;
        }
    }

    public int LineCount { get { return _lines.Count; } }

    public GlassLogView()
    {
        AutoScroll = true;
        BackColor = Color.FromArgb(24, 18, 12);
        _font = new Font("Consolas", 9f, FontStyle.Regular);

        _content = new Panel();
        _content.Location = Point.Empty;
        _content.BackColor = Color.FromArgb(24, 18, 12);
        _content.TabStop = false;
        EnableDoubleBuffer(_content);
        _content.Paint += Content_Paint;

        _tail = new Panel();
        _tail.Size = new Size(1, 1);
        _tail.BackColor = Color.FromArgb(24, 18, 12);
        _content.Controls.Add(_tail);

        Controls.Add(_content);
        EnableDoubleBuffer(this);

        _ready = true;
        LayoutContent();
    }

    static void EnableDoubleBuffer(Control c)
    {
        if (c == null) return;
        try
        {
            typeof(Control).InvokeMember(
                "DoubleBuffered",
                BindingFlags.SetProperty | BindingFlags.Instance | BindingFlags.NonPublic,
                null, c, new object[] { true });
        }
        catch { }
    }

    int TextAreaWidth()
    {
        int w = ClientSize.Width - SystemInformation.VerticalScrollBarWidth - (Pad * 2);
        return Math.Max(20, w);
    }

    int ContentPanelWidth()
    {
        return Math.Max(40, ClientSize.Width - SystemInformation.VerticalScrollBarWidth);
    }

    int MeasureLineHeight(Graphics g, string text, int width)
    {
        if (string.IsNullOrEmpty(text)) return _font.Height + LineGap + MeasureFudge;
        var sz = TextRenderer.MeasureText(g, text, _font, new Size(width, int.MaxValue), LineFlags);
        return Math.Max((int)Math.Ceiling(_font.GetHeight(g)) + LineGap, sz.Height + MeasureFudge);
    }

    int MeasureContentHeight(Graphics g, int textWidth)
    {
        int y = Pad;
        foreach (var kv in _lines)
            y += MeasureLineHeight(g, kv.Key, textWidth) + LineGap;
        return y + Pad + BottomSlack;
    }

    void LayoutContent()
    {
        if (!_ready || _content == null) return;

        int panelW = ContentPanelWidth();
        int textW = TextAreaWidth();
        int h = Pad + BottomSlack + _font.Height;

        try
        {
            _content.Width = panelW;
            using (Graphics g = _content.CreateGraphics())
            {
                if (g != null)
                    h = Math.Max(h, MeasureContentHeight(g, textW));
            }
        }
        catch
        {
            h = Math.Max(h, _lines.Count * (_font.Height + LineGap + MeasureFudge) + Pad + BottomSlack);
        }

        if (_content.Height != h)
            _content.Height = h;

        if (_tail != null)
            _tail.Location = new Point(0, Math.Max(0, h - 2));
    }

    void PaintWallpaper(Graphics g, Rectangle bounds)
    {
        if (bounds.Width <= 0 || bounds.Height <= 0) return;

        Form f = FindForm();
        if (f != null && f.BackgroundImage != null)
        {
            Point screen = _content.PointToScreen(Point.Empty);
            Point formPt = f.PointToClient(screen);
            g.DrawImage(
                f.BackgroundImage,
                new Rectangle(-formPt.X, -formPt.Y, f.ClientSize.Width, f.ClientSize.Height));
        }
        else
        {
            using (var fill = new SolidBrush(Color.FromArgb(24, 18, 12)))
                g.FillRectangle(fill, bounds);
        }

        using (var tint = new SolidBrush(Color.FromArgb(_tintAlpha, 14, 10, 6)))
            g.FillRectangle(tint, bounds);
    }

    void Content_Paint(object sender, PaintEventArgs e)
    {
        if (_content == null) return;
        var g = e.Graphics;
        PaintWallpaper(g, _content.ClientRectangle);

        int textW = Math.Max(20, _content.Width - (Pad * 2));
        int y = Pad;
        foreach (var kv in _lines)
        {
            int h = MeasureLineHeight(g, kv.Key, textW);
            var rect = new Rectangle(Pad, y, textW, h);
            TextRenderer.DrawText(g, kv.Key, _font, rect, kv.Value, TextBack, LineFlags);
            y += h + LineGap;
        }
    }

    void ScrollToBottom()
    {
        if (!_ready || _content == null) return;
        LayoutContent();

        try
        {
            if (_tail != null)
                ScrollControlIntoView(_tail);
        }
        catch { }

        try
        {
            if (VerticalScroll.Visible)
                VerticalScroll.Value = VerticalScroll.Maximum;
        }
        catch { }

        int maxY = Math.Max(0, _content.Height - DisplayRectangle.Height);
        AutoScrollPosition = new Point(0, maxY);
        _content.Invalidate(true);
    }

    public void AppendLine(string text, Color color)
    {
        if (text == null) text = string.Empty;
        text = text.TrimEnd('\r', '\n');
        _lines.Add(new KeyValuePair<string, Color>(text, color));
        ScrollToBottom();
    }

    public void ClearLines()
    {
        _lines.Clear();
        LayoutContent();
        _content.Invalidate(true);
        AutoScrollPosition = new Point(0, 0);
    }

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        if (!_ready || _content == null) return;
        LayoutContent();
        _content.Invalidate(true);
    }

    protected override void OnMouseWheel(MouseEventArgs e)
    {
        if (VerticalScroll.Visible)
        {
            int step = (e.Delta > 0) ? -48 : 48;
            int nv = VerticalScroll.Value + step;
            nv = Math.Max(VerticalScroll.Minimum, Math.Min(VerticalScroll.Maximum, nv));
            VerticalScroll.Value = nv;
            var handled = e as HandledMouseEventArgs;
            if (handled != null) handled.Handled = true;
            _content.Invalidate(true);
            return;
        }
        base.OnMouseWheel(e);
    }

    protected override void OnScroll(ScrollEventArgs se)
    {
        base.OnScroll(se);
        if (_content != null) _content.Invalidate(true);
    }
}
