#[cfg(unix)]
pub type RawFd = std::os::fd::RawFd;

#[cfg(not(unix))]
pub type RawFd = stub::NonUnixRawFdStub;

#[cfg(not(unix))]
mod stub {
    pub enum NonUnixRawFdStub {}

    impl From<NonUnixRawFdStub> for u32 {
        fn from(_: NonUnixRawFdStub) -> Self {
            unreachable!("Instance of RawFd stub cannot exit")
        }
    }

    impl From<u32> for NonUnixRawFdStub {
        fn from(_: u32) -> Self {
            unimplemented!("Cannot create instance of stub RawFd")
        }
    }

    uniffi::custom_type!(NonUnixRawFdStub, u32);
}
