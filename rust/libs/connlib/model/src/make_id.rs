#[macro_export]
macro_rules! make_id {
    ($name:ident) => {
        #[derive(Hash, Deserialize, Serialize, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
        pub struct $name(::uuid::Uuid);

        impl $name {
            pub const fn from_u128(v: u128) -> Self {
                Self(::uuid::Uuid::from_u128(v))
            }

            pub fn random() -> Self {
                Self(::uuid::Uuid::new_v4())
            }
        }

        impl ::std::str::FromStr for $name {
            type Err = uuid::Error;

            fn from_str(s: &str) -> Result<Self, Self::Err> {
                Ok(Self(::uuid::Uuid::parse_str(s)?))
            }
        }

        impl ::std::fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> ::std::fmt::Result {
                write!(f, "{}", self.0)
            }
        }

        impl ::std::fmt::Debug for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> ::std::fmt::Result {
                ::std::fmt::Display::fmt(&self, f)
            }
        }
    };
}
