// CodHQ-Setup.exe: a small Windows launcher for install.ps1.
//
// The script is embedded in the executable. On start it is written to
// %LOCALAPPDATA%\CallOfDutyHQ-SetupUtility\app\install-<hash>.ps1 (only when that
// exact copy is not there yet) and started with Windows PowerShell 5.1 in STA mode
// with no console window, the same way "irm ... | iex" starts it. Arguments are
// passed through unchanged, so the script's own options (-Sandbox, -GameFolder, the
// administrator hand-off) keep working. Built by tools\Build-Exe.ps1 with the C#
// compiler that ships with the .NET Framework; it needs nothing else installed.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("Call of Duty HQ Setup Utility")]
[assembly: AssemblyDescription("Call of Duty HQ Setup Utility")]
[assembly: AssemblyProduct("Call of Duty HQ Setup Utility")]
[assembly: AssemblyCompany("LarkTheStar")]
[assembly: AssemblyCopyright("LarkTheStar")]

internal static class Program
{
    private const string ResourceName = "install.ps1";

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            string dryRunFile = null;
            var forwarded = new List<string>();
            for (int i = 0; i < args.Length; i++)
            {
                // Test hook: write the command that would run to a file instead of running it.
                if (args[i] == "--dry-run" && i + 1 < args.Length) { dryRunFile = args[++i]; continue; }
                forwarded.Add(args[i]);
            }

            string scriptPath = ExtractScript();
            string powershell = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
            var arguments = new StringBuilder("-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File ");
            arguments.Append(Quote(scriptPath));
            foreach (string argument in forwarded) { arguments.Append(' ').Append(Quote(argument)); }

            if (dryRunFile != null)
            {
                File.WriteAllText(dryRunFile, powershell + "\n" + arguments + "\n" + scriptPath + "\n", new UTF8Encoding(false));
                return 0;
            }

            var start = new ProcessStartInfo(powershell, arguments.ToString());
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.WorkingDirectory = Path.GetDirectoryName(scriptPath);
            start.EnvironmentVariables["CODHQ_LAUNCHER"] = "exe";
            Process.Start(start);
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show("The setup utility could not start:\n\n" + ex.Message, "Call of Duty HQ Setup Utility", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    // Writes the embedded script next to the user's settings. The file name carries the
    // script's hash, so a copy that is there already is exactly this version; older
    // copies are removed when they are not in use.
    private static string ExtractScript()
    {
        byte[] script;
        using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(ResourceName))
        {
            if (stream == null) { throw new InvalidOperationException("The embedded script is missing."); }
            using (var buffer = new MemoryStream()) { stream.CopyTo(buffer); script = buffer.ToArray(); }
        }
        string hash;
        using (SHA256 sha = SHA256.Create()) { hash = BitConverter.ToString(sha.ComputeHash(script)).Replace("-", "").Substring(0, 16).ToLowerInvariant(); }

        string folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CallOfDutyHQ-SetupUtility", "app");
        Directory.CreateDirectory(folder);
        string path = Path.Combine(folder, "install-" + hash + ".ps1");
        if (!File.Exists(path) || new FileInfo(path).Length != script.Length)
        {
            string temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            File.WriteAllBytes(temp, script);
            if (File.Exists(path)) { File.Delete(path); }
            File.Move(temp, path);
        }
        foreach (string old in Directory.GetFiles(folder, "install-*.ps1"))
        {
            if (string.Equals(old, path, StringComparison.OrdinalIgnoreCase)) { continue; }
            try { File.Delete(old); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
        return path;
    }

    // Quotes one argument for a Windows command line (the rules CommandLineToArgvW reads).
    private static string Quote(string value)
    {
        if (value.Length > 0 && value.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) { return value; }
        var result = new StringBuilder("\"");
        int backslashes = 0;
        foreach (char c in value)
        {
            if (c == '\\') { backslashes++; continue; }
            if (c == '"') { result.Append('\\', backslashes * 2 + 1); }
            else { result.Append('\\', backslashes); }
            backslashes = 0;
            result.Append(c);
        }
        result.Append('\\', backslashes * 2);
        return result.Append('"').ToString();
    }
}
