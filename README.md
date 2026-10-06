# stowr.yazi

A [Yazi](https://yazi-rs.github.io/) plugin that moves the hovered (or marked) files and
directories into a [GNU Stow](https://www.gnu.org/software/stow/) package inside your dotfiles
repo, then runs `stow` so the symlink is recreated in place.

Hover `~/.config/git/config`, press `s`, confirm, type `git`:

```
before   ~/.config/git/config                       regular file
after    ~/.config/git/config          ->  ../../dotfiles/git/.config/git/config
         ~/dotfiles/git/.config/git/config          regular file, now versioned
```

Directories work the same way and are moved whole — stow then folds them into a single symlink:

```
before   ~/.config/kitty/kitty.conf                 a directory with files inside
after    ~/.config/kitty               ->  ../../dotfiles/kitty/.config/kitty
         ~/dotfiles/kitty/.config/kitty/…           the whole tree, now versioned
```

## Requirements

- [Yazi](https://yazi-rs.github.io/) `>= 26.9.1`
- [GNU Stow](https://www.gnu.org/software/stow/) on `PATH` — e.g. `sudo pacman -S stow`,
  `sudo apt install stow`, `brew install stow`
- A dotfiles repo laid out as stow packages (one directory per package)

## Installation

With Yazi's package manager:

```sh
ya pkg add matyifkbt/stowr
```

Or manually:

```sh
git clone https://github.com/matyifkbt/stowr.yazi ~/.config/yazi/plugins/stowr.yazi
```

## Configuration

`~/.config/yazi/init.lua`:

```lua
require("stowr"):setup {
	-- Repo that holds the stow packages
	dotfiles = "~/dotfiles",
	-- Extra arguments appended to the `stow` invocation, e.g. { "--no-folding" }
	flags = {},
}
```

`~/.config/yazi/keymap.toml`:

```toml
[[mgr.prepend_keymap]]
on   = "s"        # shadows the default `search --via=fd`; pick any key
run  = "plugin stowr"
desc = "Stow file into dotfiles"
```

Both are optional: without `setup` the plugin defaults to `dotfiles = "~/dotfiles"`.

## Usage

1. Hover a file or directory, or mark several with `<Space>` / `<C-a>`.
2. Press `s` (or whatever key you bound) and confirm.
3. Type the package (folder) name. It is pre-filled with a guess: the segment after
   `~/.config/`, else the first path segment under `$HOME`, else the last package you used.
   The package is created if it doesn't exist yet.
4. `stow` runs and the symlink appears where the file or directory used to be.

## How it works

- Targets are the marked files/directories if there are any, otherwise the hovered one.
- Destination is `<dotfiles>/<package>/<path relative to $HOME>`, matching the conventional
  `stow -t ~` layout — so `~/.config/git/config` becomes `~/dotfiles/git/.config/git/config`,
  and the directory `~/.config/kitty` becomes `~/dotfiles/kitty/.config/kitty`.
- Anything is moved with `rename`, falling back to copy + remove across file systems
  (`fs.copy` for a single file, `cp -a` for a directory).
- `stow -t ~ <package>` runs with the dotfiles repo as its working directory.
- On any failure during the move or the `stow` run, already-moved items are restored and the
  package tree created by the run is removed.

## Safety

The plugin refuses to touch anything it can't undo cleanly:

| Case | Result |
| --- | --- |
| Hovered entry is already a symlink | aborts: "already a symlink (already stowed?)" |
| Path is outside `$HOME` (e.g. `/etc`) | aborts — system packages and `sudo` are out of scope |
| Destination already exists in the package | asks for a second confirmation before overwriting |
| `stow` fails or is missing | restores the moved items, drops the created package tree, reports `stow`'s stderr |

An existing destination is swapped out through a temporary name in the same directory, so at every
instant either the old or the new content is in place and `stow` never sees anything but the final
tree.

## Limitations

- `$HOME` only: no `/etc` / system packages, no `sudo`.
- Everything is placed flat under the package root (no `--no-folding` style target override); pass
  `flags = { "--no-folding" }` if you want stow to link files inside a directory instead of folding
  the directory itself into one symlink.
- Moving across file systems needs `cp`/`rm` from coreutils (only used when the dotfiles repo lives
  on a different file system than `$HOME`).

## License

[MIT](LICENSE)
