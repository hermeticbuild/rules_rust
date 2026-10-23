//! Canonical production Rust sources for Bazel compilation.

use std::collections::HashSet;
use std::ops::Range;

use proc_macro2::{Delimiter, Spacing, TokenStream, TokenTree};
use quote::ToTokens;
use syn::punctuated::Punctuated;
use syn::visit_mut::{self, VisitMut};
use syn::{Attribute, Item, Meta, Token};

/// Normalize one production source file, preserving doc attributes and opaque macro syntax.
///
/// `test` is false; all other configuration predicates remain unknown. Source
/// locations and procedural macro input can change. See the README before use.
pub fn normalize(source: &str) -> syn::Result<String> {
    let mut file = syn::parse_file(source)?;
    if disabled(&file.attrs) {
        // The inner cfg removes the containing module, not just its contents.
        file.items.clear();
    } else {
        file.items.retain(keep_item);
    }
    let mut production = Production::default();
    production.visit_file_mut(&mut file);
    let mut output = String::new();
    production.write_tokens(file.into_token_stream(), &mut output);
    Ok(output)
}

// A three-valued evaluation avoids assuming anything about target/features.
fn predicate(meta: &Meta) -> Option<bool> {
    match meta {
        Meta::Path(path) if path.is_ident("test") => Some(false),
        Meta::List(list) => {
            let args = list
                .parse_args_with(Punctuated::<Meta, Token![,]>::parse_terminated)
                .ok()?;
            if list.path.is_ident("not") && args.len() == 1 {
                predicate(&args[0]).map(|value| !value)
            } else if list.path.is_ident("all") || list.path.is_ident("any") {
                let all = list.path.is_ident("all");
                let mut unknown = false;
                for arg in args {
                    match predicate(&arg) {
                        Some(value) if value != all => return Some(!all),
                        None => unknown = true,
                        _ => {}
                    }
                }
                if unknown { None } else { Some(all) }
            } else {
                None
            }
        }
        _ => None,
    }
}

fn disables(meta: &Meta) -> bool {
    let Meta::List(list) = meta else { return false };
    if list.path.is_ident("cfg") {
        list.parse_args::<Meta>().ok().as_ref().and_then(predicate) == Some(false)
    } else if list.path.is_ident("cfg_attr") {
        let Ok(args) = list.parse_args_with(Punctuated::<Meta, Token![,]>::parse_terminated) else {
            return false;
        };
        args.first().and_then(predicate) == Some(true) && args.iter().skip(1).any(disables)
    } else {
        false
    }
}

fn disabled(attrs: &[Attribute]) -> bool {
    attrs.iter().any(|attr| disables(&attr.meta))
}

fn keep_item(item: &Item) -> bool {
    let attrs: &[Attribute] = match item {
        Item::Const(i) => &i.attrs,
        Item::Enum(i) => &i.attrs,
        Item::ExternCrate(i) => &i.attrs,
        Item::Fn(i) => &i.attrs,
        Item::ForeignMod(i) => &i.attrs,
        Item::Impl(i) => &i.attrs,
        Item::Macro(i) => &i.attrs,
        Item::Mod(i) => &i.attrs,
        Item::Static(i) => &i.attrs,
        Item::Struct(i) => &i.attrs,
        Item::Trait(i) => &i.attrs,
        Item::TraitAlias(i) => &i.attrs,
        Item::Type(i) => &i.attrs,
        Item::Union(i) => &i.attrs,
        Item::Use(i) => &i.attrs,
        _ => &[],
    };
    !disabled(attrs)
        && !(matches!(item, Item::Fn(_)) && attrs.iter().any(|a| a.path().is_ident("test")))
}

#[derive(Default)]
struct Production {
    macros: HashSet<Range<usize>>,
}

impl Production {
    fn write_tokens(&self, tokens: TokenStream, output: &mut String) {
        let mut space = false;
        for token in tokens {
            if space {
                output.push(' ');
            }
            space = true;
            match token {
                TokenTree::Group(group) if self.macros.contains(&group.span().byte_range()) => {
                    // Doc comments and template placeholders in opaque macro
                    // bodies can change meaning when serialized as tokens.
                    output.push_str(&group.span().source_text().expect("parsed macro source"));
                }
                TokenTree::Group(group) => {
                    let (open, close) = match group.delimiter() {
                        // Rust's unused_braces lint treats single-line blocks
                        // differently, so keep ordinary blocks multiline.
                        Delimiter::Brace => ("{\n", "\n}"),
                        Delimiter::Parenthesis => ("(", ")"),
                        Delimiter::Bracket => ("[", "]"),
                        Delimiter::None => ("", ""),
                    };
                    output.push_str(open);
                    self.write_tokens(group.stream(), output);
                    output.push_str(close);
                }
                TokenTree::Punct(punct) => {
                    output.push(punct.as_char());
                    space = punct.spacing() != Spacing::Joint;
                }
                token => output.push_str(&token.to_string()),
            }
        }
    }
}

impl VisitMut for Production {
    fn visit_macro_mut(&mut self, mac: &mut syn::Macro) {
        self.macros.insert(mac.delimiter.span().join().byte_range());
    }

    fn visit_item_mod_mut(&mut self, module: &mut syn::ItemMod) {
        if let Some((_, items)) = &mut module.content {
            items.retain(keep_item);
        }
        visit_mut::visit_item_mod_mut(self, module);
    }

    fn visit_block_mut(&mut self, block: &mut syn::Block) {
        block.stmts.retain(|stmt| match stmt {
            syn::Stmt::Item(item) => keep_item(item),
            syn::Stmt::Local(local) => !disabled(&local.attrs),
            syn::Stmt::Macro(mac) => !disabled(&mac.attrs),
            _ => true,
        });
        visit_mut::visit_block_mut(self, block);
    }

    fn visit_item_impl_mut(&mut self, item: &mut syn::ItemImpl) {
        item.items.retain(|item| {
            !disabled(match item {
                syn::ImplItem::Const(i) => &i.attrs,
                syn::ImplItem::Fn(i) => &i.attrs,
                syn::ImplItem::Type(i) => &i.attrs,
                syn::ImplItem::Macro(i) => &i.attrs,
                _ => &[],
            })
        });
        visit_mut::visit_item_impl_mut(self, item);
    }

    fn visit_item_trait_mut(&mut self, item: &mut syn::ItemTrait) {
        item.items.retain(|item| {
            !disabled(match item {
                syn::TraitItem::Const(i) => &i.attrs,
                syn::TraitItem::Fn(i) => &i.attrs,
                syn::TraitItem::Type(i) => &i.attrs,
                syn::TraitItem::Macro(i) => &i.attrs,
                _ => &[],
            })
        });
        visit_mut::visit_item_trait_mut(self, item);
    }

    fn visit_item_foreign_mod_mut(&mut self, item: &mut syn::ItemForeignMod) {
        item.items.retain(|item| {
            !disabled(match item {
                syn::ForeignItem::Fn(i) => &i.attrs,
                syn::ForeignItem::Static(i) => &i.attrs,
                syn::ForeignItem::Type(i) => &i.attrs,
                syn::ForeignItem::Macro(i) => &i.attrs,
                _ => &[],
            })
        });
        visit_mut::visit_item_foreign_mod_mut(self, item);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_and_comment_edits_have_identical_output() {
        let before =
            "// before\npub fn answer() -> u32 { 42 } #[cfg(test)] mod tests { fn a() {} }";
        let after = "/* after\n\n*/ pub fn answer() -> u32 {42}\n#[cfg(test)] mod tests { fn b() { panic!(); } }";
        let output = normalize(before).unwrap();
        assert_eq!(output, normalize(after).unwrap());
        assert_ne!(output, normalize(&before.replace("42", "43")).unwrap());
        assert_eq!(
            normalize("#![cfg(test)] fn before() {}").unwrap(),
            normalize("#![cfg(test)] fn after() {}").unwrap(),
        );
    }

    #[test]
    fn cfg_evaluation_is_conservative() {
        let source = r#"
            #[cfg(all(test, feature = "x"))] fn removed() {}
            #[cfg(any(test, feature = "x"))] fn retained() {}
            #[cfg(not(test))] fn production() {}
            #[cfg_attr(not(test), cfg(test))] fn also_removed() {}
            #[cfg_attr(feature = "x", cfg(test))] fn unknown() {}
            #[test] fn standalone_test() {}
        "#;
        let output = normalize(source).unwrap();
        assert!(!output.contains("removed"));
        assert!(!output.contains("standalone_test"));
        assert!(output.contains(&quote::quote!(#[cfg(any(test, feature = "x"))]).to_string()));
        assert!(output.contains(&quote::quote!(#[cfg_attr(feature = "x", cfg(test))]).to_string()));
        for name in ["retained", "production", "unknown"] {
            assert!(output.contains(name), "{output}");
        }
        assert_eq!(normalize(&output).unwrap(), output);
    }

    #[test]
    fn nested_items_are_removed_but_macro_inputs_and_docs_survive() {
        let source = r#"
            /// Used by a derive macro.
            struct S;
            impl S { #[cfg(test)] fn removed() {} fn production() {} }
            trait T { #[cfg(test)] fn removed(); fn production(); }
            mod nested { #[cfg(test)] mod removed; pub fn production() {} }
            fn f() { #[cfg(test)] fn removed() {} }
            passthrough! { #[cfg(test)] fn macro_input() {} }
        "#;
        let output = normalize(source).unwrap();
        assert!(!output.contains("removed"));
        assert!(output.contains("Used by a derive macro."));
        assert!(output.contains("macro_input"));
    }

    #[test]
    fn opaque_macro_groups_survive_serialization() {
        let source = r#"
            macro_rules! matched {
                (/// ignored in a matcher
                 value) => { 42 };
                (#[doc = r" literal"]) => { 43 };
            }
            matched!(/// literal
            );
            template! { {{value}} }
        "#;
        let output = normalize(source).unwrap();
        assert!(output.contains("(/// ignored in a matcher"));
        assert!(output.contains("matched ! (/// literal\n            )"));
        assert!(output.contains("{ {{value}} }"));
        assert_eq!(normalize(&output).unwrap(), output);
    }
}
