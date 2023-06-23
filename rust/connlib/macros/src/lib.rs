#![recursion_limit = "128"]

extern crate proc_macro;
use proc_macro2::{Span, TokenStream};
use quote::quote;
use syn::{Data, DeriveInput, Fields};

/// Macro that generates a new enum with only the discriminants of another enum within a module that implements swift_bridge.
///
/// This is a workaround to create an error type compatible with swift that can be converted from the original error type.
/// it implements `From<OriginalEnum>` so the idea is that you can call a swift ffi function `handle_error(err.into());`
///
/// This makes a lot of assumption about the types it's being implemented on since we're controlling the type it is not meant
/// to be a public macro. (However be careful if you reuse it somewhere else! this is based in strum's EnumDiscrminant so you can
/// check there for an actual proper implementation).
///
/// IMPORTANT!: You need to include swift_bridge::bridge for macos and ios target so this doesn't error out.
#[proc_macro_derive(SwiftEnum)]
pub fn swift_enum(input: proc_macro::TokenStream) -> proc_macro::TokenStream {
    let ast = syn::parse_macro_input!(input as DeriveInput);

    let toks = swift_enum_inner(&ast).unwrap_or_else(|err| err.to_compile_error());
    toks.into()
}

fn swift_enum_inner(ast: &DeriveInput) -> syn::Result<TokenStream> {
    let name = &ast.ident;
    let vis = &ast.vis;

    let variants = match &ast.data {
        Data::Enum(v) => &v.variants,
        _ => {
            return Err(syn::Error::new(
                Span::call_site(),
                "This macro only support enums.",
            ))
        }
    };

    let discriminants: Vec<_> = variants
        .into_iter()
        .map(|v| {
            let ident = &v.ident;
            quote! {#ident}
        })
        .collect();

    let enum_name = syn::Ident::new(&format!("Swift{}", name), Span::call_site());
    let mod_name = syn::Ident::new("swift_ffi", Span::call_site());

    let arms = variants
        .iter()
        .map(|variant| {
            let ident = &variant.ident;
            let params = match &variant.fields {
                Fields::Unit => quote! {},
                Fields::Unnamed(_fields) => {
                    quote! { (..) }
                }
                Fields::Named(_fields) => {
                    quote! { { .. } }
                }
            };

            quote! { #name::#ident #params => #mod_name::#enum_name::#ident }
        })
        .collect::<Vec<_>>();

    let from_fn_body = quote! { match val { #(#arms),* } };

    let impl_from_ref = {
        quote! {
            impl<'a> ::core::convert::From<&'a #name> for #mod_name::#enum_name {
                fn from(val: &'a #name) -> Self {
                    #from_fn_body
                }
            }
        }
    };

    let impl_from = {
        quote! {
            impl ::core::convert::From<#name> for #mod_name::#enum_name {
                fn from(val: #name) -> Self {
                    #from_fn_body
                }
            }
        }
    };

    // If we wanted to expose this function we should have another crate that actually also includes
    // swift_bridge. but since we are only using this inside our crates we can just make sure we include it.
    Ok(quote! {
        #[cfg_attr(any(target_os = "macos", target_os = "ios"), swift_bridge::bridge)]
        #vis mod #mod_name {
            pub enum #enum_name {
                #(#discriminants),*
            }

        }

        #[cfg(any(target_os = "macos", target_os = "ios"))]
        #impl_from_ref

        #[cfg(any(target_os = "macos", target_os = "ios"))]
        #impl_from
    })
}
