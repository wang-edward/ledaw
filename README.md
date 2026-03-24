how to get zig 0.15.1
```
brew install asdf
asdf plugin add zig https://github.com/asdf-community/asdf-zig.git
asdf install zig 0.15.1
asdf set zig 0.15.1
zig env
```

build
```
zig build
```

run
```
zig build run
```

test
```
zig build test --summary all
```

## pics
<img width="624" height="652" alt="Screenshot 2026-03-18 at 12 51 28 AM" src="https://github.com/user-attachments/assets/21b99671-06a6-4e23-bf77-3efe01ce5a65" />
<img width="624" height="652" alt="Screenshot 2026-03-18 at 12 51 50 AM" src="https://github.com/user-attachments/assets/0f78a561-713b-41d4-afca-ff4cd20b876a" />
<img width="624" height="652" alt="Screenshot 2026-03-18 at 12 52 29 AM" src="https://github.com/user-attachments/assets/0fae416f-4942-49c6-9abd-050148f576ba" />

## Video demo (pretty outdated)
[![video demo](https://img.youtube.com/vi/XMdhAa6qCPk/0.jpg)](https://www.youtube.com/watch?v=XMdhAa6qCPk)

## art class requirements
- install uv, that should be enough
```
curl -LsSf https://astral.sh/uv/install.sh | sh
```

run everything
```
zig build art
```
