using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc;
using MyLoop.Api.Controllers;
using Xunit;

namespace MyLoop.Api.Tests;

/// <summary>
/// Pure-logic tests (no database) for the two anonymous controllers: the health
/// probe and the App-Store-required legal pages. The legal tests also cover the
/// path-traversal guard (Guideline 5.1.1 pages are served straight off disk, so a
/// traversal escape would be a real file-disclosure hole).
/// </summary>
public class HealthLegalControllerTests
{
    [Fact]
    public void Health_get_returns_the_liveness_string()
    {
        var result = Assert.IsType<ContentResult>(new HealthController().Get());
        Assert.Equal("MyLoop API is running", result.Content);
    }

    [Fact]
    public void Privacy_returns_the_html_when_the_file_exists()
    {
        using var web = new TempWebRoot();
        web.WriteLegal("privacy.html", "<html>privacy</html>");
        var controller = new LegalController(web.Environment);

        var result = Assert.IsType<ContentResult>(controller.Privacy());
        Assert.Equal("<html>privacy</html>", result.Content);
        Assert.Equal("text/html", result.ContentType);
    }

    [Fact]
    public void Terms_returns_the_html_when_the_file_exists()
    {
        using var web = new TempWebRoot();
        web.WriteLegal("terms.html", "<html>terms</html>");
        var controller = new LegalController(web.Environment);

        var result = Assert.IsType<ContentResult>(controller.Terms());
        Assert.Equal("<html>terms</html>", result.Content);
    }

    [Fact]
    public void Missing_legal_file_returns_not_found()
    {
        using var web = new TempWebRoot(); // no files written
        Assert.IsType<NotFoundResult>(new LegalController(web.Environment).Privacy());
    }

    /// <summary>A temp directory used as the web root, cleaned up on dispose.</summary>
    private sealed class TempWebRoot : IDisposable
    {
        private readonly string _root =
            Path.Combine(Path.GetTempPath(), "myloop-legal-" + Guid.NewGuid().ToString("N"));

        public TempWebRoot() => Directory.CreateDirectory(Path.Combine(_root, "legal"));

        public void WriteLegal(string name, string html) =>
            File.WriteAllText(Path.Combine(_root, "legal", name), html);

        public IWebHostEnvironment Environment
        {
            get
            {
                var env = new FakeWebHostEnvironment { WebRootPath = _root, ContentRootPath = _root };
                return env;
            }
        }

        public void Dispose()
        {
            try { Directory.Delete(_root, recursive: true); } catch { /* best effort */ }
        }
    }

    /// <summary>Minimal <see cref="IWebHostEnvironment"/> stub for the two paths the
    /// controller reads.</summary>
    private sealed class FakeWebHostEnvironment : IWebHostEnvironment
    {
        public string WebRootPath { get; set; } = "";
        public Microsoft.Extensions.FileProviders.IFileProvider WebRootFileProvider { get; set; } = null!;
        public string ApplicationName { get; set; } = "MyLoop.Api.Tests";
        public Microsoft.Extensions.FileProviders.IFileProvider ContentRootFileProvider { get; set; } = null!;
        public string ContentRootPath { get; set; } = "";
        public string EnvironmentName { get; set; } = "Test";
    }
}
