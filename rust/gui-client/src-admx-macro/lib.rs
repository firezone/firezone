use proc_macro::TokenStream;
use proc_macro2::Span;
use std::collections::BTreeMap;
use syn::{
    ItemStruct, LitStr, Path, Token,
    parse::{Parse, ParseStream},
    spanned::Spanned,
};

/// A proc-macro that maps struct fields to registry values defined by an ADMX template.
#[proc_macro_attribute]
pub fn admx(attr: TokenStream, item: TokenStream) -> TokenStream {
    try_admx(attr, item)
        .unwrap_or_else(|e| e.into_compile_error())
        .into()
}

fn try_admx(attr: TokenStream, item: TokenStream) -> syn::Result<proc_macro2::TokenStream> {
    let admx_path = syn::parse::<AdmxPath>(attr)?;
    let input = syn::parse::<ItemStruct>(item)?;

    let admx_xml = ::std::fs::read_to_string(admx_path.inner.value())
        .map_err(|e| syn::Error::new(admx_path.span, format!("Failed to read ADMX file: {e}")))?;
    let doc = ::roxmltree::Document::parse(&admx_xml)
        .map_err(|e| syn::Error::new(admx_path.span, format!("Failed to parse ADMX XML: {e}")))?;

    let mut policy_map = doc
        .descendants()
        .filter(|n| n.has_tag_name("policy"))
        .map(|policy| {
            let value_name = policy
                .attribute("valueName")
                .or_else(|| policy
                    .descendants()
                    .find(|d| d.has_tag_name("text"))?
                    .attribute("valueName")
                )
                .ok_or_else(|| syn::Error::new(
                    admx_path.inner.span(),
                    "Policy does not have a `valueName` attribute"
                ))?;
            let key = policy.attribute("key").ok_or_else(|| {
                syn::Error::new(
                    admx_path.inner.span(),
                    format!("Policy '{value_name}' does not have a `key` attribute"),
                )
            })?;
            let span = proc_macro2::Span::call_site();
            let typ = policy
                .descendants()
                .find(|n| n.has_tag_name("text") || n.has_tag_name("decimal"))
                .map(|el| PolicyType::from_str(el.tag_name().name(), span))
                .unwrap_or_else(|| {
                    Err(syn::Error::new(
                        span,
                        format!(
                            "No supported type element found for policy '{value_name}'"
                        ),
                    ))
                })?;

            let load_policy_value = match typ {
                PolicyType::Text => quote::quote! {
                    {
                        let result = ::winreg::RegKey::predef(::winreg::enums::HKEY_CURRENT_USER)
                            .open_subkey(#key)
                            .and_then(|k| k.get_value(#value_name));
                        ::tracing::debug!(target: ::core::module_path!(), key = concat!(#key, "\\", #value_name), ?result);
                        result.ok()
                    }
                },
                PolicyType::Decimal => quote::quote! {
                    {
                        let result = ::winreg::RegKey::predef(::winreg::enums::HKEY_CURRENT_USER)
                            .open_subkey(#key)
                            .and_then(|k| k.get_value::<u32, _>(#value_name));
                        ::tracing::debug!(target: ::core::module_path!(), key = concat!(#key, "\\", #value_name), ?result);
                        result.map(|v| v == 1).ok()
                    }
                },
            };

            Ok((value_name.to_string(), load_policy_value))
        })
        .collect::<syn::Result<BTreeMap<_, _>>>()?;

    let field_loads = input
        .fields
        .iter()
        .map(|field| {
            let field_ident = field
                .ident
                .as_ref()
                .ok_or_else(|| syn::Error::new(field.span(), "Only named fields are supported"))?;
            let policy_name = field_ident.to_string();

            let load_policy_value = policy_map
                .remove(&policy_name)
                .ok_or_else(|| syn::Error::new(field.span(), "No ADMX policy found"))?;

            Ok(quote::quote! {
                #field_ident: #load_policy_value
            })
        })
        .collect::<syn::Result<Vec<_>>>()?;

    #[expect(clippy::manual_try_fold, reason = "We need to start with `Ok(())`")]
    policy_map
        .into_iter()
        .fold(Ok(()), |acc, (value_name, _)| {
            let err = syn::Error::new(
                admx_path.inner.span(),
                format!("ADMX policy `{value_name}` is not mapped to any struct field",),
            );

            match acc {
                Ok(()) => Err(err),
                Err(mut errors) => {
                    errors.combine(err);

                    Err(errors)
                }
            }
        })?;

    let struct_name = &input.ident;

    Ok(quote::quote! {
        #input

        impl #struct_name {
            pub fn load_from_registry() -> ::anyhow::Result<Self> {
                Ok(Self {
                    #(#field_loads,)*
                })
            }
        }
    })
}

struct AdmxPath {
    inner: LitStr,
    span: Span,
}

impl Parse for AdmxPath {
    fn parse(input: ParseStream) -> syn::Result<Self> {
        let path = input.parse::<Path>()?;
        input.parse::<Token![=]>()?;
        let value = input.parse::<LitStr>()?;

        if !path.is_ident("path") {
            return Err(syn::Error::new(
                path.span(),
                r#"Expected a single key `path`: `#[admx(path = "<path to admx file>")]`"#,
            ));
        }

        Ok(AdmxPath {
            inner: value,
            span: input.span(),
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum PolicyType {
    Text,
    Decimal,
}

impl PolicyType {
    fn from_str(s: &str, span: proc_macro2::Span) -> Result<Self, syn::Error> {
        match s {
            "text" => Ok(PolicyType::Text),
            "decimal" => Ok(PolicyType::Decimal),
            other => Err(syn::Error::new(
                span,
                format!("Unsupported ADMX policy type: {other}"),
            )),
        }
    }
}
