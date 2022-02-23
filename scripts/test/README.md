



# install test suite

Example of `hostnamectl` for each supported distro

```
.
└── hostnamectl
    ├── amazonlinux2-arm64
    ├── amazonlinux2-x64
    ├── centos7-x64
    ├── centos8-arm64
    .
    .
    .
```

which will help drive the install script WIP 
in case we add or remove platforms


# API throttle limits

When iterating of each type of platform it's better to 
have a cached version of the latest release rather
than over throttle GitHub's API

```
admin@ip-172-31-26-45:~/firezone/scripts/test$ curl -s https://api.github.com/repos/firezone/firezone/releases/latest 
```

```json
{
  "message": "API rate limit exceeded for 35.87.143.83. (But here's the good news: Authenticated requests get a higher rate limit. Check out the documentation for more details.)",
  "documentation_url": "https://docs.github.com/rest/overview/resources-in-the-rest-api#rate-limiting"
}
```


# WIP 

- [ ] passing more than one parameter seems to be acting weird 
- [ ] Ideaaly, if paramters behave _normally_ can have the ability to smoke test each platform or run live
- [x] found slight variation os name 'Fedora Linux 35' unlike the previous 'Fedora 34'
