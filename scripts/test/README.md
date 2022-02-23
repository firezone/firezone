



# install test suite


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



# now need a mock API too to avoid this (while testing above)

```
admin@ip-172-31-26-45:~/firezone/scripts/test$ curl -s https://api.github.com/repos/firezone/firezone/releases/latest 
```

```json
{
  "message": "API rate limit exceeded for 35.87.143.83. (But here's the good news: Authenticated requests get a higher rate limit. Check out the documentation for more details.)",
  "documentation_url": "https://docs.github.com/rest/overview/resources-in-the-rest-api#rate-limiting"
}
```

