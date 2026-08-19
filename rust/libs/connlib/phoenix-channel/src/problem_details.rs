use serde::Deserialize;
use tokio_tungstenite::tungstenite::{handshake::client::Response, http::header::CONTENT_TYPE};

const PROBLEM_JSON: &str = "application/problem+json";

/// Why the portal rejected a request, as defined by [RFC 9457](https://www.rfc-editor.org/rfc/rfc9457).
///
/// Only the members the client acts upon are captured, the portal may send more.
#[derive(Debug, Default, PartialEq, Deserialize)]
pub(crate) struct ProblemDetails {
    /// A machine-readable identifier of the problem.
    ///
    /// Older portals don't send this yet.
    pub(crate) code: Option<String>,
    /// A human-readable explanation of the problem.
    pub(crate) detail: Option<String>,
}

impl ProblemDetails {
    /// Extracts the problem details from an HTTP response.
    ///
    /// Returns [`None`] for responses that aren't `application/problem+json` or whose body cannot be parsed,
    /// such as an error page served by an intermediary proxy.
    pub(crate) fn from_response(response: &Response) -> Option<Self> {
        let content_type = response.headers().get(CONTENT_TYPE)?.to_str().ok()?;

        if !is_problem_json(content_type) {
            return None;
        }

        let body = response.body().as_deref()?;
        let details = serde_json::from_slice(body).ok()?;

        Some(details)
    }
}

/// Checks whether the given `Content-Type` header value announces problem details.
///
/// Media types are case-insensitive and may carry parameters like `charset`.
fn is_problem_json(content_type: &str) -> bool {
    let media_type = content_type
        .split_once(';')
        .map_or(content_type, |(media_type, _)| media_type);

    media_type.trim().eq_ignore_ascii_case(PROBLEM_JSON)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio_tungstenite::tungstenite::http;

    #[test]
    fn parses_known_code() {
        let response = problem_details_response(
            r#"{"type":"about:blank","title":"Unauthorized","status":401,"detail":"Invalid token","code":"invalid_token"}"#,
        );

        let details = ProblemDetails::from_response(&response).unwrap();

        assert_eq!(details.code.as_deref(), Some("invalid_token"));
        assert_eq!(details.detail.as_deref(), Some("Invalid token"));
    }

    #[test]
    fn parses_unknown_code() {
        let response = problem_details_response(
            r#"{"status":403,"detail":"Device is not trusted","code":"device_untrusted"}"#,
        );

        let details = ProblemDetails::from_response(&response).unwrap();

        assert_eq!(details.code.as_deref(), Some("device_untrusted"));
    }

    #[test]
    fn parses_body_without_code() {
        let response = problem_details_response(
            r#"{"type":"about:blank","title":"Unauthorized","status":401,"detail":"Invalid token"}"#,
        );

        let details = ProblemDetails::from_response(&response).unwrap();

        assert_eq!(details.code, None);
        assert_eq!(details.detail.as_deref(), Some("Invalid token"));
    }

    #[test]
    fn ignores_malformed_json() {
        let response = problem_details_response("{not json");

        let details = ProblemDetails::from_response(&response);

        assert_eq!(details, None);
    }

    #[test]
    fn ignores_other_content_type() {
        let response = response("text/html", "<html>Gateway timeout</html>");

        let details = ProblemDetails::from_response(&response);

        assert_eq!(details, None);
    }

    #[test]
    fn ignores_missing_content_type() {
        let response = http::Response::builder()
            .status(http::StatusCode::UNAUTHORIZED)
            .body(Some(br#"{"code":"invalid_token"}"#.to_vec()))
            .unwrap();

        let details = ProblemDetails::from_response(&response);

        assert_eq!(details, None);
    }

    #[test]
    fn matches_content_type_regardless_of_case_and_parameters() {
        let response = response(
            "Application/Problem+JSON; charset=utf-8",
            r#"{"code":"missing_token"}"#,
        );

        let details = ProblemDetails::from_response(&response).unwrap();

        assert_eq!(details.code.as_deref(), Some("missing_token"));
    }

    fn problem_details_response(body: &str) -> Response {
        response("application/problem+json; charset=utf-8", body)
    }

    fn response(content_type: &str, body: &str) -> Response {
        http::Response::builder()
            .status(http::StatusCode::UNAUTHORIZED)
            .header(CONTENT_TYPE, content_type)
            .body(Some(body.as_bytes().to_vec()))
            .unwrap()
    }
}
