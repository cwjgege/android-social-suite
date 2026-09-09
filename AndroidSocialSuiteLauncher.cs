using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

internal static class AndroidSocialSuiteLauncher
{
    [STAThread]
    private static int Main(string[] args)
    {
        string extractionRoot = Path.Combine(
            Path.GetTempPath(),
            "AndroidSocialSuite",
            Guid.NewGuid().ToString("N"));

        try
        {
            Directory.CreateDirectory(extractionRoot);
            string suitePath = Path.Combine(extractionRoot, "android-social-suite.ps1");
            string managerPath = Path.Combine(extractionRoot, "android-avd-manager.ps1");
            string xrayPath = Path.Combine(extractionRoot, "xray.exe");
            string xrayLicensePath = Path.Combine(extractionRoot, "XRAY-LICENSE.txt");
            string zxingPath = Path.Combine(extractionRoot, "zxing.dll");
            string zxingLicensePath = Path.Combine(extractionRoot, "ZXING-LICENSE.txt");
            string iconPath = Path.Combine(extractionRoot, "app-icon.ico");
            string iconImagePath = Path.Combine(extractionRoot, "app-icon.png");
            ExtractResource("android-social-suite.ps1", suitePath);
            ExtractResource("android-avd-manager.ps1", managerPath);
            ExtractResource("xray.exe", xrayPath);
            ExtractResource("XRAY-LICENSE.txt", xrayLicensePath);
            ExtractResource("zxing.dll", zxingPath);
            ExtractResource("ZXING-LICENSE.txt", zxingLicensePath);
            ExtractResource("app-icon.ico", iconPath);
            ExtractResource("app-icon.png", iconImagePath);

            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                "WindowsPowerShell",
                "v1.0",
                "powershell.exe");
            startInfo.Arguments = BuildArguments(suitePath, args);
            startInfo.WorkingDirectory = extractionRoot;
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;
            startInfo.WindowStyle = ProcessWindowStyle.Hidden;
            startInfo.EnvironmentVariables["ANDROID_SOCIAL_LAUNCHER_EXE"] =
                Assembly.GetExecutingAssembly().Location;

            using (Process process = Process.Start(startInfo))
            {
                process.WaitForExit();
                return process.ExitCode;
            }
        }
        catch (Exception exception)
        {
            MessageBox.Show(
                exception.Message,
                "Android Social Suite",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return 1;
        }
        finally
        {
            try
            {
                if (Directory.Exists(extractionRoot))
                {
                    Directory.Delete(extractionRoot, true);
                }
            }
            catch
            {
                // Windows will clear abandoned temporary files normally.
            }
        }
    }

    private static void ExtractResource(string resourceName, string destination)
    {
        Assembly assembly = Assembly.GetExecutingAssembly();
        using (Stream input = assembly.GetManifestResourceStream(resourceName))
        {
            if (input == null)
            {
                throw new InvalidOperationException("Missing embedded component: " + resourceName);
            }

            using (FileStream output = new FileStream(destination, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                input.CopyTo(output);
            }
        }
    }

    private static string BuildArguments(string suitePath, IEnumerable<string> args)
    {
        StringBuilder builder = new StringBuilder();
        builder.Append("-NoLogo -NoProfile -ExecutionPolicy Bypass -File ");
        builder.Append(Quote(suitePath));
        foreach (string argument in args)
        {
            builder.Append(' ');
            builder.Append(Quote(argument));
        }
        return builder.ToString();
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }
}
