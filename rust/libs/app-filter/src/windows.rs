//! Enforcement with the Windows Filtering Platform.
//!
//! Every filter lives in a dynamic session, so the kernel removes them when the
//! Tunnel service exits for any reason. The filters sit in one private sublayer
//! at the ALE connect layers:
//!
//! - permit (weight 15): the listed executables on the tunnel interface
//! - permit (weight 15): anything to the tunnel's DNS servers on the tunnel interface
//! - block (weight 0): everything else on the tunnel interface
//!
//! Matching on the interface LUID means the filter guards exactly what the tunnel
//! routes, without mirroring the route table into WFP. Permits keep their action
//! rights, so a block from another security product still wins.

use crate::{AppId, Interface, Policy, ProtectedDestinations};
use anyhow::{Context as _, Result, bail};
use std::net::IpAddr;
use windows::Win32::Foundation::HANDLE;
use windows::Win32::NetworkManagement::WindowsFilteringPlatform::{
    FWP_ACTION_BLOCK, FWP_ACTION_PERMIT, FWP_ACTION_TYPE, FWP_BYTE_ARRAY16, FWP_BYTE_ARRAY16_TYPE,
    FWP_BYTE_BLOB, FWP_BYTE_BLOB_TYPE, FWP_CONDITION_VALUE0, FWP_CONDITION_VALUE0_0,
    FWP_MATCH_EQUAL, FWP_UINT8, FWP_UINT32, FWP_UINT64, FWP_VALUE0, FWP_VALUE0_0, FWPM_ACTION0,
    FWPM_CONDITION_ALE_APP_ID, FWPM_CONDITION_IP_LOCAL_INTERFACE, FWPM_CONDITION_IP_REMOTE_ADDRESS,
    FWPM_DISPLAY_DATA0, FWPM_FILTER_CONDITION0, FWPM_FILTER0, FWPM_LAYER_ALE_AUTH_CONNECT_V4,
    FWPM_LAYER_ALE_AUTH_CONNECT_V6, FWPM_PROVIDER0, FWPM_SESSION_FLAG_DYNAMIC, FWPM_SESSION0,
    FWPM_SUBLAYER0, FwpmEngineClose0, FwpmEngineOpen0, FwpmFilterAdd0, FwpmFilterDeleteById0,
    FwpmFreeMemory0, FwpmGetAppIdFromFileName0, FwpmProviderAdd0, FwpmSubLayerAdd0,
    FwpmTransactionAbort0, FwpmTransactionBegin0, FwpmTransactionCommit0,
};
use windows::Win32::System::Rpc::RPC_C_AUTHN_WINNT;
use windows::core::{GUID, HRESULT, HSTRING, PCWSTR, PWSTR};

const PROVIDER_KEY: GUID = GUID::from_u128(0x6f1b0a2e_3a6e_4c1d_9a4b_2f0d8c1e5a71);
const SUBLAYER_KEY: GUID = GUID::from_u128(0x9c3e7d54_0b2a_4f8e_a1c6_7e5d2b4a9f03);

/// Highest weight a sublayer can have, so our block is evaluated before the built-in firewall's permits.
const SUBLAYER_WEIGHT: u16 = u16::MAX;
const PERMIT_WEIGHT: u8 = 15;
const BLOCK_WEIGHT: u8 = 0;

const ERROR_SUCCESS: u32 = 0;

pub struct Enforcer {
    engine: Engine,
    app_ids: Vec<Vec<u8>>,
    filter_ids: Vec<u64>,
}

impl Enforcer {
    pub fn new(policy: &Policy) -> Result<Self> {
        let engine = Engine::open()?;
        engine.add_provider_and_sublayer()?;

        let app_ids = policy
            .allowed_apps()
            .filter_map(|app| {
                app_id_from_path(app)
                    .inspect_err(|e| {
                        tracing::warn!(app = app.as_str(), "Ignoring application: {e:#}")
                    })
                    .ok()
            })
            .collect();

        Ok(Self {
            engine,
            app_ids,
            filter_ids: Vec::new(),
        })
    }

    pub fn apply(
        &mut self,
        destinations: &ProtectedDestinations,
        interface: &Interface,
    ) -> Result<()> {
        let luid = interface
            .luid
            .context("Cannot filter before the tunnel interface exists")?;
        let app_blobs = self
            .app_ids
            .iter()
            .map(|app_id| FWP_BYTE_BLOB {
                size: app_id.len() as u32,
                data: app_id.as_ptr().cast_mut(),
            })
            .collect::<Vec<_>>();
        let dns_v4 = destinations
            .exempt()
            .filter_map(|ip| match ip {
                IpAddr::V4(ip) => Some(u32::from(ip)),
                IpAddr::V6(_) => None,
            })
            .collect::<Vec<_>>();
        let dns_v6 = destinations
            .exempt()
            .filter_map(|ip| match ip {
                IpAddr::V4(_) => None,
                IpAddr::V6(ip) => Some(FWP_BYTE_ARRAY16 {
                    byteArray16: ip.octets(),
                }),
            })
            .collect::<Vec<_>>();

        let mut filter_ids = Vec::new();
        self.engine.transaction(|engine| {
            for id in self.filter_ids.drain(..) {
                engine.delete_filter(id)?;
            }

            for layer in [
                FWPM_LAYER_ALE_AUTH_CONNECT_V4,
                FWPM_LAYER_ALE_AUTH_CONNECT_V6,
            ] {
                filter_ids.push(engine.add_filter(
                    layer,
                    FWP_ACTION_BLOCK,
                    BLOCK_WEIGHT,
                    &[interface_condition(&luid)],
                )?);

                for blob in &app_blobs {
                    filter_ids.push(engine.add_filter(
                        layer,
                        FWP_ACTION_PERMIT,
                        PERMIT_WEIGHT,
                        &[interface_condition(&luid), app_condition(blob)],
                    )?);
                }
            }

            for ip in &dns_v4 {
                filter_ids.push(engine.add_filter(
                    FWPM_LAYER_ALE_AUTH_CONNECT_V4,
                    FWP_ACTION_PERMIT,
                    PERMIT_WEIGHT,
                    &[interface_condition(&luid), remote_v4_condition(*ip)],
                )?);
            }

            for ip in &dns_v6 {
                filter_ids.push(engine.add_filter(
                    FWPM_LAYER_ALE_AUTH_CONNECT_V6,
                    FWP_ACTION_PERMIT,
                    PERMIT_WEIGHT,
                    &[interface_condition(&luid), remote_v6_condition(ip)],
                )?);
            }

            Ok(())
        })?;
        self.filter_ids = filter_ids;

        tracing::debug!(num_filters = self.filter_ids.len(), "Installed WFP filters");

        Ok(())
    }

    pub fn clear(&mut self) {
        if self.filter_ids.is_empty() {
            return;
        }

        let result = self.engine.transaction(|engine| {
            for id in self.filter_ids.drain(..) {
                engine.delete_filter(id)?;
            }

            Ok(())
        });

        if let Err(e) = result {
            tracing::warn!("Failed to remove WFP filters: {e:#}");
        }
    }
}

struct Engine {
    handle: HANDLE,
}

impl Engine {
    fn open() -> Result<Self> {
        let session = FWPM_SESSION0 {
            flags: FWPM_SESSION_FLAG_DYNAMIC,
            ..Default::default()
        };
        let mut handle = HANDLE::default();

        // SAFETY: All pointers are valid for the duration of the call; the engine copies the session.
        let code = unsafe {
            FwpmEngineOpen0(
                PCWSTR::null(),
                RPC_C_AUTHN_WINNT,
                None,
                Some(&session),
                &mut handle,
            )
        };
        check(code).context("Failed to open WFP engine")?;

        Ok(Self { handle })
    }

    fn add_provider_and_sublayer(&self) -> Result<()> {
        let name = HSTRING::from("Firezone application filter");
        let display_data = FWPM_DISPLAY_DATA0 {
            name: PWSTR(name.as_ptr().cast_mut()),
            description: PWSTR::null(),
        };

        let provider = FWPM_PROVIDER0 {
            providerKey: PROVIDER_KEY,
            displayData: display_data,
            ..Default::default()
        };
        // SAFETY: `provider` and the strings it points to outlive the call.
        let code = unsafe { FwpmProviderAdd0(self.handle, &provider, None) };
        check(code).context("Failed to add WFP provider")?;

        let mut provider_key = PROVIDER_KEY;
        let sublayer = FWPM_SUBLAYER0 {
            subLayerKey: SUBLAYER_KEY,
            displayData: display_data,
            providerKey: &mut provider_key,
            weight: SUBLAYER_WEIGHT,
            ..Default::default()
        };
        // SAFETY: `sublayer` and everything it points to outlive the call.
        let code = unsafe { FwpmSubLayerAdd0(self.handle, &sublayer, None) };
        check(code).context("Failed to add WFP sublayer")?;

        Ok(())
    }

    fn transaction(&self, f: impl FnOnce(&Self) -> Result<()>) -> Result<()> {
        // SAFETY: The handle is a valid, open engine handle.
        let code = unsafe { FwpmTransactionBegin0(self.handle, 0) };
        check(code).context("Failed to begin WFP transaction")?;

        if let Err(e) = f(self) {
            // SAFETY: A transaction is in progress on this handle.
            unsafe { FwpmTransactionAbort0(self.handle) };

            return Err(e);
        }

        // SAFETY: A transaction is in progress on this handle.
        let code = unsafe { FwpmTransactionCommit0(self.handle) };
        check(code).context("Failed to commit WFP transaction")?;

        Ok(())
    }

    fn add_filter(
        &self,
        layer: GUID,
        action: FWP_ACTION_TYPE,
        weight: u8,
        conditions: &[FWPM_FILTER_CONDITION0],
    ) -> Result<u64> {
        let name = HSTRING::from("Firezone application filter");
        let mut provider_key = PROVIDER_KEY;
        let filter = FWPM_FILTER0 {
            displayData: FWPM_DISPLAY_DATA0 {
                name: PWSTR(name.as_ptr().cast_mut()),
                description: PWSTR::null(),
            },
            providerKey: &mut provider_key,
            layerKey: layer,
            subLayerKey: SUBLAYER_KEY,
            weight: FWP_VALUE0 {
                r#type: FWP_UINT8,
                Anonymous: FWP_VALUE0_0 { uint8: weight },
            },
            numFilterConditions: conditions.len() as u32,
            filterCondition: conditions.as_ptr().cast_mut(),
            action: FWPM_ACTION0 {
                r#type: action,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut id = 0_u64;

        // SAFETY: `filter`, `conditions` and the values they point to outlive the call; the engine copies them.
        let code = unsafe { FwpmFilterAdd0(self.handle, &filter, None, Some(&mut id)) };
        check(code).context("Failed to add WFP filter")?;

        Ok(id)
    }

    fn delete_filter(&self, id: u64) -> Result<()> {
        // SAFETY: The handle is a valid, open engine handle.
        let code = unsafe { FwpmFilterDeleteById0(self.handle, id) };
        check(code).with_context(|| format!("Failed to delete WFP filter {id}"))?;

        Ok(())
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        // SAFETY: The handle is a valid, open engine handle and is not used after this.
        unsafe { FwpmEngineClose0(self.handle) };
    }
}

/// Resolves an executable path to the device-path blob WFP matches `ALE_APP_ID` against.
///
/// The file must exist: WFP reads the volume to produce the device path.
fn app_id_from_path(app: &AppId) -> Result<Vec<u8>> {
    let path = HSTRING::from(app.as_str());
    let mut blob: *mut FWP_BYTE_BLOB = std::ptr::null_mut();

    // SAFETY: `path` is a valid NUL-terminated wide string and `blob` a valid out-pointer.
    let code = unsafe { FwpmGetAppIdFromFileName0(&path, &mut blob) };
    check(code).context("Failed to resolve application ID")?;

    if blob.is_null() {
        bail!("WFP returned no application ID");
    }

    // SAFETY: On success, `blob` points to a blob of `size` bytes owned by WFP until freed below.
    let bytes = unsafe { std::slice::from_raw_parts((*blob).data, (*blob).size as usize).to_vec() };
    // SAFETY: `blob` was allocated by WFP and is freed exactly once.
    unsafe { FwpmFreeMemory0((&mut blob as *mut *mut FWP_BYTE_BLOB).cast()) };

    Ok(bytes)
}

fn interface_condition(luid: &u64) -> FWPM_FILTER_CONDITION0 {
    FWPM_FILTER_CONDITION0 {
        fieldKey: FWPM_CONDITION_IP_LOCAL_INTERFACE,
        matchType: FWP_MATCH_EQUAL,
        conditionValue: FWP_CONDITION_VALUE0 {
            r#type: FWP_UINT64,
            Anonymous: FWP_CONDITION_VALUE0_0 {
                uint64: std::ptr::from_ref(luid).cast_mut(),
            },
        },
    }
}

fn app_condition(blob: &FWP_BYTE_BLOB) -> FWPM_FILTER_CONDITION0 {
    FWPM_FILTER_CONDITION0 {
        fieldKey: FWPM_CONDITION_ALE_APP_ID,
        matchType: FWP_MATCH_EQUAL,
        conditionValue: FWP_CONDITION_VALUE0 {
            r#type: FWP_BYTE_BLOB_TYPE,
            Anonymous: FWP_CONDITION_VALUE0_0 {
                byteBlob: std::ptr::from_ref(blob).cast_mut(),
            },
        },
    }
}

fn remote_v4_condition(ip: u32) -> FWPM_FILTER_CONDITION0 {
    FWPM_FILTER_CONDITION0 {
        fieldKey: FWPM_CONDITION_IP_REMOTE_ADDRESS,
        matchType: FWP_MATCH_EQUAL,
        conditionValue: FWP_CONDITION_VALUE0 {
            r#type: FWP_UINT32,
            Anonymous: FWP_CONDITION_VALUE0_0 { uint32: ip },
        },
    }
}

fn remote_v6_condition(ip: &FWP_BYTE_ARRAY16) -> FWPM_FILTER_CONDITION0 {
    FWPM_FILTER_CONDITION0 {
        fieldKey: FWPM_CONDITION_IP_REMOTE_ADDRESS,
        matchType: FWP_MATCH_EQUAL,
        conditionValue: FWP_CONDITION_VALUE0 {
            r#type: FWP_BYTE_ARRAY16_TYPE,
            Anonymous: FWP_CONDITION_VALUE0_0 {
                byteArray16: std::ptr::from_ref(ip).cast_mut(),
            },
        },
    }
}

fn check(code: u32) -> Result<()> {
    if code == ERROR_SUCCESS {
        return Ok(());
    }

    Err(windows::core::Error::from_hresult(HRESULT::from_win32(code)).into())
}
