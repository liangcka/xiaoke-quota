// Native.cs —— Claude娘 的少量 C# 辅助代码（由 PowerShell Add-Type 编译，C# 5 语法）
//   WebpFrames : 用 Windows 自带的 WebP 解码器（WIC）读取动画帧，修正通道顺序/预乘，裁边并高质量缩放
//   Win32      : 跟随窗口所需的几个 user32 函数
using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace ClaudeNiang
{
    public sealed class WebpFrames : IDisposable
    {
        private BitmapDecoder _dec;
        private Stream _stream;
        private bool _swapRB;
        private bool _premul;
        private bool _convert;

        public int Count { get; private set; }
        public int SourceWidth { get; private set; }
        public int SourceHeight { get; private set; }
        public string FormatInfo { get; private set; }

        public WebpFrames(string path, bool cacheAll)
        {
            _stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            _dec = BitmapDecoder.Create(_stream, BitmapCreateOptions.PreservePixelFormat,
                                        cacheAll ? BitmapCacheOption.OnLoad : BitmapCacheOption.None);
            if (cacheAll) { _stream.Dispose(); _stream = null; }
            Count = _dec.Frames.Count;
            BitmapFrame f0 = _dec.Frames[0];
            SourceWidth = f0.PixelWidth;
            SourceHeight = f0.PixelHeight;
            DetectFormat(f0.Format);
        }

        private static Guid FormatGuid(PixelFormat pf)
        {
            try
            {
                PropertyInfo p = typeof(PixelFormat).GetProperty("Guid", BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public);
                if (p != null) return (Guid)p.GetValue(pf, null);
            }
            catch { }
            return Guid.Empty;
        }

        private void DetectFormat(PixelFormat pf)
        {
            Guid g = FormatGuid(pf);
            string s = g.ToString().ToLowerInvariant();
            _convert = false;
            if (pf == PixelFormats.Bgra32) { _swapRB = false; _premul = false; }
            else if (pf == PixelFormats.Pbgra32) { _swapRB = false; _premul = true; }
            else if (s == "f5c7ad2d-6a8d-43dd-a7a8-a29935261ae9") { _swapRB = true; _premul = false; }   // 32bppRGBA
            else if (s == "3cc4a650-a527-4d37-a916-3142c7ebedba") { _swapRB = true; _premul = true; }    // 32bppPRGBA
            else { _convert = true; }
            FormatInfo = pf.ToString() + " " + s + (_convert ? " convert" : (_swapRB ? " swapRB" : "") + (_premul ? " premul" : " straight"));
        }

        private BitmapSource ToPbgra(int index)
        {
            BitmapSource f = _dec.Frames[index];
            if (_convert)
            {
                FormatConvertedBitmap c = new FormatConvertedBitmap(f, PixelFormats.Pbgra32, null, 0);
                c.Freeze();
                return c;
            }
            int w = f.PixelWidth, h = f.PixelHeight, stride = w * 4;
            byte[] px = new byte[stride * h];
            f.CopyPixels(px, stride, 0);
            for (int k = 0; k < px.Length; k += 4)
            {
                int c0 = px[k], c1 = px[k + 1], c2 = px[k + 2], a = px[k + 3];
                int b = _swapRB ? c2 : c0;
                int r = _swapRB ? c0 : c2;
                int g = c1;
                if (!_premul && a != 255)
                {
                    b = (b * a + 127) / 255; g = (g * a + 127) / 255; r = (r * a + 127) / 255;
                }
                px[k] = (byte)b; px[k + 1] = (byte)g; px[k + 2] = (byte)r;
            }
            BitmapSource src = BitmapSource.Create(w, h, 96, 96, PixelFormats.Pbgra32, null, px, stride);
            src.Freeze();
            return src;
        }

        // 取第 index 帧：裁出 (cx,cy,cw,ch)，高质量缩放到 tw×th，返回已冻结的位图（可跨线程）
        public BitmapSource GetFrame(int index, int cx, int cy, int cw, int ch, int tw, int th)
        {
            BitmapSource src = ToPbgra(index);
            if (tw <= 0 || th <= 0) { tw = cw; th = ch; }
            double sx = (double)tw / cw, sy = (double)th / ch;
            DrawingVisual dv = new DrawingVisual();
            RenderOptions.SetBitmapScalingMode(dv, BitmapScalingMode.HighQuality);
            using (DrawingContext dc = dv.RenderOpen())
            {
                dc.DrawImage(src, new Rect(-cx * sx, -cy * sy, src.PixelWidth * sx, src.PixelHeight * sy));
            }
            RenderTargetBitmap rtb = new RenderTargetBitmap(tw, th, 96, 96, PixelFormats.Pbgra32);
            rtb.Render(dv);
            rtb.Freeze();
            return rtb;
        }

        public void Dispose()
        {
            _dec = null;
            if (_stream != null) { _stream.Dispose(); _stream = null; }
        }
    }

    // CSS 同款 cubic-bezier(x1,y1,x2,y2) 缓动（允许 y 超出 0..1，用来复刻原项目的按压回弹曲线）
    public sealed class CubicBezierEase : System.Windows.Media.Animation.EasingFunctionBase
    {
        public static readonly DependencyProperty X1Property = DependencyProperty.Register("X1", typeof(double), typeof(CubicBezierEase), new PropertyMetadata(0.25));
        public static readonly DependencyProperty Y1Property = DependencyProperty.Register("Y1", typeof(double), typeof(CubicBezierEase), new PropertyMetadata(0.1));
        public static readonly DependencyProperty X2Property = DependencyProperty.Register("X2", typeof(double), typeof(CubicBezierEase), new PropertyMetadata(0.25));
        public static readonly DependencyProperty Y2Property = DependencyProperty.Register("Y2", typeof(double), typeof(CubicBezierEase), new PropertyMetadata(1.0));
        public double X1 { get { return (double)GetValue(X1Property); } set { SetValue(X1Property, value); } }
        public double Y1 { get { return (double)GetValue(Y1Property); } set { SetValue(Y1Property, value); } }
        public double X2 { get { return (double)GetValue(X2Property); } set { SetValue(X2Property, value); } }
        public double Y2 { get { return (double)GetValue(Y2Property); } set { SetValue(Y2Property, value); } }

        public CubicBezierEase() { EasingMode = System.Windows.Media.Animation.EasingMode.EaseIn; }
        public CubicBezierEase(double x1, double y1, double x2, double y2) : this() { X1 = x1; Y1 = y1; X2 = x2; Y2 = y2; }

        private static double B(double a, double b, double s) { double u = 1 - s; return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s; }
        private static double DB(double a, double b, double s) { double u = 1 - s; return 3 * u * u * a + 6 * u * s * (b - a) + 3 * s * s * (1 - b); }

        protected override double EaseInCore(double t)
        {
            if (t <= 0) return 0;
            if (t >= 1) return 1;
            double x1 = X1, x2 = X2, s = t;
            for (int i = 0; i < 8; i++)
            {
                double dx = B(x1, x2, s) - t;
                if (Math.Abs(dx) < 1e-6) break;
                double d = DB(x1, x2, s);
                if (Math.Abs(d) < 1e-6) break;
                s -= dx / d;
            }
            if (s < 0 || s > 1 || Math.Abs(B(x1, x2, s) - t) > 1e-4)
            {
                double lo = 0, hi = 1; s = t;
                for (int i = 0; i < 40; i++) { if (B(x1, x2, s) < t) lo = s; else hi = s; s = (lo + hi) / 2; }
            }
            return B(Y1, Y2, s);
        }

        protected override Freezable CreateInstanceCore() { return new CubicBezierEase(); }
    }

    public static class Win32
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct RECT { public int Left, Top, Right, Bottom; }

        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hWnd, uint cmd);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int index);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] public static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int index, IntPtr value);

        public const int GWL_EXSTYLE = -20;
        public const long WS_EX_TOPMOST = 0x8, WS_EX_TOOLWINDOW = 0x80, WS_EX_NOACTIVATE = 0x08000000;

        public static bool IsTopmost(IntPtr h) { return (GetWindowLongPtr(h, GWL_EXSTYLE).ToInt64() & WS_EX_TOPMOST) != 0; }

        public static void AddExStyle(IntPtr h, long bits)
        {
            long cur = GetWindowLongPtr(h, GWL_EXSTYLE).ToInt64();
            SetWindowLongPtr(h, GWL_EXSTYLE, new IntPtr(cur | bits));
        }

        // 把 me 放到 target 正上方（z 序），不激活、不移动
        public static void PlaceAbove(IntPtr me, IntPtr target)
        {
            IntPtr prev = GetWindow(target, 3); // GW_HWNDPREV
            if (prev == me) return;
            IntPtr after = IntPtr.Zero;           // HWND_TOP
            if (prev != IntPtr.Zero && !IsTopmost(prev)) after = prev;
            SetWindowPos(me, after, 0, 0, 0, 0, 0x0013); // NOSIZE|NOMOVE|NOACTIVATE
        }

        [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr hWnd, int attr, out RECT rect, int size);

        // 窗口实际可见的边界（不含 Win10/11 最大化时伸出屏幕的隐形边框）
        public static bool GetVisibleRect(IntPtr h, out RECT r)
        {
            try
            {
                if (DwmGetWindowAttribute(h, 9, out r, Marshal.SizeOf(typeof(RECT))) == 0 && r.Right > r.Left) return true; // DWMWA_EXTENDED_FRAME_BOUNDS
            }
            catch { }
            return GetWindowRect(h, out r);
        }
    }
}
