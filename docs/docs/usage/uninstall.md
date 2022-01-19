---
layout: default
title: Uninstall
nav_order: 4
parent: Usage
---

# Uninstall

---

To completely remove Firezone and its configuration files, run the [uninstall.sh
script](https://github.com/firezone/firezone/blob/master/scripts/uninstall.sh):

```bash
sudo /bin/bash -c "$(curl -fsSL https://github.com/firezone/firezone/raw/master/scripts/uninstall.sh)"
```

**Warning**: This will irreversibly destroy ALL Firezone data and can't be
undone.
