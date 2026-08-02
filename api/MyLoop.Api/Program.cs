using MyLoop.Api.Configuration;
using MyLoop.Api.Data;

var builder = WebApplication.CreateBuilder(args);

builder.Host.AddMyLoopSerilog();

builder.Services
    .AddMyLoopDatabase(builder.Configuration)
    .AddMyLoopServices()
    .AddMyLoopPushNotifications(builder.Configuration)
    .AddMyLoopAuthentication(builder.Configuration)
    .AddMyLoopRateLimiting()
    .AddMyLoopCors(builder.Configuration);

builder.Services.AddSignalR();
builder.Services.AddControllers();

var app = builder.Build();

app.UseMyLoopPipeline();
await app.InitializeDatabaseAsync();

app.Run();

// Exposed so the integration-test project (WebApplicationFactory) can boot the app.
public partial class Program { }
