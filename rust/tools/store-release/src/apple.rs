use std::{
    path::Path,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context as _, Result, anyhow, bail};
use base64::{Engine as _, prelude::BASE64_STANDARD, prelude::BASE64_URL_SAFE_NO_PAD};
use reqwest::{Client, Method};
use ring::{
    rand::SystemRandom,
    signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair},
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest as _, Sha256};
use tokio::time::sleep;

use crate::{
    AppleAuth, ApplePlatform, ApplePrepareVersion, AppleScreenshot, AppleUploadBuild, http,
};

const API_ROOT: &str = "https://api.appstoreconnect.apple.com/v1";
const BUILD_POLL_INTERVAL: Duration = Duration::from_secs(15);
const BUILD_POLLS: usize = 120;
const SCREENSHOT_POLL_INTERVAL: Duration = Duration::from_secs(2);
const SCREENSHOT_POLLS: usize = 150;

pub async fn upload_build(args: AppleUploadBuild) -> Result<()> {
    let artifact = File::read(&args.artifact)?;
    let uti = artifact_uti(&args.artifact)?;
    let api = Api::new(args.auth)?;
    let app_id = api.app_id(&args.bundle_id).await?;

    if let Some(build_id) = api
        .existing_build(&app_id, &args.version, &args.build_number, args.platform)
        .await?
    {
        println!(
            "Apple build {} ({}) for {} is already uploaded as {build_id}",
            args.version,
            args.build_number,
            args.platform.api_name()
        );
        return Ok(());
    }

    let upload = api
        .create_build_upload(&app_id, &args.version, &args.build_number, args.platform)
        .await?;
    let upload_file = api
        .create_build_upload_file(&upload.id, &artifact, uti)
        .await?;
    upload_operations(&api.client, &artifact.bytes, upload_file.operations()?).await?;
    api.commit_build_upload_file(&upload_file.id, &artifact)
        .await?;
    let build_id = api.wait_for_build(&upload.id).await?;

    println!(
        "Uploaded Apple build {} ({}) for {} as {build_id}",
        args.version,
        args.build_number,
        args.platform.api_name()
    );

    Ok(())
}

pub async fn prepare_version(args: ApplePrepareVersion) -> Result<()> {
    let screenshots = ScreenshotGroups::read(args.platform, args.screenshot)?;
    let api = Api::new(args.auth)?;
    let app_id = api.app_id(&args.bundle_id).await?;
    let build_id = api
        .required_build(&app_id, &args.version, &args.build_number, args.platform)
        .await?;
    let version = api
        .version(&app_id, &args.version, args.platform, &args.locale)
        .await?;
    api.set_build(&version.id, &build_id).await?;
    let localization = api
        .localization(
            &version.id,
            &args.locale,
            &args.whats_new,
            version.source_localization,
        )
        .await?;
    api.set_whats_new(&localization.id, &args.whats_new).await?;

    for group in screenshots.groups {
        api.reconcile_screenshots(&localization.id, group).await?;
    }

    println!(
        "Prepared Apple version {} ({}) for {} without submitting it for review",
        args.version,
        args.build_number,
        args.platform.api_name()
    );

    Ok(())
}

struct Api {
    client: Client,
    issuer_id: String,
    key_id: String,
    key_pair: EcdsaKeyPair,
}

impl Api {
    fn new(auth: AppleAuth) -> Result<Self> {
        let key = decode_private_key(&auth.private_key_base64)?;
        let rng = SystemRandom::new();
        let key_pair = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &key, &rng)
            .map_err(|error| anyhow!("Failed to parse the App Store Connect key: {error:?}"))?;
        let client = Client::builder()
            .timeout(Duration::from_secs(300))
            .build()
            .context("Failed to build the App Store Connect HTTP client")?;

        Ok(Self {
            client,
            issuer_id: auth.issuer_id,
            key_id: auth.key_id,
            key_pair,
        })
    }

    async fn app_id(&self, bundle_id: &str) -> Result<String> {
        let response: List<Resource> = http::json(
            self.request(Method::GET, "/apps")?
                .query(&[("filter[bundleId]", bundle_id), ("limit", "2")]),
            "find the App Store Connect app",
        )
        .await?;
        let [app] = response.data.as_slice() else {
            bail!(
                "Expected one App Store Connect app for {bundle_id}, found {}",
                response.data.len()
            );
        };

        Ok(app.id.clone())
    }

    async fn existing_build(
        &self,
        app: &str,
        version: &str,
        build_number: &str,
        platform: ApplePlatform,
    ) -> Result<Option<String>> {
        let uploads = self
            .build_uploads(app, version, build_number, platform)
            .await?;

        if let Some(upload) = uploads.iter().find(|upload| upload.state() == "COMPLETE") {
            let build_id = upload.build_id()?;
            return Ok(Some(build_id));
        }
        if let Some(upload) = uploads.iter().find(|upload| upload.state() == "PROCESSING") {
            let build_id = self.wait_for_build(&upload.id).await?;
            return Ok(Some(build_id));
        }

        for upload in uploads {
            self.delete_build_upload(&upload.id).await?;
        }

        Ok(None)
    }

    async fn required_build(
        &self,
        app: &str,
        version: &str,
        build_number: &str,
        platform: ApplePlatform,
    ) -> Result<String> {
        let uploads = self
            .build_uploads(app, version, build_number, platform)
            .await?;
        let upload = uploads
            .iter()
            .find(|upload| matches!(upload.state(), "COMPLETE" | "PROCESSING"))
            .with_context(|| {
                format!(
                    "Apple build {version} ({build_number}) for {} has not been uploaded",
                    platform.api_name()
                )
            })?;

        if upload.state() == "COMPLETE" {
            return upload.build_id();
        }

        let build_id = self.wait_for_build(&upload.id).await?;

        Ok(build_id)
    }

    async fn build_uploads(
        &self,
        app: &str,
        version: &str,
        build_number: &str,
        platform: ApplePlatform,
    ) -> Result<Vec<BuildUpload>> {
        let response: List<BuildUpload> = http::json(
            self.request(Method::GET, &format!("/apps/{app}/buildUploads"))?
                .query(&[
                    ("filter[cfBundleShortVersionString]", version),
                    ("filter[cfBundleVersion]", build_number),
                    ("filter[platform]", platform.api_name()),
                    ("include", "build"),
                    ("sort", "-uploadedDate"),
                    ("limit", "200"),
                ]),
            "list App Store Connect build uploads",
        )
        .await?;

        Ok(response.data)
    }

    async fn create_build_upload(
        &self,
        app: &str,
        version: &str,
        build_number: &str,
        platform: ApplePlatform,
    ) -> Result<BuildUpload> {
        let response: Single<BuildUpload> = http::json(
            self.request(Method::POST, "/buildUploads")?.json(&json!({
                "data": {
                    "type": "buildUploads",
                    "attributes": {
                        "cfBundleShortVersionString": version,
                        "cfBundleVersion": build_number,
                        "platform": platform.api_name(),
                    },
                    "relationships": {
                        "app": {"data": {"type": "apps", "id": app}},
                    },
                },
            })),
            "create an App Store Connect build upload",
        )
        .await?;

        Ok(response.data)
    }

    async fn create_build_upload_file(
        &self,
        upload: &str,
        artifact: &File,
        uti: &str,
    ) -> Result<UploadFile> {
        let response: Single<UploadFile> = http::json(
            self.request(Method::POST, "/buildUploadFiles")?
                .json(&json!({
                    "data": {
                        "type": "buildUploadFiles",
                        "attributes": {
                            "assetType": "ASSET",
                            "fileName": artifact.name,
                            "fileSize": artifact.bytes.len(),
                            "uti": uti,
                        },
                        "relationships": {
                            "buildUpload": {
                                "data": {"type": "buildUploads", "id": upload},
                            },
                        },
                    },
                })),
            "reserve the App Store Connect build file",
        )
        .await?;

        Ok(response.data)
    }

    async fn commit_build_upload_file(&self, upload_file: &str, artifact: &File) -> Result<()> {
        let hash = hex::encode(Sha256::digest(&artifact.bytes));
        let _: Single<UploadFile> = http::json(
            self.request(Method::PATCH, &format!("/buildUploadFiles/{upload_file}"))?
                .json(&json!({
                    "data": {
                        "type": "buildUploadFiles",
                        "id": upload_file,
                        "attributes": {
                            "uploaded": true,
                            "sourceFileChecksums": {
                                "file": {"algorithm": "SHA_256", "hash": hash},
                            },
                        },
                    },
                })),
            "commit the App Store Connect build file",
        )
        .await?;

        Ok(())
    }

    async fn wait_for_build(&self, upload_id: &str) -> Result<String> {
        for _ in 0..BUILD_POLLS {
            let response: Single<BuildUpload> = http::json(
                self.request(Method::GET, &format!("/buildUploads/{upload_id}"))?
                    .query(&[("include", "build")]),
                "read the App Store Connect build upload",
            )
            .await?;

            match response.data.state() {
                "COMPLETE" => return response.data.build_id(),
                "FAILED" => bail!(
                    "App Store Connect rejected the build upload: {}",
                    response.data.state_details()
                ),
                "AWAITING_UPLOAD" | "PROCESSING" | "" => sleep(BUILD_POLL_INTERVAL).await,
                state => bail!("App Store Connect returned unknown build upload state {state}"),
            }
        }

        bail!("Timed out waiting for App Store Connect to process the build");
    }

    async fn delete_build_upload(&self, upload_id: &str) -> Result<()> {
        http::empty(
            self.request(Method::DELETE, &format!("/buildUploads/{upload_id}"))?,
            "remove an incomplete App Store Connect build upload",
        )
        .await?;

        Ok(())
    }

    async fn version(
        &self,
        app: &str,
        version: &str,
        platform: ApplePlatform,
        locale: &str,
    ) -> Result<PreparedVersion> {
        let response: List<AppStoreVersion> = http::json(
            self.request(Method::GET, &format!("/apps/{app}/appStoreVersions"))?
                .query(&[
                    ("filter[platform]", platform.api_name()),
                    ("filter[versionString]", version),
                    ("limit", "2"),
                ]),
            "find the App Store version",
        )
        .await?;

        match response.data.as_slice() {
            [existing] => {
                ensure_editable(existing)?;
                Ok(PreparedVersion {
                    id: existing.id.clone(),
                    source_localization: None,
                })
            }
            [] => {
                let source_localization = self
                    .latest_localization(app, version, platform, locale)
                    .await?;
                let response: Single<AppStoreVersion> = http::json(
                    self.request(Method::POST, "/appStoreVersions")?
                        .json(&json!({
                            "data": {
                                "type": "appStoreVersions",
                                "attributes": {
                                    "platform": platform.api_name(),
                                    "versionString": version,
                                    "releaseType": "MANUAL",
                                },
                                "relationships": {
                                    "app": {"data": {"type": "apps", "id": app}},
                                },
                            },
                        })),
                    "create the App Store version",
                )
                .await?;

                Ok(PreparedVersion {
                    id: response.data.id,
                    source_localization,
                })
            }
            versions => bail!(
                "Expected at most one App Store version {version} for {}, found {}",
                platform.api_name(),
                versions.len()
            ),
        }
    }

    async fn latest_localization(
        &self,
        app: &str,
        target_version: &str,
        platform: ApplePlatform,
        locale: &str,
    ) -> Result<Option<LocalizationAttributes>> {
        let response: List<AppStoreVersion> = http::json(
            self.request(Method::GET, &format!("/apps/{app}/appStoreVersions"))?
                .query(&[("filter[platform]", platform.api_name()), ("limit", "200")]),
            "list existing App Store versions",
        )
        .await?;
        let latest = response
            .data
            .into_iter()
            .filter(|candidate| candidate.attributes.version_string != target_version)
            .max_by(|left, right| {
                left.attributes
                    .created_date
                    .cmp(&right.attributes.created_date)
            });
        let Some(latest) = latest else {
            return Ok(None);
        };

        let localization = self.find_localization(&latest.id, locale).await?;
        let attributes = localization.map(|localization| localization.attributes);

        Ok(attributes)
    }

    async fn set_build(&self, version: &str, build: &str) -> Result<()> {
        let current: Linkage = http::json(
            self.request(
                Method::GET,
                &format!("/appStoreVersions/{version}/relationships/build"),
            )?,
            "read the selected App Store build",
        )
        .await?;
        if current.data.as_ref().map(|data| data.id.as_str()) == Some(build) {
            return Ok(());
        }

        http::empty(
            self.request(
                Method::PATCH,
                &format!("/appStoreVersions/{version}/relationships/build"),
            )?
            .json(&json!({"data": {"type": "builds", "id": build}})),
            "select the App Store build",
        )
        .await?;

        Ok(())
    }

    async fn localization(
        &self,
        version: &str,
        locale: &str,
        whats_new: &str,
        source: Option<LocalizationAttributes>,
    ) -> Result<AppStoreLocalization> {
        if let Some(localization) = self.find_localization(version, locale).await? {
            return Ok(localization);
        }

        let mut attributes = source.unwrap_or_else(|| LocalizationAttributes {
            locale: locale.to_owned(),
            ..Default::default()
        });
        attributes.locale = locale.to_owned();
        attributes.whats_new = Some(whats_new.to_owned());
        let response: Single<AppStoreLocalization> = http::json(
            self.request(Method::POST, "/appStoreVersionLocalizations")?
                .json(&json!({
                    "data": {
                        "type": "appStoreVersionLocalizations",
                        "attributes": attributes,
                        "relationships": {
                            "appStoreVersion": {
                                "data": {"type": "appStoreVersions", "id": version},
                            },
                        },
                    },
                })),
            "create the App Store version localization",
        )
        .await?;

        Ok(response.data)
    }

    async fn find_localization(
        &self,
        version: &str,
        locale: &str,
    ) -> Result<Option<AppStoreLocalization>> {
        let response: List<AppStoreLocalization> = http::json(
            self.request(
                Method::GET,
                &format!("/appStoreVersions/{version}/appStoreVersionLocalizations"),
            )?
            .query(&[("filter[locale]", locale), ("limit", "2")]),
            "find the App Store version localization",
        )
        .await?;

        match response.data.len() {
            0 => Ok(None),
            1 => Ok(response.data.into_iter().next()),
            count => bail!("Expected at most one {locale} localization, found {count}"),
        }
    }

    async fn set_whats_new(&self, localization: &str, whats_new: &str) -> Result<()> {
        let _: Single<AppStoreLocalization> = http::json(
            self.request(
                Method::PATCH,
                &format!("/appStoreVersionLocalizations/{localization}"),
            )?
            .json(&json!({
                "data": {
                    "type": "appStoreVersionLocalizations",
                    "id": localization,
                    "attributes": {"whatsNew": whats_new},
                },
            })),
            "set the App Store What's New text",
        )
        .await?;

        Ok(())
    }

    async fn reconcile_screenshots(
        &self,
        localization: &str,
        group: ScreenshotGroup,
    ) -> Result<()> {
        let set_id = self
            .screenshot_set(localization, &group.display_type)
            .await?;
        let current = self.screenshots(&set_id).await?;
        let expected = group
            .files
            .iter()
            .map(|file| (file.name.as_str(), file.md5.as_str()))
            .collect::<Vec<_>>();
        let actual = current
            .iter()
            .map(|screenshot| {
                (
                    screenshot.attributes.file_name.as_str(),
                    screenshot.attributes.source_file_checksum.as_deref(),
                    screenshot.attributes.state(),
                )
            })
            .collect::<Vec<_>>();
        if actual.len() == expected.len()
            && actual.iter().zip(&expected).all(|(actual, expected)| {
                actual.0 == expected.0
                    && actual
                        .1
                        .is_some_and(|checksum| checksum.eq_ignore_ascii_case(expected.1))
                    && actual.2 == "COMPLETE"
            })
        {
            return Ok(());
        }

        for screenshot in current {
            http::empty(
                self.request(
                    Method::DELETE,
                    &format!("/appScreenshots/{}", screenshot.id),
                )?,
                "remove an old App Store screenshot",
            )
            .await?;
        }

        let mut uploaded = Vec::with_capacity(group.files.len());
        for file in group.files {
            uploaded.push(self.upload_screenshot(&set_id, file).await?);
        }
        self.wait_for_screenshots(&set_id, &uploaded).await?;

        Ok(())
    }

    async fn screenshot_set(&self, localization: &str, display_type: &str) -> Result<String> {
        let response: List<AppScreenshotSet> = http::json(
            self.request(
                Method::GET,
                &format!("/appStoreVersionLocalizations/{localization}/appScreenshotSets"),
            )?
            .query(&[
                ("filter[screenshotDisplayType]", display_type),
                ("limit", "2"),
            ]),
            "find the App Store screenshot set",
        )
        .await?;

        match response.data.as_slice() {
            [set] => Ok(set.id.clone()),
            [] => {
                let response: Single<AppScreenshotSet> = http::json(
                    self.request(Method::POST, "/appScreenshotSets")?
                        .json(&json!({
                            "data": {
                                "type": "appScreenshotSets",
                                "attributes": {"screenshotDisplayType": display_type},
                                "relationships": {
                                    "appStoreVersionLocalization": {
                                        "data": {
                                            "type": "appStoreVersionLocalizations",
                                            "id": localization,
                                        },
                                    },
                                },
                            },
                        })),
                    "create the App Store screenshot set",
                )
                .await?;

                Ok(response.data.id)
            }
            sets => bail!(
                "Expected at most one {display_type} screenshot set, found {}",
                sets.len()
            ),
        }
    }

    async fn screenshots(&self, set: &str) -> Result<Vec<AppScreenshot>> {
        let response: List<AppScreenshot> = http::json(
            self.request(
                Method::GET,
                &format!("/appScreenshotSets/{set}/appScreenshots"),
            )?
            .query(&[("limit", "200")]),
            "list App Store screenshots",
        )
        .await?;

        Ok(response.data)
    }

    async fn upload_screenshot(&self, set: &str, file: ScreenshotFile) -> Result<String> {
        let response: Single<AppScreenshot> = http::json(
            self.request(Method::POST, "/appScreenshots")?.json(&json!({
                "data": {
                    "type": "appScreenshots",
                    "attributes": {
                        "fileName": file.name,
                        "fileSize": file.bytes.len(),
                    },
                    "relationships": {
                        "appScreenshotSet": {
                            "data": {"type": "appScreenshotSets", "id": set},
                        },
                    },
                },
            })),
            "reserve an App Store screenshot",
        )
        .await?;
        upload_operations(
            &self.client,
            &file.bytes,
            response.data.attributes.operations()?,
        )
        .await?;
        let id = response.data.id;
        let _: Single<AppScreenshot> = http::json(
            self.request(Method::PATCH, &format!("/appScreenshots/{id}"))?
                .json(&json!({
                    "data": {
                        "type": "appScreenshots",
                        "id": id,
                        "attributes": {
                            "uploaded": true,
                            "sourceFileChecksum": file.md5,
                        },
                    },
                })),
            "commit an App Store screenshot",
        )
        .await?;

        Ok(id)
    }

    async fn wait_for_screenshots(&self, set: &str, expected_ids: &[String]) -> Result<()> {
        for _ in 0..SCREENSHOT_POLLS {
            let screenshots = self.screenshots(set).await?;
            let expected = screenshots
                .iter()
                .filter(|screenshot| expected_ids.contains(&screenshot.id))
                .collect::<Vec<_>>();
            if let Some(failed) = expected
                .iter()
                .find(|screenshot| screenshot.attributes.state() == "FAILED")
            {
                bail!(
                    "App Store Connect rejected screenshot {}: {}",
                    failed.attributes.file_name,
                    failed.attributes.state_details()
                );
            }
            if expected.len() == expected_ids.len()
                && expected
                    .iter()
                    .all(|screenshot| screenshot.attributes.state() == "COMPLETE")
            {
                return Ok(());
            }

            sleep(SCREENSHOT_POLL_INTERVAL).await;
        }

        bail!("Timed out waiting for App Store Connect to process screenshots");
    }

    fn request(&self, method: Method, path: &str) -> Result<reqwest::RequestBuilder> {
        let token = self.token()?;
        let request = self
            .client
            .request(method, format!("{API_ROOT}{path}"))
            .bearer_auth(token);

        Ok(request)
    }

    fn token(&self) -> Result<String> {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .context("System clock is before the Unix epoch")?
            .as_secs();
        let header = BASE64_URL_SAFE_NO_PAD.encode(serde_json::to_vec(&JwtHeader {
            alg: "ES256",
            kid: &self.key_id,
            typ: "JWT",
        })?);
        let claims = BASE64_URL_SAFE_NO_PAD.encode(serde_json::to_vec(&JwtClaims {
            iss: &self.issuer_id,
            iat: now,
            exp: now + 15 * 60,
            aud: "appstoreconnect-v1",
        })?);
        let signing_input = format!("{header}.{claims}");
        let signature = self
            .key_pair
            .sign(&SystemRandom::new(), signing_input.as_bytes())
            .map_err(|error| anyhow!("Failed to sign the App Store Connect token: {error:?}"))?;
        let signature = BASE64_URL_SAFE_NO_PAD.encode(signature.as_ref());

        Ok(format!("{signing_input}.{signature}"))
    }
}

async fn upload_operations(
    client: &Client,
    bytes: &[u8],
    operations: &[UploadOperation],
) -> Result<()> {
    if operations.is_empty() {
        bail!("App Store Connect returned no upload operations");
    }

    for operation in operations {
        let end = operation
            .offset
            .checked_add(operation.length)
            .context("App Store Connect returned an overflowing upload range")?;
        let chunk = bytes
            .get(operation.offset..end)
            .context("App Store Connect returned an upload range outside the file")?;
        let method = Method::from_bytes(operation.method.as_bytes())
            .context("App Store Connect returned an invalid upload method")?;
        let mut request = client.request(method, &operation.url).body(chunk.to_vec());
        for header in &operation.request_headers {
            request = request.header(header.name.as_str(), header.value.as_str());
        }
        http::empty(request, "upload bytes reserved by App Store Connect").await?;
    }

    Ok(())
}

fn decode_private_key(encoded: &str) -> Result<Vec<u8>> {
    let decoded = BASE64_STANDARD
        .decode(encoded.trim())
        .context("App Store Connect key is not base64")?;
    if !decoded.starts_with(b"-----BEGIN") {
        return Ok(decoded);
    }

    let pem = std::str::from_utf8(&decoded).context("App Store Connect key is not UTF-8 PEM")?;
    let body = pem
        .lines()
        .filter(|line| !line.starts_with("-----"))
        .collect::<String>();
    let der = BASE64_STANDARD
        .decode(body)
        .context("App Store Connect PEM body is not base64")?;

    Ok(der)
}

fn artifact_uti(path: &Path) -> Result<&'static str> {
    match path.extension().and_then(|extension| extension.to_str()) {
        Some("ipa") => Ok("com.apple.ipa"),
        Some("pkg") => Ok("com.apple.pkg"),
        _ => bail!("Apple build artifact must have an .ipa or .pkg extension"),
    }
}

fn ensure_editable(version: &AppStoreVersion) -> Result<()> {
    let state = version.attributes.app_version_state.as_str();
    if matches!(
        state,
        "PREPARE_FOR_SUBMISSION"
            | "READY_FOR_REVIEW"
            | "DEVELOPER_REJECTED"
            | "METADATA_REJECTED"
            | "REJECTED"
            | "INVALID_BINARY"
    ) {
        return Ok(());
    }

    bail!(
        "App Store version {} is not editable (state {state})",
        version.attributes.version_string
    );
}

struct ScreenshotGroups {
    groups: Vec<ScreenshotGroup>,
}

impl ScreenshotGroups {
    fn read(platform: ApplePlatform, screenshots: Vec<AppleScreenshot>) -> Result<Self> {
        let mut groups: Vec<ScreenshotGroup> = Vec::new();

        for screenshot in screenshots {
            validate_display_type(platform, &screenshot.display_type)?;
            let file = ScreenshotFile::read(&screenshot.path)?;
            let group = match groups
                .iter_mut()
                .find(|group| group.display_type == screenshot.display_type)
            {
                Some(group) => group,
                None => {
                    groups.push(ScreenshotGroup {
                        display_type: screenshot.display_type.clone(),
                        files: Vec::new(),
                    });
                    groups
                        .last_mut()
                        .context("Failed to create a screenshot group")?
                }
            };
            if group
                .files
                .iter()
                .any(|existing| existing.name == file.name)
            {
                bail!(
                    "Screenshot {} is listed more than once for {}",
                    file.name,
                    group.display_type
                );
            }
            group.files.push(file);
        }

        if groups.is_empty() {
            bail!("At least one App Store screenshot is required");
        }
        if let Some(group) = groups.iter().find(|group| group.files.len() > 10) {
            bail!(
                "App Store screenshot set {} contains more than 10 images",
                group.display_type
            );
        }

        Ok(Self { groups })
    }
}

fn validate_display_type(platform: ApplePlatform, display_type: &str) -> Result<()> {
    let valid = match platform {
        ApplePlatform::Ios => matches!(display_type, "APP_IPHONE_67" | "APP_IPAD_PRO_3GEN_129"),
        ApplePlatform::MacOs => display_type == "APP_DESKTOP",
    };
    if !valid {
        bail!(
            "Screenshot display type {display_type} is not supported for {}",
            platform.api_name()
        );
    }

    Ok(())
}

struct ScreenshotGroup {
    display_type: String,
    files: Vec<ScreenshotFile>,
}

struct ScreenshotFile {
    name: String,
    bytes: Vec<u8>,
    md5: String,
}

impl ScreenshotFile {
    fn read(path: &Path) -> Result<Self> {
        let file = File::read(path)?;
        let md5 = format!("{:x}", md5::compute(&file.bytes));

        Ok(Self {
            name: file.name,
            bytes: file.bytes,
            md5,
        })
    }
}

struct File {
    name: String,
    bytes: Vec<u8>,
}

impl File {
    fn read(path: &Path) -> Result<Self> {
        let metadata = path
            .metadata()
            .with_context(|| format!("Missing file {}", path.display()))?;
        if !metadata.is_file() || metadata.len() == 0 {
            bail!("{} is not a non-empty file", path.display());
        }
        let name = path
            .file_name()
            .and_then(|name| name.to_str())
            .with_context(|| format!("{} has no UTF-8 file name", path.display()))?
            .to_owned();
        let bytes =
            std::fs::read(path).with_context(|| format!("Failed to read {}", path.display()))?;

        Ok(Self { name, bytes })
    }
}

#[derive(Serialize)]
struct JwtHeader<'a> {
    alg: &'a str,
    kid: &'a str,
    typ: &'a str,
}

#[derive(Serialize)]
struct JwtClaims<'a> {
    iss: &'a str,
    iat: u64,
    exp: u64,
    aud: &'a str,
}

#[derive(Deserialize)]
struct List<T> {
    data: Vec<T>,
}

#[derive(Deserialize)]
struct Single<T> {
    data: T,
}

#[derive(Deserialize)]
struct Resource {
    id: String,
}

#[derive(Deserialize)]
struct BuildUpload {
    id: String,
    #[serde(default)]
    attributes: BuildUploadAttributes,
    #[serde(default)]
    relationships: BuildUploadRelationships,
}

impl BuildUpload {
    fn state(&self) -> &str {
        &self.attributes.state.state
    }

    fn state_details(&self) -> String {
        self.attributes.state.details()
    }

    fn build_id(&self) -> Result<String> {
        let id = self
            .relationships
            .build
            .as_ref()
            .and_then(|relationship| relationship.data.as_ref())
            .map(|data| data.id.clone())
            .context("Completed App Store Connect upload has no build")?;

        Ok(id)
    }
}

#[derive(Default, Deserialize)]
struct BuildUploadAttributes {
    #[serde(default)]
    state: State,
}

#[derive(Default, Deserialize)]
struct BuildUploadRelationships {
    build: Option<Relationship>,
}

#[derive(Deserialize)]
struct Relationship {
    data: Option<Resource>,
}

#[derive(Default, Deserialize)]
struct State {
    #[serde(default)]
    state: String,
    #[serde(default)]
    errors: Vec<StateDetail>,
}

impl State {
    fn details(&self) -> String {
        self.errors
            .iter()
            .map(|error| format!("{}: {}", error.code, error.description))
            .collect::<Vec<_>>()
            .join("; ")
    }
}

#[derive(Deserialize)]
struct StateDetail {
    #[serde(default)]
    code: String,
    #[serde(default)]
    description: String,
}

#[derive(Deserialize)]
struct UploadFile {
    id: String,
    attributes: UploadAttributes,
}

impl UploadFile {
    fn operations(&self) -> Result<&[UploadOperation]> {
        self.attributes.operations()
    }
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UploadAttributes {
    #[serde(default)]
    upload_operations: Vec<UploadOperation>,
    #[serde(default)]
    asset_delivery_state: State,
}

impl UploadAttributes {
    fn operations(&self) -> Result<&[UploadOperation]> {
        if self.upload_operations.is_empty() {
            bail!("App Store Connect returned no upload operations");
        }

        Ok(&self.upload_operations)
    }

    fn state(&self) -> &str {
        &self.asset_delivery_state.state
    }

    fn state_details(&self) -> String {
        self.asset_delivery_state.details()
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct UploadOperation {
    method: String,
    url: String,
    length: usize,
    offset: usize,
    #[serde(default)]
    request_headers: Vec<UploadHeader>,
}

#[derive(Deserialize)]
struct UploadHeader {
    name: String,
    value: String,
}

struct PreparedVersion {
    id: String,
    source_localization: Option<LocalizationAttributes>,
}

#[derive(Deserialize)]
struct AppStoreVersion {
    id: String,
    attributes: VersionAttributes,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct VersionAttributes {
    #[serde(default)]
    app_version_state: String,
    #[serde(default)]
    version_string: String,
    #[serde(default)]
    created_date: String,
}

#[derive(Deserialize)]
struct Linkage {
    data: Option<Resource>,
}

#[derive(Deserialize)]
struct AppStoreLocalization {
    id: String,
    attributes: LocalizationAttributes,
}

#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct LocalizationAttributes {
    locale: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    keywords: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    marketing_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    promotional_text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    support_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    whats_new: Option<String>,
}

#[derive(Deserialize)]
struct AppScreenshotSet {
    id: String,
}

#[derive(Deserialize)]
struct AppScreenshot {
    id: String,
    #[serde(default)]
    attributes: ScreenshotAttributes,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ScreenshotAttributes {
    #[serde(default)]
    file_name: String,
    source_file_checksum: Option<String>,
    #[serde(default)]
    upload_operations: Vec<UploadOperation>,
    #[serde(default)]
    asset_delivery_state: State,
}

impl ScreenshotAttributes {
    fn operations(&self) -> Result<&[UploadOperation]> {
        if self.upload_operations.is_empty() {
            bail!("App Store Connect returned no screenshot upload operations");
        }

        Ok(&self.upload_operations)
    }

    fn state(&self) -> &str {
        &self.asset_delivery_state.state
    }

    fn state_details(&self) -> String {
        self.asset_delivery_state.details()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_only_store_screenshot_types_for_the_platform() {
        assert!(validate_display_type(ApplePlatform::Ios, "APP_IPHONE_67").is_ok());
        assert!(validate_display_type(ApplePlatform::Ios, "APP_IPAD_PRO_3GEN_129").is_ok());
        assert!(validate_display_type(ApplePlatform::MacOs, "APP_DESKTOP").is_ok());
        assert!(validate_display_type(ApplePlatform::MacOs, "APP_IPHONE_67").is_err());
    }
}
