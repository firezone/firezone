# Firezone Android client

## Prerequisites for developing locally

1. Install a recent `ruby` for your platform. Ruby is used for the mock auth
   server.
1. Install needed gems and start mock auth server:

```
cd server
bundle install
ruby server.rb
```

1. Add the following to a `./local.properties` file:

```gradle
sdk.dir=/path/to/your/ANDROID_HOME
```

Replace `/path/to/your/ANDROID_HOME` with the path to your locally installed
Android SDK. On macOS this is `/Users/jamil/Library./Android/sdk`

1. Perform a test build: `./gradlew build`
