# Linux source attribution

The `crates/` directory, `Cargo.toml` and `Cargo.lock` are imported from
[shinkuan/AirCard-Linux](https://github.com/shinkuan/AirCard-Linux), commit
`7686fd21e3e598d2217c5e6da88229cd1bca4e07`, under its MIT license. The complete
license is preserved in [LICENSE.AirCard-Linux](LICENSE.AirCard-Linux). Statements
about physical device tests in the source repository describe its author's
tests, not validation performed by the AirCard maintainers.

That Linux implementation ports
[Lumid-Off/AirCard-Windows](https://github.com/Lumid-Off/AirCard-Windows).
The original AirCard app is by [Mak5er](https://github.com/Mak5er/AirCard)
and contributors. The underlying AirLift research is by
[0xjohnnydev](https://github.com/0xjohnnydev/airlift).

This change adds the Linux client and
Arch Linux packaging. The Python/macOS helpers are not the Linux runtime.
