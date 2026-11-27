// Watch.cs —— Claude娘「随 Claude 启动」的小助手（C# 5 语法）
//   由 Common.ps1 编译成 %LOCALAPPDATA%\ClaudeNiang\ClaudeNiangWatch.exe，快捷方式放在「启动」文件夹里，登录后常驻。
//   · Claude 桌面 App 一启动，就把 Claude娘 叫出来；
//   · Claude 完全退出（约 6 秒内没回来）后，让由它叫出来的 Claude娘 一起退出。
//   每 2 秒用 EnumWindows 看一眼有没有 Claude 的窗口：不查 WMI（一次要 ~0.3 秒）、不常驻 PowerShell，几乎不占 CPU 和内存。
//   「启动」文件夹里的快捷方式被删掉（改了启动方式 / 停用）或者程序文件夹不在了，它就自己退出。
//
//   用法：ClaudeNiangWatch.exe "<程序的 app 目录>" ["<启动文件夹里的快捷方式>"] [--baseline]
//     --baseline：把启动这一刻 Claude 是否在运行当作初始状态（从菜单 / 安装器打开时用，避免和它们重复启动挂件）
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace ClaudeNiangWatch
{
    static class Program
    {
        delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int max);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr h, int flags, StringBuilder sb, ref int size);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

        const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        const int PollMs = 2000;
        const int GoneSeconds = 6;

        static readonly Dictionary<uint, bool> PidIsClaude = new Dictionary<uint, bool>();
        static readonly StringBuilder ClassBuf = new StringBuilder(64);
        static readonly StringBuilder PathBuf = new StringBuilder(1024);
        static readonly EnumWindowsProc OnWindowCb = OnWindow;   // 留住委托，免得被 GC 回收
        static bool _found;

        // Claude 桌面 App 的进程：MSIX 版在 ...\WindowsApps\Claude_<版本>\app\claude.exe，旧安装版在 ...\AnthropicClaude\...\claude.exe。
        // Claude Code CLI 也叫 claude.exe，但不在这两个位置，不算。
        static bool IsClaudeDesktop(uint pid)
        {
            bool r;
            if (PidIsClaude.TryGetValue(pid, out r)) return r;
            r = false;
            IntPtr h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
            if (h != IntPtr.Zero)
            {
                try
                {
                    PathBuf.Length = 0;
                    int n = PathBuf.Capacity;
                    if (QueryFullProcessImageName(h, 0, PathBuf, ref n))
                    {
                        string p = PathBuf.ToString().ToLowerInvariant();
                        r = p.EndsWith("\\claude.exe") && (p.Contains("\\windowsapps\\claude_") || p.Contains("\\anthropicclaude\\"));
                    }
                }
                finally { CloseHandle(h); }
            }
            PidIsClaude[pid] = r;
            return r;
        }

        // Claude 是 Electron 应用，顶层窗口的类名是 Chrome_WidgetWin_*（缩到托盘时窗口隐藏但还在）
        static bool OnWindow(IntPtr hWnd, IntPtr lParam)
        {
            ClassBuf.Length = 0;
            if (GetClassName(hWnd, ClassBuf, ClassBuf.Capacity) > 0 && ClassBuf.ToString().StartsWith("Chrome_WidgetWin_", StringComparison.Ordinal))
            {
                uint pid;
                GetWindowThreadProcessId(hWnd, out pid);
                if (pid != 0 && IsClaudeDesktop(pid)) { _found = true; return false; }
            }
            return true;
        }

        static bool ClaudeRunning()
        {
            PidIsClaude.Clear();   // 每轮重新判断，进程号被复用也不会认错
            _found = false;
            EnumWindows(OnWindowCb, IntPtr.Zero);
            return _found;
        }

        // 挂件在运行时持有这个单实例互斥量（见 ClaudeNiang.ps1）
        static bool WidgetRunning()
        {
            try { using (Mutex m = Mutex.OpenExisting(@"Local\ClaudeNiang.Singleton")) { return true; } }
            catch { return false; }
        }

        static void LaunchWidget(string appDir, string script)
        {
            try
            {
                string ps = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
                if (!File.Exists(ps)) ps = "powershell.exe";
                ProcessStartInfo psi = new ProcessStartInfo(ps, "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"");
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.WorkingDirectory = appDir;
                using (Process.Start(psi)) { }
            }
            catch { }
        }

        static void AskWidgetToExit()
        {
            try { using (EventWaitHandle ev = EventWaitHandle.OpenExisting(@"Local\ClaudeNiang.Exit")) { ev.Set(); } }
            catch { }
        }

        [STAThread]
        static int Main(string[] args)
        {
            string appDir = null, link = null;
            bool baseline = false;
            foreach (string a in args)
            {
                if (a == "--baseline") baseline = true;
                else if (appDir == null) appDir = a.TrimEnd('\\', '"');
                else if (link == null) link = a;
            }
            if (string.IsNullOrEmpty(appDir)) return 2;
            string script = Path.Combine(appDir, "ClaudeNiang.ps1");

            bool created;
            using (Mutex single = new Mutex(true, @"Local\ClaudeNiang.Watch", out created))
            {
                if (!created) return 0;   // 已经有一个在看着了

                bool was = baseline && ClaudeRunning();
                bool launched = false;     // 当前这个挂件是不是我们叫出来的（只让自己叫出来的跟着 Claude 退出）
                DateTime lastSeen = DateTime.UtcNow;
                while (true)
                {
                    if ((link != null && !File.Exists(link)) || !File.Exists(script)) return 0;
                    bool now = ClaudeRunning();
                    if (now)
                    {
                        lastSeen = DateTime.UtcNow;
                        if (!was && !WidgetRunning()) { LaunchWidget(appDir, script); launched = true; }
                    }
                    else if (launched && (DateTime.UtcNow - lastSeen).TotalSeconds >= GoneSeconds)
                    {
                        AskWidgetToExit();
                        launched = false;
                    }
                    was = now;
                    Thread.Sleep(PollMs);
                }
            }
        }
    }
}
