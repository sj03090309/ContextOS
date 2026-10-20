using System.Windows;

namespace ContextOS.Windows;

public partial class App : Application
{
    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        try
        {
            var contract = CoreContract.LoadBundled();
            if (e.Args.SequenceEqual(new[] { "--self-test" }))
            {
                ShutdownMode = ShutdownMode.OnExplicitShutdown;
                Shutdown(await ShellSelfTest.RunAsync(contract));
                return;
            }
            if (e.Args.Length != 0) { Shutdown(2); return; }
            var window = new MainWindow(new DashboardViewModel(new RuntimeInspector(contract), contract.Version));
            MainWindow = window;
            window.Show();
        }
        catch (Exception exception)
        {
            if (e.Args.Length == 0)
                MessageBox.Show("앱의 버전 정보를 확인할 수 없습니다. 같은 버전의 전체 앱을 다시 준비해 주세요.", "ContextOS",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
            else if (e.Args.SequenceEqual(new[] { "--self-test" }))
                Console.Error.WriteLine("GUI startup self-test failed: " + exception.GetType().Name);
            Shutdown(2);
        }
    }
}
