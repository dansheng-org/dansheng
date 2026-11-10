//! Generic, owner-configured application gateway routes. No school-specific URL
//! encoding, identity-provider endpoints or credentials belong in this module.
use crate::{CoreError, CoreResult};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use url::Url;

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RouteMode {
    #[default]
    Direct,
    Gateway,
    Auto,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct GatewayRoute {
    pub provider: String,
    pub origin: String,
    /// HTTPS gateway prefix, without query/fragment or the resource path.
    pub gateway_prefix: String,
    pub mode: RouteMode,
}

fn invalid() -> CoreError {
    CoreError::invalid("invalid application gateway route")
}
fn unsafe_route() -> CoreError {
    CoreError::new(
        "UnsafeRoute",
        "gateway URL is outside configured routing boundaries",
    )
}

pub fn validate_routes(routes: &[GatewayRoute]) -> CoreResult<()> {
    if routes.len() > 64 {
        return Err(invalid());
    }
    let mut origins = BTreeSet::new();
    let mut physical = BTreeSet::new();
    for route in routes {
        if route.provider.is_empty()
            || route.provider.len() > 64
            || !route
                .provider
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        {
            return Err(invalid());
        }
        let logical = Url::parse(&route.origin).map_err(|_| invalid())?;
        let gateway = Url::parse(&route.gateway_prefix).map_err(|_| invalid())?;
        if !matches!(logical.scheme(), "http" | "https")
            || logical.origin().ascii_serialization() != route.origin
            || !logical.username().is_empty()
            || logical.password().is_some()
            || gateway.scheme() != "https"
            || gateway.as_str() != route.gateway_prefix
            || !gateway.username().is_empty()
            || gateway.password().is_some()
            || gateway.query().is_some()
            || gateway.fragment().is_some()
            || gateway.path() == "/"
            || gateway.path().ends_with('/')
            || gateway.path().contains('%')
            || gateway.origin() == logical.origin()
            || route.gateway_prefix.len() > 4096
            || !origins.insert(route.origin.clone())
            || !physical.insert(route.gateway_prefix.clone())
        {
            return Err(invalid());
        }
    }
    // Prevent nested prefixes and gateway-as-target cycles inside one account.
    for a in routes {
        for b in routes {
            let gateway = Url::parse(&a.gateway_prefix).map_err(|_| invalid())?;
            if gateway.origin().ascii_serialization() == b.origin
                || (a.gateway_prefix != b.gateway_prefix
                    && b.gateway_prefix
                        .starts_with(&(a.gateway_prefix.clone() + "/")))
            {
                return Err(invalid());
            }
        }
    }
    Ok(())
}

impl GatewayRoute {
    pub fn gateway_origin(&self) -> CoreResult<String> {
        Ok(Url::parse(&self.gateway_prefix)
            .map_err(|_| invalid())?
            .origin()
            .ascii_serialization())
    }
    pub fn encode(&self, logical: &Url) -> CoreResult<Url> {
        if logical.origin().ascii_serialization() != self.origin {
            return Err(unsafe_route());
        }
        let path = logical.path().to_ascii_lowercase();
        // A gateway may normalize paths before dispatch. Refuse encoded separators
        // and double encoding rather than crossing the trusted prefix boundary.
        if ["%2f", "%5c", "%25", "%00"]
            .iter()
            .any(|v| path.contains(v))
        {
            return Err(unsafe_route());
        }
        let mut physical = Url::parse(&format!("{}{}", self.gateway_prefix, logical.path()))
            .map_err(|_| unsafe_route())?;
        physical.set_query(logical.query());
        physical.set_fragment(None);
        Ok(physical)
    }
    pub fn decode(&self, physical: &Url) -> CoreResult<Option<Url>> {
        let prefix = Url::parse(&self.gateway_prefix).map_err(|_| invalid())?;
        if physical.origin() != prefix.origin() {
            return Ok(None);
        }
        let Some(tail) = physical.path().strip_prefix(prefix.path()) else {
            return Ok(None);
        };
        if !tail.is_empty() && !tail.starts_with('/') {
            return Ok(None);
        }
        let mut logical = Url::parse(&format!(
            "{}{}",
            self.origin,
            if tail.is_empty() { "/" } else { tail }
        ))
        .map_err(|_| unsafe_route())?;
        logical.set_query(physical.query());
        if self.encode(&logical)?.path() != physical.path() && !tail.is_empty() {
            return Err(unsafe_route());
        }
        Ok(Some(logical))
    }
}

/// Convert a redirect or a pagination URI back into its authorized logical URL.
/// Gateway login/dashboard redirects require authentication instead of exposing
/// gateway URLs, cookies or identity-provider tickets to callers.
pub fn decode_location(
    routes: &[GatewayRoute],
    physical_base: &Url,
    location: &str,
) -> CoreResult<Url> {
    let next = physical_base.join(location).map_err(|_| unsafe_route())?;
    for route in routes {
        if let Some(logical) = route.decode(&next)? {
            return Ok(logical);
        }
    }
    if routes.iter().any(|r| {
        r.gateway_origin()
            .is_ok_and(|origin| origin == next.origin().ascii_serialization())
    }) {
        return Err(CoreError::new(
            "AuthenticationRequired",
            "gateway session requires renewed authentication",
        ));
    }
    if let Some(route) = routes.iter().find(|route| {
        route.mode != RouteMode::Direct && route.origin == next.origin().ascii_serialization()
    }) {
        route.encode(&next)?;
        return Ok(next);
    }
    if next.scheme() != "https" || !next.username().is_empty() || next.password().is_some() {
        return Err(unsafe_route());
    }
    Ok(next)
}

pub fn decode_link_header(
    routes: &[GatewayRoute],
    physical_base: &Url,
    value: &str,
) -> CoreResult<String> {
    if value.len() > 32768 {
        return Err(unsafe_route());
    }
    let mut result = String::new();
    let mut rest = value;
    while let Some(start) = rest.find('<') {
        result.push_str(&rest[..start + 1]);
        rest = &rest[start + 1..];
        let end = rest.find('>').ok_or_else(unsafe_route)?;
        let decoded = decode_location(routes, physical_base, &rest[..end])?;
        result.push_str(decoded.as_str());
        result.push('>');
        rest = &rest[end + 1..];
    }
    result.push_str(rest);
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn route() -> GatewayRoute {
        GatewayRoute {
            provider: "test.gateway".into(),
            origin: "https://campus.example".into(),
            gateway_prefix: "https://gateway.example/https/encoded".into(),
            mode: RouteMode::Gateway,
        }
    }
    #[test]
    fn routing_roundtrip_preserves_query_and_enforces_prefix_boundaries() {
        let route = route();
        validate_routes(std::slice::from_ref(&route)).unwrap();
        let logical =
            Url::parse("https://campus.example/api/v1/files?cursor=a%2Bb&per_page=30").unwrap();
        let physical = route.encode(&logical).unwrap();
        assert_eq!(
            physical.as_str(),
            "https://gateway.example/https/encoded/api/v1/files?cursor=a%2Bb&per_page=30"
        );
        assert_eq!(route.decode(&physical).unwrap(), Some(logical));
        assert!(
            route
                .decode(&Url::parse("https://gateway.example/https/encoded-other/a").unwrap())
                .unwrap()
                .is_none()
        );
        assert!(
            route
                .encode(&Url::parse("https://campus.example/%252f../different").unwrap())
                .is_err()
        );
        assert!(
            route
                .encode(&Url::parse("https://other.example/a").unwrap())
                .is_err()
        );
    }
    #[test]
    fn malformed_routes_cycles_and_gateway_login_redirects_fail_closed() {
        for prefix in [
            "http://gateway.example/p",
            "https://u:p@gateway.example/p",
            "https://gateway.example/",
            "https://gateway.example/p?secret=x",
            "https://campus.example/p",
            "https://gateway.example/%2f",
        ] {
            let mut value = route();
            value.gateway_prefix = prefix.into();
            assert!(validate_routes(&[value]).is_err());
        }
        let a = route();
        let mut b = route();
        b.origin = "https://other.example".into();
        b.gateway_prefix.push_str("/nested");
        assert!(validate_routes(&[a.clone(), b]).is_err());
        let physical = a
            .encode(&Url::parse("https://campus.example/data").unwrap())
            .unwrap();
        assert_eq!(
            decode_location(
                std::slice::from_ref(&a),
                &physical,
                "/login?ticket=sensitive"
            )
            .unwrap_err()
            .code,
            "AuthenticationRequired"
        );
        let link = "<https://gateway.example/https/encoded/api/v1/files?page=2>; rel=\"next\"";
        assert_eq!(
            decode_link_header(&[a], &physical, link).unwrap(),
            "<https://campus.example/api/v1/files?page=2>; rel=\"next\""
        );
    }
}
