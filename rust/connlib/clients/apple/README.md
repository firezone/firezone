# Connlib Apple Wrapper

Apple Package wrapper for Connlib distributed as a binary XCFramework for
inclusion in the Firezone Apple client.

## Prerequisites

1. Install [ stable rust ](https://www.rust-lang.org/tools/install) for your
   platform
1. Install `llvm` from Homebrew:

```

brew install llvm

```

This fixes build issues with Apple's command line tools. See
https://github.com/briansmith/ring/issues/1374
