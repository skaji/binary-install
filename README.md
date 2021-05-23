# binary-install

Install binaries from github releases

# Usage

Prepare spec.yaml:

```yaml
binaries:
  - name: jq
    github_url: https://github.com/stedolan/jq
  - name: ghq
    github_url: https://github.com/x-motemen/ghq
  - name: peco
    github_url: https://github.com/peco/peco
```

And execute `binary-install` so that binaries will be installed into `~/bin`:

```
❯ binary-install spec.yaml
[jq] You don't have one, GO!
[jq] Downloading https://github.com/stedolan/jq/releases/download/jq-1.6/jq-osx-amd64
[jq] Install /Users/skaji/.binary-install/cache/d849afa2bb84e1a3300fda0f7cb63d49-jq-osx-amd64 as /Users/skaji/bin/jq
[ghq] You don't have one, GO!
[ghq] Downloading https://github.com/x-motemen/ghq/releases/download/v1.2.0/ghq_darwin_amd64.zip
[ghq] Install /Users/skaji/.binary-install/work/P4EIU6idEV/ghq_darwin_amd64/ghq as /Users/skaji/bin/ghq
[peco] You don't have one, GO!
[peco] Downloading https://github.com/peco/peco/releases/download/v0.5.8/peco_darwin_amd64.zip
[peco] Install /Users/skaji/.binary-install/work/7ENfjKHP4W/peco_darwin_amd64/peco as /Users/skaji/bin/peco
```

# Install

Download `binary-install`.

```
❯ wget https://raw.githubusercontent.com/skaji/binary-install/main/binary-install
❯ chmod +x binary-install
❯ ./binary-install --version
binary-install 0.0.1
```

# Copyright and License

This software is copyright (c) 2021 by Shoichi Kaji.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.
