# Fixture lockfiles

Empty `touch`-files — existence markers only. The scripts under test check `[ -f ... ]` for PM detection; they never read the contents. `$PM` itself is always stubbed, so real `pnpm install` never runs against these.
