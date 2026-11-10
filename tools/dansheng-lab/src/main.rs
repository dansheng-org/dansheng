use clap::Parser;
use dansheng_core::{CoreResult, Engine};
use dansheng_host::{platform::DesktopPlatform, security};
use std::{
    path::{Path, PathBuf},
    sync::Arc,
};

#[derive(Parser)]
#[command(about = "Development-only local credential intake and read-only core tests")]
struct Args {
    #[arg(long)]
    profile: Option<PathBuf>,
    #[arg(long, default_value_t = 19764)]
    port: u16,
}
#[tokio::main]
async fn main() {
    if let Err(error) = run(Args::parse()).await {
        // No profile content, upstream error body, URL ticket, token or password logs.
        eprintln!("dansheng-lab stopped: {}", error.code);
        std::process::exit(1);
    }
}
async fn run(args: Args) -> CoreResult<()> {
    let default_root = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .ok_or_else(|| dansheng_core::CoreError::invalid("Windows LOCALAPPDATA is required"))?
        .join("dansheng-lab");
    let profile = args
        .profile
        .unwrap_or_else(|| default_root.join("profiles").join("manual"));
    // Never place real credentials or personal source data in this repository.
    let workspace = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()?;
    let normalized = dansheng_core::store::Store::profile_path(&profile)?;
    if normalized.starts_with(&workspace) {
        return Err(dansheng_core::CoreError::invalid(
            "test profiles must be outside the source workspace",
        ));
    }
    let lock = dansheng_core::store::Store::acquire_profile_lock(&profile)?;
    security::private_dir(&profile)?;
    let platform = Arc::new(DesktopPlatform::new(&profile));
    let engine = Engine::from_store(
        dansheng_core::store::Store::open_locked(lock)?,
        platform.clone(),
    );
    engine.register_service(Arc::new(dansheng_connectors::core_adapter::CampusService))?;
    let listener =
        tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, args.port)).await?;
    let port = listener.local_addr()?.port();
    let app = dansheng_lab::Lab::new(engine, platform, port);
    let run_path = profile.join("lab-control.json");
    security::write_private_json(&run_path, &app.control_file().await)?;
    println!("dansheng-lab ready at http://127.0.0.1:{port}");
    let shutdown = app.clone();
    axum::serve(listener, dansheng_lab::router(app))
        .with_graceful_shutdown(async move {
            tokio::select! { _=tokio::signal::ctrl_c()=>{}, _=shutdown.wait_for_shutdown()=>{} }
        })
        .await?;
    Ok(())
}
