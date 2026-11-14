// SPDX-License-Identifier: GPL-3.0-or-later
// URL protocol adapted from DanXi-Dev/DanXi 3c1f5f026fbc7ca50e151865f813cdb381807abe,
// lib/util/webvpn_proxy.dart. This public encoding key is not an account credential.
//! Trusted Fudan gateway adapter; the core owns generic routing and grants.
use aes::cipher::{AsyncStreamCipher, KeyIvInit};
use dansheng_core::{
    CoreError, CoreResult,
    network_routes::{GatewayRoute, RouteMode},
};
use url::Url;

pub const GATEWAY_ORIGIN: &str = "https://webvpn.fudan.edu.cn";
const ENCODING_KEY: &[u8; 16] = b"wrdvpnisthebest!";
pub const DEFAULT_ORIGINS: &[&str] = &[
    "https://fdjwgl.fudan.edu.cn",
    "https://elearning.fudan.edu.cn",
    "https://ecard.fudan.edu.cn",
    "https://zlapp.fudan.edu.cn",
    "https://my.fudan.edu.cn",
    "https://yjsxk.fudan.edu.cn",
    "https://ehall.fudan.edu.cn",
    "http://10.64.130.6",
    "https://www.fduhole.com",
    "https://auth.fduhole.com",
    "https://danke.fduhole.com",
    "https://forum.fduhole.com",
    "https://image.fduhole.com",
];
fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

pub fn gateway_route(origin: &str, mode: RouteMode) -> CoreResult<GatewayRoute> {
    let url =
        Url::parse(origin).map_err(|_| CoreError::invalid("invalid Fudan resource origin"))?;
    if url.origin().ascii_serialization() != origin || !matches!(url.scheme(), "http" | "https") {
        return Err(CoreError::invalid(
            "resource must be a canonical HTTP(S) origin",
        ));
    }
    let host = url
        .host_str()
        .ok_or_else(|| CoreError::invalid("resource host is missing"))?;
    if matches!(
        host,
        "webvpn.fudan.edu.cn" | "id.fudan.edu.cn" | "uis.fudan.edu.cn"
    ) || !(host.ends_with(".fudan.edu.cn")
        || host == "fudan.edu.cn"
        || host == "10.64.130.6"
        || [
            "www.fduhole.com",
            "auth.fduhole.com",
            "danke.fduhole.com",
            "forum.fduhole.com",
            "image.fduhole.com",
        ]
        .contains(&host))
    {
        return Err(CoreError::new(
            "PermissionDenied",
            "resource is outside the Fudan gateway adapter scope",
        ));
    }
    let mut encoded = host.as_bytes().to_vec();
    cfb_mode::Encryptor::<aes::Aes128>::new(ENCODING_KEY.into(), ENCODING_KEY.into())
        .encrypt(&mut encoded);
    let encoded_host = format!("{}{}", hex(ENCODING_KEY), hex(&encoded));
    let scheme = url
        .port()
        .map(|port| format!("{}-{port}", url.scheme()))
        .unwrap_or_else(|| url.scheme().to_owned());
    let route = GatewayRoute {
        provider: "fudan.webvpn".into(),
        origin: origin.into(),
        gateway_prefix: format!("{GATEWAY_ORIGIN}/{scheme}/{encoded_host}"),
        mode,
    };
    dansheng_core::network_routes::validate_routes(std::slice::from_ref(&route))?;
    Ok(route)
}
pub fn gateway_routes(origins: &[String], mode: RouteMode) -> CoreResult<Vec<GatewayRoute>> {
    let routes = origins
        .iter()
        .map(|origin| gateway_route(origin, mode))
        .collect::<CoreResult<Vec<_>>>()?;
    dansheng_core::network_routes::validate_routes(&routes)?;
    Ok(routes)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn gateway_host_encoding_matches_the_independent_aes_cfb_reference_vector() {
        let rule = gateway_route("https://forum.fduhole.com", RouteMode::Gateway).unwrap();
        assert_eq!(
            rule.gateway_prefix,
            "https://webvpn.fudan.edu.cn/https/77726476706e69737468656265737421f6f853892a7e6e546b0086a09d1b203a46"
        );
    }
    #[test]
    fn provider_cannot_route_auth_bootstrap_or_unrelated_destinations() {
        for origin in [
            GATEWAY_ORIGIN,
            "https://id.fudan.edu.cn",
            "https://uis.fudan.edu.cn",
            "https://evil.example",
            "https://fudan.edu.cn.evil.example",
            "https://127.0.0.1",
            "https://forum.fduhole.com/path",
            "https://u:p@forum.fduhole.com",
        ] {
            assert!(gateway_route(origin, RouteMode::Gateway).is_err());
        }
        let rule = gateway_route("http://10.64.130.6", RouteMode::Gateway).unwrap();
        let logical = Url::parse("http://10.64.130.6/resource/query?building=fixture").unwrap();
        assert_eq!(
            rule.decode(&rule.encode(&logical).unwrap()).unwrap(),
            Some(logical)
        );
        assert!(
            rule.gateway_prefix
                .starts_with("https://webvpn.fudan.edu.cn/http/")
        );
    }
}
