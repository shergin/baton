package baton.sample

import androidx.compose.runtime.Composable
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.ui.Modifier

/**
 * What the detail pane can show: a character, an episode or a location,
 * each by its id. A screen opens another by pushing one, so a character's
 * episode, that episode's cast and a cast member's location are reached
 * from the list through one stack, which a host keeps and renders.
 */
sealed interface Destination {
    val id: String

    data class Character(override val id: String) : Destination
    data class Episode(override val id: String) : Destination
    data class Location(override val id: String) : Destination

    companion object {
        /** A stack of destinations as a saver, each as its kind and id, so an Android host keeps it across a recreation. */
        val stackSaver: Saver<List<Destination>, Any> = listSaver(
            save = { stack -> stack.map { "${it::class.simpleName}:${it.id}" } },
            restore = { saved ->
                saved.map { entry ->
                    val (kind, id) = entry.split(':', limit = 2)
                    when (kind) {
                        "Episode" -> Episode(id)
                        "Location" -> Location(id)
                        else -> Character(id)
                    }
                }
            },
        )
    }
}

/** The screen of [destination], which opens another through [onOpen]. */
@Composable
fun DestinationScreen(destination: Destination, onOpen: (Destination) -> Unit, modifier: Modifier = Modifier) {
    when (destination) {
        is Destination.Character -> CharacterScreen(id = destination.id, onOpen = onOpen, modifier = modifier)
        is Destination.Episode -> EpisodeScreen(id = destination.id, onOpen = onOpen, modifier = modifier)
        is Destination.Location -> LocationScreen(id = destination.id, onOpen = onOpen, modifier = modifier)
    }
}
