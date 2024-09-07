use super::*;
use anyhow::Result;
use std::str::FromStr as _;

use builder::INTERNET_RESOURCE_DESCRIPTION;

impl Menu {
    fn selected_item<E: Into<Option<Event>>, S: Into<String>>(mut self, id: E, title: S) -> Self {
        self.add_item(item(id, title).selected());
        self
    }
}

fn signed_in<'a>(
    resources: &'a [ResourceDescription],
    favorite_resources: &'a HashSet<ResourceId>,
    internet_resource_enabled: &'a Option<bool>,
) -> AppState<'a> {
    AppState {
        connlib: ConnlibState::SignedIn(SignedIn {
            actor_name: "Jane Doe",
            favorite_resources,
            resources,
            internet_resource_enabled,
        }),
        release: None,
    }
}

fn resources() -> Vec<ResourceDescription> {
    let s = r#"[
        {
            "id": "73037362-715d-4a83-a749-f18eadd970e6",
            "type": "cidr",
            "name": "172.172.0.0/16",
            "address": "172.172.0.0/16",
            "address_description": "cidr resource",
            "sites": [{"name": "test", "id": "bf56f32d-7b2c-4f5d-a784-788977d014a4"}],
            "status": "Unknown"
        },
        {
            "id": "03000143-e25e-45c7-aafb-144990e57dcd",
            "type": "dns",
            "name": "MyCorp GitLab",
            "address": "gitlab.mycorp.com",
            "address_description": "https://gitlab.mycorp.com",
            "sites": [{"name": "test", "id": "bf56f32d-7b2c-4f5d-a784-788977d014a4"}],
            "status": "Online"
        },
        {
            "id": "1106047c-cd5d-4151-b679-96b93da7383b",
            "type": "internet",
            "name": "Internet Resource",
            "address": "All internet addresses",
            "sites": [{"name": "test", "id": "eb94482a-94f4-47cb-8127-14fb3afa5516"}],
            "status": "Offline"
        }
    ]"#;

    serde_json::from_str(s).unwrap()
}

#[test]
fn no_resources_no_favorites() {
    let resources = vec![];
    let favorites = Default::default();
    let disabled_resources = Default::default();
    let input = signed_in(&resources, &favorites, &disabled_resources);
    let actual = input.into_menu();
    let expected = Menu::default()
        .disabled("Signed in as Jane Doe")
        .item(Event::SignOut, SIGN_OUT)
        .separator()
        .disabled(RESOURCES)
        .add_bottom_section(None, DISCONNECT_AND_QUIT); // Skip testing the bottom section, it's simple

    assert_eq!(
        actual,
        expected,
        "{}",
        serde_json::to_string_pretty(&actual).unwrap()
    );
}

#[test]
fn no_resources_invalid_favorite() {
    let resources = vec![];
    let favorites = HashSet::from([ResourceId::from_u128(42)]);
    let disabled_resources = Default::default();
    let input = signed_in(&resources, &favorites, &disabled_resources);
    let actual = input.into_menu();
    let expected = Menu::default()
        .disabled("Signed in as Jane Doe")
        .item(Event::SignOut, SIGN_OUT)
        .separator()
        .disabled(RESOURCES)
        .add_bottom_section(None, DISCONNECT_AND_QUIT); // Skip testing the bottom section, it's simple

    assert_eq!(
        actual,
        expected,
        "{}",
        serde_json::to_string_pretty(&actual).unwrap()
    );
}

#[test]
fn some_resources_no_favorites() {
    let resources = resources();
    let favorites = Default::default();
    let disabled_resources = Default::default();
    let input = signed_in(&resources, &favorites, &disabled_resources);
    let actual = input.into_menu();
    let expected = Menu::default()
        .disabled("Signed in as Jane Doe")
        .item(Event::SignOut, SIGN_OUT)
        .separator()
        .disabled(RESOURCES)
        .add_submenu(
            Menu::new("172.172.0.0/16")
                .copyable("cidr resource")
                .separator()
                .disabled("Resource")
                .copyable("172.172.0.0/16")
                .copyable("172.172.0.0/16")
                .item(
                    Event::AddFavorite(
                        ResourceId::from_str("73037362-715d-4a83-a749-f18eadd970e6").unwrap(),
                    ),
                    ADD_FAVORITE,
                )
                .separator()
                .disabled("Site")
                .copyable("test")
                .copyable(NO_ACTIVITY),
        )
        .add_submenu(
            Menu::new("MyCorp GitLab")
                .item(
                    Event::Url("https://gitlab.mycorp.com".parse().unwrap()),
                    "<https://gitlab.mycorp.com>",
                )
                .separator()
                .disabled("Resource")
                .copyable("MyCorp GitLab")
                .copyable("gitlab.mycorp.com")
                .item(
                    Event::AddFavorite(
                        ResourceId::from_str("03000143-e25e-45c7-aafb-144990e57dcd").unwrap(),
                    ),
                    ADD_FAVORITE,
                )
                .separator()
                .disabled("Site")
                .copyable("test")
                .copyable(GATEWAY_CONNECTED),
        )
        .add_submenu(
            Menu::new("— Internet Resource")
                .disabled(INTERNET_RESOURCE_DESCRIPTION)
                .separator()
                .item(Event::EnableInternetResource, ENABLE)
                .separator()
                .disabled("Site")
                .copyable("test")
                .copyable(ALL_GATEWAYS_OFFLINE),
        )
        .add_bottom_section(None, DISCONNECT_AND_QUIT); // Skip testing the bottom section, it's simple
    assert_eq!(
        actual,
        expected,
        "{}",
        serde_json::to_string_pretty(&actual).unwrap(),
    );
}

#[test]
fn some_resources_one_favorite() -> Result<()> {
    let resources = resources();
    let favorites = HashSet::from([ResourceId::from_str(
        "03000143-e25e-45c7-aafb-144990e57dcd",
    )?]);
    let disabled_resources = Default::default();
    let input = signed_in(&resources, &favorites, &disabled_resources);
    let actual = input.into_menu();
    let expected = Menu::default()
        .disabled("Signed in as Jane Doe")
        .item(Event::SignOut, SIGN_OUT)
        .separator()
        .disabled(FAVORITE_RESOURCES)
        .add_submenu(
            Menu::new("MyCorp GitLab")
                .item(
                    Event::Url("https://gitlab.mycorp.com".parse().unwrap()),
                    "<https://gitlab.mycorp.com>",
                )
                .separator()
                .disabled("Resource")
                .copyable("MyCorp GitLab")
                .copyable("gitlab.mycorp.com")
                .selected_item(
                    Event::RemoveFavorite(ResourceId::from_str(
                        "03000143-e25e-45c7-aafb-144990e57dcd",
                    )?),
                    REMOVE_FAVORITE,
                )
                .separator()
                .disabled("Site")
                .copyable("test")
                .copyable(GATEWAY_CONNECTED),
        )
        .add_submenu(
            Menu::new("— Internet Resource")
                .disabled(INTERNET_RESOURCE_DESCRIPTION)
                .separator()
                .item(Event::EnableInternetResource, ENABLE)
                .separator()
                .disabled("Site")
                .copyable("test")
                .copyable(ALL_GATEWAYS_OFFLINE),
        )
        .separator()
        .add_submenu(
            Menu::new(OTHER_RESOURCES).add_submenu(
                Menu::new("172.172.0.0/16")
                    .copyable("cidr resource")
                    .separator()
                    .disabled("Resource")
                    .copyable("172.172.0.0/16")
                    .copyable("172.172.0.0/16")
                    .item(
                        Event::AddFavorite(ResourceId::from_str(
                            "73037362-715d-4a83-a749-f18eadd970e6",
                        )?),
                        ADD_FAVORITE,
                    )
                    .separator()
                    .disabled("Site")
                    .copyable("test")
                    .copyable(NO_ACTIVITY),
            ),
        )
        .add_bottom_section(None, DISCONNECT_AND_QUIT); // Skip testing the bottom section, it's simple

    assert_eq!(
        actual,
        expected,
        "{}",
        serde_json::to_string_pretty(&actual).unwrap()
    );

    Ok(())
}

#[test]
fn some_resources_invalid_favorite() -> Result<()> {
    let resources = resources();
    let favorites = HashSet::from([ResourceId::from_str(
        "00000000-0000-0000-0000-000000000000",
    )?]);
    let disabled_resources = Default::default();
    let input = signed_in(&resources, &favorites, &disabled_resources);
    let actual = input.into_menu();
    let expected = Menu::default()
        .disabled("Signed in as Jane Doe")
        .item(Event::SignOut, SIGN_OUT)
        .separator()
        .disabled(RESOURCES)
        .add_submenu(
            Menu::new("172.172.0.0/16")
                .copyable("cidr resource")
                .separator()
                .disabled("Resource")
                .copyable("172.172.0.0/16")
                .copyable("172.172.0.0/16")
                .item(
                    Event::AddFavorite(ResourceId::from_str(
                        "73037362-715d-4a83-a749-f18eadd970e6",
                    )?),
                    ADD_FAVORITE,
                )
                .separator()
                .disabled("Site")
                .copyable("test")
                .copyable(NO_ACTIVITY),
        )
        .add_submenu(
            Menu::new("MyCorp GitLab")
                .item(
                    Event::Url("https://gitlab.mycorp.com".parse().unwrap()),
                    "<https://gitlab.mycorp.com>",
                )
                .separator()
                .disabled("Resource")
                .copyable("MyCorp GitLab")
                .copyable("gitlab.mycorp.com")
                .item(
                    Event::AddFavorite(ResourceId::from_str(
                        "03000143-e25e-45c7-aafb-144990e57dcd",
                    )?),
                    ADD_FAVORITE,
                )
                .separator()
                .disabled("Site")
                .copyable("test")
                .copyable(GATEWAY_CONNECTED),
        )
        .add_submenu(
            Menu::new("— Internet Resource")
                .disabled(INTERNET_RESOURCE_DESCRIPTION)
                .separator()
                .item(Event::EnableInternetResource, ENABLE)
                .separator()
                .disabled("Site")
                .copyable("test")
                .copyable(ALL_GATEWAYS_OFFLINE),
        )
        .add_bottom_section(None, DISCONNECT_AND_QUIT); // Skip testing the bottom section, it's simple

    assert_eq!(
        actual,
        expected,
        "{}",
        serde_json::to_string_pretty(&actual).unwrap(),
    );

    Ok(())
}
