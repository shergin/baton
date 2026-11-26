// An app's own file in the dependent module: it imports the runtime and the
// base without the generated SPI, so it can neither name an anchor nor build
// the base's lens over one. `scripts/check-bases.sh` type-checks this file
// against the built modules and expects it to fail on the lens's
// `init(anchor:)`; it is not a source of any target.
import Baton
import Shared

@MainActor
func reread(_ anchor: Anchor) -> String? {
    CharacterStatus_character(anchor: anchor).status
}
