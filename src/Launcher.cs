using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;

internal static class Launcher
{
    [STAThread]
    private static void Main(string[] args)
    {
        try
        {
            string app = AppDomain.CurrentDomain.BaseDirectory;
            string shell = File.ReadAllText(Path.Combine(app, "pwsh.path")).Trim();
            string script = Path.Combine(app, "Update.ps1");
            string payload = Convert.ToBase64String(Encoding.UTF8.GetBytes(new JavaScriptSerializer().Serialize(args)));
            string command = "-NoLogo -NoProfile -File \"" + script + "\" -Payload " + payload;
            var dispatch = new ProcessStartInfo(shell, "-NonInteractive " + command + " -Dispatch");
            dispatch.UseShellExecute = false;
            dispatch.CreateNoWindow = true;
            dispatch.WorkingDirectory = Environment.CurrentDirectory;
            using (Process worker = Process.Start(dispatch))
            {
                worker.WaitForExit();
                if (worker.ExitCode == 0) return;
                if (worker.ExitCode != 10) throw new InvalidOperationException();
            }

            var visible = new ProcessStartInfo(shell, command + " -Interactive");
            visible.UseShellExecute = true;
            visible.WindowStyle = ProcessWindowStyle.Normal;
            visible.WorkingDirectory = Environment.CurrentDirectory;
            using (Process worker = Process.Start(visible)) { }
        }
        catch
        {
            MessageBox.Show("The Chromium update launcher could not start. Check the installed updater and PowerShell.",
                "Chromium Updater", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
