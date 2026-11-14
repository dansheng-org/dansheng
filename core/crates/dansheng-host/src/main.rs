use clap::{Parser, Subcommand};
use dansheng_core::{CoreError, CoreResult, Request};
use dansheng_host::{Client, ClientConfig, HostPaths};
use std::path::PathBuf;

#[derive(Parser)]
#[command(
    name = "dansheng-host",
    about = "Local dansheng desktop service and IPC clients"
)]
struct Cli {
    #[arg(long, global = true)]
    data_dir: Option<PathBuf>,
    /// Client config containing endpoint and token_file; MCP defaults to its dedicated config.
    #[arg(long, global = true)]
    client_config: Option<PathBuf>,
    #[command(subcommand)]
    command: Command,
}
#[derive(Subcommand)]
enum Command {
    /// Own the database, authenticated local IPC listener and scheduler.
    Serve,
    /// Call a core method with JSON params, or supply a full Request using --request.
    Call {
        method: Option<String>,
        #[arg(default_value = "{}")]
        params: String,
        #[arg(long)]
        request: Option<String>,
    },
    /// MCP over stdio; connects with the dedicated MCP token and never opens storage.
    Mcp,
    /// Print the core Request/Response JSON schema without opening storage.
    Schema,
    /// Offline snapshot restore. Stop the service first; core validates and locks the profile.
    Restore { snapshot: PathBuf },
}
#[tokio::main]
async fn main() {
    if let Err(error) = run(Cli::parse()).await {
        eprintln!("{}", serde_json::json!({"error":error}));
        std::process::exit(1);
    }
}
fn read_config(path: &std::path::Path) -> CoreResult<ClientConfig> {
    let bytes = std::fs::read(path)?;
    if bytes.len() > 64 * 1024 {
        return Err(CoreError::invalid("client config too large"));
    }
    Ok(serde_json::from_slice(&bytes)?)
}
async fn run(cli: Cli) -> CoreResult<()> {
    if matches!(cli.command, Command::Schema) {
        println!(
            "{}",
            serde_json::to_string_pretty(&dansheng_host::schema())?
        );
        return Ok(());
    }
    let data_dir = match cli.data_dir {
        Some(path) => path,
        None => default_data_dir()?,
    };
    // Restore is a native offline command, before HostPaths, token provisioning,
    // Engine::open or IPC. Invalid snapshots must not create host-owned files.
    if let Command::Restore { snapshot } = cli.command {
        let receipt = tokio::task::spawn_blocking(move || {
            dansheng_core::backup::restore(&data_dir, &snapshot)
        })
        .await
        .map_err(|_| CoreError::new("RestoreFailed", "offline restore worker failed"))??;
        println!("{}", serde_json::to_string(&receipt)?);
        return Ok(());
    }
    let paths = HostPaths::new(&data_dir)?;
    match cli.command {
        Command::Serve => dansheng_host::serve(paths, shutdown()).await,
        Command::Call {
            method,
            params,
            request,
        } => {
            let config = match cli.client_config {
                Some(path) => read_config(&path)?,
                None => paths.owner,
            };
            let client = Client::connect(&config).await?;
            let request: Request = if let Some(request) = request {
                serde_json::from_str(&request)?
            } else {
                Request {
                    id: uuid::Uuid::new_v4().to_string(),
                    method: method
                        .ok_or_else(|| CoreError::invalid("method or --request is required"))?,
                    params: serde_json::from_str(&params)?,
                }
            };
            println!("{}", serde_json::to_string(&client.call(request).await?)?);
            Ok(())
        }
        Command::Mcp => {
            let config =
                read_config(&cli.client_config.unwrap_or_else(|| paths.mcp_config_path()))?;
            dansheng_host::mcp::serve_stdio(&config).await
        }
        Command::Schema | Command::Restore { .. } => unreachable!(),
    }
}
fn default_data_dir() -> CoreResult<PathBuf> {
    #[cfg(windows)]
    if let Some(path) = std::env::var_os("LOCALAPPDATA") {
        return Ok(PathBuf::from(path).join("dansheng"));
    }
    #[cfg(unix)]
    {
        if let Some(path) = std::env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .filter(|p| p.is_absolute())
        {
            return Ok(path.join("dansheng"));
        }
        if let Some(path) = std::env::var_os("HOME") {
            return Ok(PathBuf::from(path).join(".local/share/dansheng"));
        }
    }
    Err(CoreError::invalid(
        "set --data-dir to a private application directory",
    ))
}
async fn shutdown() {
    #[cfg(unix)]
    {
        let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("SIGTERM listener");
        tokio::select! { _ = tokio::signal::ctrl_c() => {}, _ = term.recv() => {} }
    }
    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}
