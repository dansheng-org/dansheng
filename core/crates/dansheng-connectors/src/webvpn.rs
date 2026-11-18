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
/// Every Fudan service origin a connector talks to, plus the intranet room
/// directory. With WebVPN switched on, all of them go through the gateway.
/// `fudan_origins_cover_every_connector_address` keeps this list complete.
/// The identity providers and the gateway itself are never routed: logins
/// reach them through [`encode_url`] inside the login flow instead.
pub const FUDAN_ORIGINS: &[&str] = &[
    "https://fdjwgl.fudan.edu.cn",
    "https://elearning.fudan.edu.cn",
    "https://elearning.obs.fudan.edu.cn",
    "https://ecard.fudan.edu.cn",
    "https://zlapp.fudan.edu.cn",
    "https://my.fudan.edu.cn",
    "http://yjsxk.fudan.edu.cn",
    "https://yjsxk.fudan.edu.cn",
    "https://ehall.fudan.edu.cn",
    "https://cloud.fudan.edu.cn",
    "https://elife.fudan.edu.cn",
    "https://fdtyjw.fudan.edu.cn",
    "https://fdulspgw.fudan.edu.cn",
    "https://gs.fudan.edu.cn",
    "https://jwc.fudan.edu.cn",
    "https://library.fudan.edu.cn",
    "https://mlibrary.fudan.edu.cn",
    "https://news.fudan.edu.cn",
    "https://opac.fudan.edu.cn",
    "https://paper.fudan.edu.cn",
    "https://yzsfwapp.fudan.edu.cn",
    "http://10.64.130.6",
];
/// The community forum is reachable from anywhere; WebVPN is only its
/// fallback (DanXi's behaviour), whatever the Fudan switch says.
pub const FORUM_ORIGINS: &[&str] = &[
    "https://www.fduhole.com",
    "https://auth.fduhole.com",
    "https://danke.fduhole.com",
    "https://forum.fduhole.com",
    "https://image.fduhole.com",
];
pub const DEFAULT_ORIGINS: &[&str] = &[
    "https://fdjwgl.fudan.edu.cn",
    "https://elearning.fudan.edu.cn",
    "https://elearning.obs.fudan.edu.cn",
    "https://ecard.fudan.edu.cn",
    "https://zlapp.fudan.edu.cn",
    "https://my.fudan.edu.cn",
    "http://yjsxk.fudan.edu.cn",
    "https://yjsxk.fudan.edu.cn",
    "https://ehall.fudan.edu.cn",
    "https://cloud.fudan.edu.cn",
    "https://elife.fudan.edu.cn",
    "https://fdtyjw.fudan.edu.cn",
    "https://fdulspgw.fudan.edu.cn",
    "https://gs.fudan.edu.cn",
    "https://jwc.fudan.edu.cn",
    "https://library.fudan.edu.cn",
    "https://mlibrary.fudan.edu.cn",
    "https://news.fudan.edu.cn",
    "https://opac.fudan.edu.cn",
    "https://paper.fudan.edu.cn",
    "https://yzsfwapp.fudan.edu.cn",
    "http://10.64.130.6",
    "https://www.fduhole.com",
    "https://auth.fduhole.com",
    "https://danke.fduhole.com",
    "https://forum.fduhole.com",
    "https://image.fduhole.com",
];

/// Whether an origin belongs to the Fudan switch (as opposed to the forum).
pub fn is_fudan_origin(origin: &str) -> bool {
    Url::parse(origin).ok().is_some_and(|url| {
        url.host_str().is_some_and(|host| {
            host == "fudan.edu.cn" || host.ends_with(".fudan.edu.cn") || host == "10.64.130.6"
        })
    })
}

/// The mode a default route takes when the Fudan switch is set to `fudan`.
pub fn default_mode(origin: &str, fudan: RouteMode) -> RouteMode {
    if is_fudan_origin(origin) || fudan == RouteMode::Direct {
        fudan
    } else {
        RouteMode::Auto
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn encoded_host(host: &str) -> String {
    let mut encoded = host.as_bytes().to_vec();
    cfb_mode::Encryptor::<aes::Aes128>::new(ENCODING_KEY.into(), ENCODING_KEY.into())
        .encrypt(&mut encoded);
    format!("{}{}", hex(ENCODING_KEY), hex(&encoded))
}

fn decoded_host(segment: &str) -> Option<String> {
    let cipher = segment.strip_prefix(&hex(ENCODING_KEY))?;
    if cipher.is_empty() || cipher.len() % 2 != 0 || cipher.len() > 512 {
        return None;
    }
    let mut bytes = (0..cipher.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&cipher[i..i + 2], 16).ok())
        .collect::<Option<Vec<u8>>>()?;
    cfb_mode::Decryptor::<aes::Aes128>::new(ENCODING_KEY.into(), ENCODING_KEY.into())
        .decrypt(&mut bytes);
    let host = String::from_utf8(bytes).ok()?;
    host.bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')
        .then_some(host)
}

/// The gateway address of a Fudan URL, for the login flow only. Unlike
/// [`gateway_route`] it accepts the identity providers, because a site's own
/// sign-in has to pass through the gateway to land in the gateway session.
pub fn encode_url(url: &Url) -> CoreResult<Url> {
    let host = url
        .host_str()
        .ok_or_else(|| CoreError::invalid("resource host is missing"))?;
    if !matches!(url.scheme(), "http" | "https")
        || !url.username().is_empty()
        || url.password().is_some()
        || host == "webvpn.fudan.edu.cn"
        || !(host.ends_with(".fudan.edu.cn") || host == "10.64.130.6")
    {
        return Err(CoreError::new(
            "PermissionDenied",
            "resource is outside the Fudan gateway adapter scope",
        ));
    }
    let scheme = url
        .port()
        .map(|port| format!("{}-{port}", url.scheme()))
        .unwrap_or_else(|| url.scheme().to_owned());
    let mut physical = Url::parse(&format!(
        "{GATEWAY_ORIGIN}/{scheme}/{}{}",
        encoded_host(host),
        url.path()
    ))
    .map_err(|_| CoreError::invalid("invalid gateway address"))?;
    physical.set_query(url.query());
    Ok(physical)
}

/// The gateway rewrites links inside the pages it serves. Turns every gateway
/// address in `text` (absolute, or rooted at `/<scheme>/<host>`) back into
/// its logical origin, so a login page reads as the site itself wrote it.
pub fn decode_text(text: &str) -> std::borrow::Cow<'_, str> {
    static PATTERN: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let pattern = PATTERN.get_or_init(|| {
        regex::Regex::new(&format!(
            r"(?:https?:)?(?:(?://|\\/\\/)webvpn\.fudan\.edu\.cn)?(?:/|\\/)(https?)(?:-(\d{{1,5}}))?(?:/|\\/)({}[0-9a-f]{{2,512}})",
            hex(ENCODING_KEY)
        ))
        .expect("constant pattern")
    });
    pattern.replace_all(text, |caps: &regex::Captures<'_>| {
        let whole = caps[0].to_owned();
        let Some(host) = decoded_host(&caps[3]) else {
            return whole;
        };
        if !(host.ends_with(".fudan.edu.cn") || host == "10.64.130.6") {
            return whole;
        }
        let escaped = whole.contains("\\/");
        let origin = match caps.get(2) {
            Some(port) => format!("{}://{host}:{}", &caps[1], port.as_str()),
            None => format!("{}://{host}", &caps[1]),
        };
        if escaped {
            origin.replace('/', "\\/")
        } else {
            origin
        }
    })
}

/// The logical URL behind a gateway address (query and fragment kept), or
/// `None` for the gateway's own pages such as its sign-in.
pub fn decode_url(physical: &Url) -> Option<Url> {
    if physical.origin().ascii_serialization() != GATEWAY_ORIGIN {
        return None;
    }
    let mut segments = physical.path().splitn(4, '/');
    segments.next();
    let scheme = segments.next()?;
    let host = decoded_host(segments.next()?)?;
    let tail = segments.next().unwrap_or("");
    let (scheme, port) = match scheme.split_once('-') {
        Some((scheme, port)) => (scheme, Some(port.parse::<u16>().ok()?)),
        None => (scheme, None),
    };
    if !matches!(scheme, "http" | "https") {
        return None;
    }
    let authority = match port {
        Some(port) => format!("{host}:{port}"),
        None => host,
    };
    let mut logical = Url::parse(&format!("{scheme}://{authority}/{tail}")).ok()?;
    logical.set_query(physical.query());
    logical.set_fragment(physical.fragment());
    Some(logical)
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
    let encoded_host = encoded_host(host);
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

    #[test]
    fn default_origins_are_the_fudan_list_then_the_forum() {
        let joined: Vec<&str> = FUDAN_ORIGINS.iter().chain(FORUM_ORIGINS).copied().collect();
        assert_eq!(DEFAULT_ORIGINS, joined.as_slice());
        assert!(FUDAN_ORIGINS.iter().all(|o| is_fudan_origin(o)));
        assert!(FORUM_ORIGINS.iter().all(|o| !is_fudan_origin(o)));
        gateway_routes(
            &DEFAULT_ORIGINS
                .iter()
                .map(|s| s.to_string())
                .collect::<Vec<_>>(),
            RouteMode::Gateway,
        )
        .unwrap();
    }

    /// With WebVPN on, every Fudan address a connector uses must have a route.
    /// Identity providers and the gateway itself are reached by the login flow.
    #[test]
    fn fudan_origins_cover_every_connector_address() {
        let pattern = regex::Regex::new(r"https?://(?:[a-z0-9-]+\.)*fudan\.edu\.cn").unwrap();
        let unrouted = [
            "https://id.fudan.edu.cn",
            "http://id.fudan.edu.cn",
            "https://uis.fudan.edu.cn",
            "http://uis.fudan.edu.cn",
            "https://webvpn.fudan.edu.cn",
            // Only negative cases in login tests.
            "https://fudan.edu.cn",
            "http://fdjwgl.fudan.edu.cn",
        ];
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        let mut missing = std::collections::BTreeSet::new();
        let mut stack = vec![dir];
        while let Some(dir) = stack.pop() {
            for entry in std::fs::read_dir(dir).unwrap() {
                let path = entry.unwrap().path();
                if path.is_dir() {
                    stack.push(path);
                } else if path.extension().is_some_and(|e| e == "rs") {
                    let text = std::fs::read_to_string(&path).unwrap();
                    for found in pattern.find_iter(&text) {
                        let origin = found.as_str();
                        if !FUDAN_ORIGINS.contains(&origin) && !unrouted.contains(&origin) {
                            missing.insert(origin.to_owned());
                        }
                    }
                }
            }
        }
        assert!(missing.is_empty(), "add to FUDAN_ORIGINS: {missing:?}");
    }

    #[test]
    fn login_urls_round_trip_through_the_gateway_including_identity_hosts() {
        for raw in [
            "https://id.fudan.edu.cn/ac/?lck=1#/login?entityId=x",
            "https://elearning.fudan.edu.cn/login/cas?ticket=ST-1",
            "http://yjsxk.fudan.edu.cn/yjsxkapp/sys/a.do",
            "https://uis.fudan.edu.cn/authserver/login",
        ] {
            let logical = Url::parse(raw).unwrap();
            let mut physical = encode_url(&logical).unwrap();
            assert_eq!(physical.origin().ascii_serialization(), GATEWAY_ORIGIN);
            physical.set_fragment(logical.fragment());
            assert_eq!(decode_url(&physical), Some(logical));
        }
        let route = gateway_route("https://elearning.fudan.edu.cn", RouteMode::Gateway).unwrap();
        let logical = Url::parse("https://elearning.fudan.edu.cn/x").unwrap();
        assert_eq!(
            encode_url(&logical).unwrap(),
            route.encode(&logical).unwrap()
        );
        for outside in [
            "https://webvpn.fudan.edu.cn/login",
            "https://evil.example/",
            "https://fudan.edu.cn.evil.example/",
        ] {
            assert!(encode_url(&Url::parse(outside).unwrap()).is_err());
        }
        assert_eq!(
            decode_url(&Url::parse("https://webvpn.fudan.edu.cn/login?cas_login=true").unwrap()),
            None
        );
    }

    #[test]
    fn rewritten_page_links_read_as_the_site_wrote_them() {
        let elearning =
            encode_url(&Url::parse("https://elearning.fudan.edu.cn/").unwrap()).unwrap();
        let prefix = elearning.as_str().trim_end_matches('/');
        let path = elearning.path().trim_end_matches('/');
        let page = format!(
            r#"<a href="{prefix}/login/cas?ticket=ST-1">x</a><form action="{path}/a"></form>{{"u":"{}"}} <a href="https://webvpn.fudan.edu.cn/login">vpn</a>"#,
            prefix.replace('/', "\\/")
        );
        assert_eq!(
            decode_text(&page),
            r#"<a href="https://elearning.fudan.edu.cn/login/cas?ticket=ST-1">x</a><form action="https://elearning.fudan.edu.cn/a"></form>{"u":"https:\/\/elearning.fudan.edu.cn"} <a href="https://webvpn.fudan.edu.cn/login">vpn</a>"#
        );
        // Hosts outside Fudan never come out of a gateway link.
        let outside = format!("/https/{}", encoded_host("evil.example"));
        assert_eq!(decode_text(&outside), outside);
    }
}
