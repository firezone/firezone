use std::{path::Path, time::Duration};

use anyhow::{Context as _, Result, bail};
use reqwest::{Client, Method, header::CONTENT_TYPE};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

use crate::{AndroidPrepare, http};

const API_ROOT: &str = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications";
const UPLOAD_ROOT: &str =
    "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications";

pub async fn prepare(args: AndroidPrepare) -> Result<()> {
    let bundle = read_file(&args.bundle)?;
    let screenshots = read_screenshots(&args.screenshot)?;
    let api = Api::new(args.access_token)?;
    let edit_id = api.create_edit(&args.package_name).await?;
    let version_code = api
        .upload_bundle(&args.package_name, &edit_id, bundle)
        .await?;
    let track = api.track(&args.package_name, &edit_id, &args.track).await?;
    let track = with_draft_release(
        track,
        &args.track,
        version_code,
        &args.version,
        &args.locale,
        &args.whats_new,
    )?;
    api.update_track(&args.package_name, &edit_id, &args.track, &track)
        .await?;
    api.replace_screenshots(&args.package_name, &edit_id, &args.locale, screenshots)
        .await?;
    api.commit(&args.package_name, &edit_id).await?;

    println!(
        "Prepared {} version {} ({version_code}) on the {} track without sending it for review",
        args.package_name, args.version, args.track
    );

    Ok(())
}

struct Api {
    client: Client,
    access_token: String,
}

impl Api {
    fn new(access_token: String) -> Result<Self> {
        let client = Client::builder()
            .timeout(Duration::from_secs(300))
            .build()
            .context("Failed to build the Google Play HTTP client")?;

        Ok(Self {
            client,
            access_token,
        })
    }

    async fn create_edit(&self, package: &str) -> Result<String> {
        let response: AppEdit = http::json(
            self.request(Method::POST, &format!("{API_ROOT}/{package}/edits")),
            "create a Google Play edit",
        )
        .await?;
        let id = response
            .id
            .context("Google Play returned an edit without an ID")?;

        Ok(id)
    }

    async fn upload_bundle(&self, package: &str, edit: &str, bytes: Vec<u8>) -> Result<i32> {
        let hash = hex::encode(Sha256::digest(&bytes));
        let response: Bundles = http::json(
            self.request(
                Method::GET,
                &format!("{API_ROOT}/{package}/edits/{edit}/bundles"),
            ),
            "list Google Play bundles",
        )
        .await?;

        if let Some(bundle) = response
            .bundles
            .into_iter()
            .find(|bundle| bundle.sha256.eq_ignore_ascii_case(&hash))
        {
            return Ok(bundle.version_code);
        }

        let bundle: Bundle = http::json(
            self.request(
                Method::POST,
                &format!("{UPLOAD_ROOT}/{package}/edits/{edit}/bundles"),
            )
            .query(&[("uploadType", "media")])
            .header(CONTENT_TYPE, "application/octet-stream")
            .body(bytes),
            "upload the Android App Bundle",
        )
        .await?;

        Ok(bundle.version_code)
    }

    async fn track(&self, package: &str, edit: &str, track: &str) -> Result<Value> {
        let track = http::json(
            self.request(
                Method::GET,
                &format!("{API_ROOT}/{package}/edits/{edit}/tracks/{track}"),
            ),
            "read the Google Play track",
        )
        .await?;

        Ok(track)
    }

    async fn update_track(
        &self,
        package: &str,
        edit: &str,
        track: &str,
        body: &Value,
    ) -> Result<()> {
        let _: Value = http::json(
            self.request(
                Method::PUT,
                &format!("{API_ROOT}/{package}/edits/{edit}/tracks/{track}"),
            )
            .json(body),
            "update the Google Play draft release",
        )
        .await?;

        Ok(())
    }

    async fn replace_screenshots(
        &self,
        package: &str,
        edit: &str,
        locale: &str,
        screenshots: Vec<Vec<u8>>,
    ) -> Result<()> {
        let path = format!("{API_ROOT}/{package}/edits/{edit}/listings/{locale}/phoneScreenshots");
        http::empty(
            self.request(Method::DELETE, &path),
            "clear Google Play phone screenshots",
        )
        .await?;

        for bytes in screenshots {
            let path =
                format!("{UPLOAD_ROOT}/{package}/edits/{edit}/listings/{locale}/phoneScreenshots");
            let _: Value = http::json(
                self.request(Method::POST, &path)
                    .query(&[
                        ("uploadType", "media"),
                        ("aiGeneratedState", "aiGeneratedStateNotAiGenerated"),
                    ])
                    .header(CONTENT_TYPE, "image/png")
                    .body(bytes),
                "upload a Google Play screenshot",
            )
            .await?;
        }

        Ok(())
    }

    async fn commit(&self, package: &str, edit: &str) -> Result<()> {
        let _: AppEdit = http::json(
            self.request(
                Method::POST,
                &format!("{API_ROOT}/{package}/edits/{edit}:commit"),
            )
            .query(&[
                ("changesNotSentForReview", "true"),
                ("changesInReviewBehavior", "ERROR_IF_IN_REVIEW"),
            ]),
            "commit the Google Play edit",
        )
        .await?;

        Ok(())
    }

    fn request(&self, method: Method, url: &str) -> reqwest::RequestBuilder {
        self.client
            .request(method, url)
            .bearer_auth(&self.access_token)
    }
}

fn with_draft_release(
    mut track: Value,
    track_name: &str,
    version_code: i32,
    version: &str,
    locale: &str,
    whats_new: &str,
) -> Result<Value> {
    let object = track
        .as_object_mut()
        .context("Google Play returned a track that is not an object")?;
    object.insert("track".to_owned(), json!(track_name));
    let releases = object
        .entry("releases")
        .or_insert_with(|| json!([]))
        .as_array_mut()
        .context("Google Play returned track releases that are not an array")?;
    releases
        .extract_if(.., |release| release.get("status") == Some(&json!("draft")))
        .for_each(drop);
    releases.push(json!({
        "name": version,
        "versionCodes": [version_code.to_string()],
        "status": "draft",
        "releaseNotes": [{
            "language": locale,
            "text": whats_new,
        }],
    }));

    Ok(track)
}

fn read_screenshots(paths: &[impl AsRef<Path>]) -> Result<Vec<Vec<u8>>> {
    if !(2..=8).contains(&paths.len()) {
        bail!("Google Play requires between 2 and 8 phone screenshots");
    }

    paths.iter().map(|path| read_file(path.as_ref())).collect()
}

fn read_file(path: &Path) -> Result<Vec<u8>> {
    let metadata = path
        .metadata()
        .with_context(|| format!("Missing file {}", path.display()))?;
    if !metadata.is_file() || metadata.len() == 0 {
        bail!("{} is not a non-empty file", path.display());
    }

    let bytes =
        std::fs::read(path).with_context(|| format!("Failed to read {}", path.display()))?;

    Ok(bytes)
}

#[derive(Deserialize)]
struct AppEdit {
    id: Option<String>,
}

#[derive(Deserialize)]
struct Bundles {
    #[serde(default)]
    bundles: Vec<Bundle>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Bundle {
    version_code: i32,
    #[serde(default)]
    sha256: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replaces_only_draft_releases() {
        let input = json!({
            "track": "internal",
            "releases": [
                {"name": "published", "status": "completed", "versionCodes": ["7"]},
                {"name": "old draft", "status": "draft", "versionCodes": ["8"]},
            ],
        });
        let Ok(actual) = with_draft_release(
            input,
            "internal",
            9,
            "1.2.3",
            "en-US",
            "https://www.firezone.dev/changelog",
        ) else {
            panic!("valid track should be updated");
        };
        let expected = json!({
            "track": "internal",
            "releases": [
                {"name": "published", "status": "completed", "versionCodes": ["7"]},
                {
                    "name": "1.2.3",
                    "status": "draft",
                    "versionCodes": ["9"],
                    "releaseNotes": [{
                        "language": "en-US",
                        "text": "https://www.firezone.dev/changelog",
                    }],
                },
            ],
        });

        assert_eq!(actual, expected);
    }
}
