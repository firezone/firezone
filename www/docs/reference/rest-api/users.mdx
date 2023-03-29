---
title: Users
sidebar_position: 2
toc_max_heading_level: 4
---


This endpoint allows an administrator to manage Users.

## Auto-Create Users from OpenID or SAML providers

You can set Configuration option `auto_create_users` to `true` to automatically create users
from OpenID or SAML providers. Use it with care as anyone with access to the provider will be
able to log-in to Firezone.

If `auto_create_users` is `false`, then you need to provision users with `password` attribute,
otherwise they will have no means to log in.

## Disabling users

Even though API returns `disabled_at` attribute, currently, it's not possible to disable users via API,
since this field is only for internal use by automatic user disabling mechanism on OIDC/SAML errors.

## API Documentation
### List all Users [`GET /v0/users`]



#### Example
```bash
$ curl -i \
  -X GET "https://{firezone_host}/v0/users" \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer {api_token}' \

HTTP/1.1 200
Content-Type: application/json; charset=utf-8

{
  "data": [
    {
      "disabled_at": null,
      "email": "test-5094@test",
      "id": "4963a5f0-dbb5-424a-8859-8032209eeaef",
      "inserted_at": "2023-03-29T15:11:47.363517Z",
      "last_signed_in_at": null,
      "last_signed_in_method": null,
      "role": "admin",
      "updated_at": "2023-03-29T15:11:47.363517Z"
    },
    {
      "disabled_at": null,
      "email": "test-5634@test",
      "id": "e904d9ae-c358-4ab4-9bfd-44b4bf942a15",
      "inserted_at": "2023-03-29T15:11:47.364938Z",
      "last_signed_in_at": null,
      "last_signed_in_method": null,
      "role": "admin",
      "updated_at": "2023-03-29T15:11:47.364938Z"
    },
    {
      "disabled_at": null,
      "email": "test-5666@test",
      "id": "e7decf88-4abb-45df-9dd0-35e3587dfb59",
      "inserted_at": "2023-03-29T15:11:47.366068Z",
      "last_signed_in_at": null,
      "last_signed_in_method": null,
      "role": "admin",
      "updated_at": "2023-03-29T15:11:47.366068Z"
    },
    {
      "disabled_at": null,
      "email": "test-5190@test",
      "id": "457aeee0-13aa-44b3-9057-181cc206edcb",
      "inserted_at": "2023-03-29T15:11:47.367568Z",
      "last_signed_in_at": null,
      "last_signed_in_method": null,
      "role": "admin",
      "updated_at": "2023-03-29T15:11:47.367568Z"
    }
  ]
}
```
### Create a User [`POST /v0/users`]


Create a new User.

This endpoint is useful in two cases:

  1. When [Local Authentication](/docs/authenticate/local-auth/) is enabled (discouraged in
    production deployments), it allows an administrator to provision users with their passwords;
  2. When `auto_create_users` in the associated OpenID or SAML configuration is disabled,
    it allows an administrator to provision users with their emails beforehand, effectively
    whitelisting specific users for authentication.

If `auto_create_users` is `true` in the associated OpenID or SAML configuration, there is no need
to provision users; they will be created automatically when they log in for the first time using
the associated OpenID or SAML provider.

#### User Attributes

| Attribute | Type | Required | Description |
| --------- | ---- | -------- | ----------- |
| `role` | `admin` or `unprivileged` (default) | No | User role. |
| `email` | `string` | Yes | Email which will be used to identify the user. |
| `password` | `string` | No | A password that can be used for login-password authentication. |
| `password_confirmation` | `string` | -> | Is required when the `password` is set. |

#### Example
```bash
$ curl -i \
  -X POST "https://{firezone_host}/v0/users" \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer {api_token}' \
  --data-binary @- << EOF
{
  "user": {
    "email": "new-user@test",
    "password": "test1234test",
    "password_confirmation": "test1234test",
    "role": "unprivileged"
  }
}'
EOF

HTTP/1.1 201
Content-Type: application/json; charset=utf-8
Location: /v0/users/2b7128fb-4a30-472d-9f45-d2a5063ba5db

{
  "data": {
    "disabled_at": null,
    "email": "new-user@test",
    "id": "2b7128fb-4a30-472d-9f45-d2a5063ba5db",
    "inserted_at": "2023-03-29T15:11:47.178709Z",
    "last_signed_in_at": null,
    "last_signed_in_method": null,
    "role": "unprivileged",
    "updated_at": "2023-03-29T15:11:47.178709Z"
  }
}
```
#### Provision an unprivileged OpenID User
```bash
$ curl -i \
  -X POST "https://{firezone_host}/v0/users" \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer {api_token}' \
  --data-binary @- << EOF
{
  "user": {
    "email": "new-user@test",
    "role": "unprivileged"
  }
}'
EOF

HTTP/1.1 201
Content-Type: application/json; charset=utf-8
Location: /v0/users/e4796108-f4d8-4a11-9860-d07b92b08d93

{
  "data": {
    "disabled_at": null,
    "email": "new-user@test",
    "id": "e4796108-f4d8-4a11-9860-d07b92b08d93",
    "inserted_at": "2023-03-29T15:11:47.192265Z",
    "last_signed_in_at": null,
    "last_signed_in_method": null,
    "role": "unprivileged",
    "updated_at": "2023-03-29T15:11:47.192265Z"
  }
}
```
#### Provision an admin OpenID User
```bash
$ curl -i \
  -X POST "https://{firezone_host}/v0/users" \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer {api_token}' \
  --data-binary @- << EOF
{
  "user": {
    "email": "new-user@test",
    "role": "admin"
  }
}'
EOF

HTTP/1.1 201
Content-Type: application/json; charset=utf-8
Location: /v0/users/479ed1cb-1657-4c82-bc32-2200f6cc82e9

{
  "data": {
    "disabled_at": null,
    "email": "new-user@test",
    "id": "479ed1cb-1657-4c82-bc32-2200f6cc82e9",
    "inserted_at": "2023-03-29T15:11:47.460359Z",
    "last_signed_in_at": null,
    "last_signed_in_method": null,
    "role": "admin",
    "updated_at": "2023-03-29T15:11:47.460359Z"
  }
}
```
#### Error due to invalid parameters
```bash
$ curl -i \
  -X POST "https://{firezone_host}/v0/users" \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer {api_token}' \
  --data-binary @- << EOF
{
  "user": {
    "email": "test@test.com",
    "password": "test1234"
  }
}'
EOF

HTTP/1.1 422
Content-Type: application/json; charset=utf-8

{
  "errors": {
    "password": [
      "should be at least 12 character(s)"
    ],
    "password_confirmation": [
      "can't be blank"
    ]
  }
}
```
### GET /v0/users/{id}



#### An email can be used instead of ID.
**URI Parameters:**

  - `id`: `test-905@test`
```bash
$ curl -i \
  -X GET "https://{firezone_host}/v0/users/{id}" \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer {api_token}' \

HTTP/1.1 200
Content-Type: application/json; charset=utf-8

{
  "data": {
    "disabled_at": null,
    "email": "test-905@test",
    "id": "d43dae29-0687-456c-a3a4-a461eb744cf5",
    "inserted_at": "2023-03-29T15:11:47.340583Z",
    "last_signed_in_at": null,
    "last_signed_in_method": null,
    "role": "admin",
    "updated_at": "2023-03-29T15:11:47.340583Z"
  }
}
```
### Update a User [`PATCH /v0/users/{id}`]


For details please see [Create a User](#create-a-user-post-v0users) section.

#### Update by email
**URI Parameters:**

  - `id`: `test-1960@test`
```bash
$ curl -i \
  -X PUT "https://{firezone_host}/v0/users/{id}" \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer {api_token}' \
  --data-binary @- << EOF
{
  "user": {}
}'
EOF

HTTP/1.1 200
Content-Type: application/json; charset=utf-8

{
  "data": {
    "disabled_at": null,
    "email": "test-1960@test",
    "id": "8830b359-2368-4f55-9879-1cb04ee0cbbf",
    "inserted_at": "2023-03-29T15:11:47.391921Z",
    "last_signed_in_at": null,
    "last_signed_in_method": null,
    "role": "unprivileged",
    "updated_at": "2023-03-29T15:11:47.391921Z"
  }
}
```
#### Update by ID
**URI Parameters:**

  - `id`: `d542e1bc-25b2-453d-ae14-41f8f81605ee`
```bash
$ curl -i \
  -X PUT "https://{firezone_host}/v0/users/{id}" \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer {api_token}' \
  --data-binary @- << EOF
{
  "user": {}
}'
EOF

HTTP/1.1 200
Content-Type: application/json; charset=utf-8

{
  "data": {
    "disabled_at": null,
    "email": "test-1513@test",
    "id": "d542e1bc-25b2-453d-ae14-41f8f81605ee",
    "inserted_at": "2023-03-29T15:11:47.475440Z",
    "last_signed_in_at": null,
    "last_signed_in_method": null,
    "role": "unprivileged",
    "updated_at": "2023-03-29T15:11:47.475440Z"
  }
}
```
### DELETE /v0/users/{id}



#### Example
**URI Parameters:**

  - `id`: `31156bf6-73de-4d9b-aa1e-2e419a45dd25`
```bash
$ curl -i \
  -X DELETE "https://{firezone_host}/v0/users/{id}" \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer {api_token}' \

HTTP/1.1 204
Content-Type: application/json; charset=utf-8
```
#### An email can be used instead of ID.
**URI Parameters:**

  - `id`: `test-4996@test`
```bash
$ curl -i \
  -X DELETE "https://{firezone_host}/v0/users/{id}" \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer {api_token}' \

HTTP/1.1 204
Content-Type: application/json; charset=utf-8
```
