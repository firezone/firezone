use std::net::IpAddr;

use libs_common::Callbacks;
use webrtc::sdp::description::common::Attribute;

use crate::{ControlSignal, Tunnel};

const CANDIDATE_PLACE: usize = 4;

fn get_candidate_ip(candidate: &str) -> Option<IpAddr> {
    candidate
        .split_whitespace()
        .nth(CANDIDATE_PLACE)
        .and_then(|c| c.parse().ok())
}

impl<C, CB> Tunnel<C, CB>
where
    C: ControlSignal + Send + Sync + 'static,
    CB: Callbacks + 'static,
{
    pub(crate) fn sdp_remove_resource_attributes(&self, attributes: &mut Vec<Attribute>) {
        attributes.retain(|a| {
            !a.is_ice_candidate()
                || !a.value.as_ref().is_some_and(|k| {
                    get_candidate_ip(k)
                        .is_some_and(|c| self.resources.read().values().any(|x| x.contains(c)))
                })
        })
    }
}
