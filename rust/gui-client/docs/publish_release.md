Publish GUI (Linux and Windows) release playbook

1. Run tests on debs and MSIs from tip of `main`
1. `git checkout main`
1. `git pull`
1. `git checkout -b ci/bump-gui`
1. Change the current and next GUI versions in `scripts/Makefile` https://github.com/firezone/firezone/commit/ef3b4e5dfeb7b9f0bcf9b7e12bb00a7ae12c2d8c#diff-8b119a9bacccbd06b544bc77467bcd92e68bd86f980367cb45d4379496759f46
1. Run `make -f scripts/Makefile version`
1. Uncomment the upcoming `Entry` in `website/src/components/Changelog/GUI.tsx` and make a new commented upcoming `Entry`
1. Update the known issues in `website/src/app/kb/user-guides/linux-gui-client/readme.mdx` and `website/src/app/kb/user-guides/windows-client/readme.mdx`.
1. `git commit -am "chore: bump GUI to 1.x.y"`
1. `git push`
1. Open a PR and get it approved
1. Run the publish CI step (Maybe? or publish the draft release?)
1. Merge the PR
