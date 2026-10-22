use opentelemetry::KeyValue;
use opentelemetry_sdk::{
    Resource,
    resource::{EnvResourceDetector, ResourceDetector, TelemetryResourceDetector},
};

pub fn service_instance_id(maybe_legacy_id: String) -> KeyValue {
    KeyValue::new(
        "service.instance.id",
        crate::maybe_hash_device_id(maybe_legacy_id),
    )
}

pub fn default_resource_with<const N: usize>(attributes: [KeyValue; N]) -> Resource {
    Resource::builder_empty()
        .with_detector(Box::new(TelemetryResourceDetector))
        .with_detector(Box::new(OsResourceDetector))
        .with_detector(Box::new(EnvResourceDetector::new()))
        .with_attributes(attributes)
        .build()
}

pub struct OsResourceDetector;

impl ResourceDetector for OsResourceDetector {
    fn detect(&self) -> Resource {
        Resource::builder_empty()
            .with_attribute(KeyValue::new("os.type", std::env::consts::OS))
            .build()
    }
}
